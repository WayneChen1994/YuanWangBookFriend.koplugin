--[[--
DeepSeek API 封装（PRD §5.3）。
只走 chat/completions，非流式；密钥从加密存储读取，永不明文。
--]]--

local Config = require("ywbf/config")
local Crypto = require("ywbf/crypto")
local HttpClient = require("ywbf/httpclient")
local Spoiler = require("ywbf/spoiler")
local Util = require("ywbf/util")
local json = require("json")
local logger = require("logger")
local _ = require("gettext")

local DeepSeek = {}

DeepSeek.ENDPOINT = "https://api.deepseek.com/chat/completions"
-- 余额查询：只读接口，不消耗额度，也不携带任何书籍内容
DeepSeek.BALANCE_ENDPOINT = "https://api.deepseek.com/user/balance"

-- JSON 字段只认字符串和数字：dkjson 把 null 解成一个 function，
-- 直接带出去会让 UI 印出 "function: 0x…"，所以其余类型一律当字段缺失
local function scalar(v)
    if type(v) == "string" or type(v) == "number" then return v end
    return nil
end

function DeepSeek:getApiKey()
    local blob = Config:get("api_key_enc")
    if not blob then return nil, _("未配置 API Key（请到「远望书友 → API Key 配置」设置，或从文件导入）") end
    local key, err = Crypto:decrypt(blob)
    if not key then return nil, "API Key 解密失败：" .. tostring(err) end
    return key
end

function DeepSeek:setApiKey(plain_key)
    if not plain_key or plain_key == "" then
        Config:set("api_key_enc", nil)
        return false
    end
    local blob = Crypto:encrypt(plain_key)
    if not blob then return false end
    Config:set("api_key_enc", blob)
    return true
end

function DeepSeek:hasApiKey()
    return Config:get("api_key_enc") ~= nil
end

--[[--
**防剧透管道的单点出口（PRD F4.2/F4.3/F4.4，DEV_PLAN T3.6）**

插件里所有发往 DeepSeek 的请求都必须经过 DeepSeek:chat，因此管道就装在这里：
  1. 发出前：Spoiler.guardMessages —— 多轮历史 / 用户粘贴的原文按未读章节标题截断；
  2. 回来后：Spoiler.sanitizeAnswer —— 回答里出现未读章节号/标题时替换为标准化模糊提示。
开关关闭或拿不到进度时两步都直通，行为与 M2 完全一致。
没有旁路：ui/asker.lua、ui/chatdialog.lua、ui/toastcard.lua、main.lua 的连通性测试
全部经由本函数，不存在第二处 HttpClient.post。

例外只有一个：balance() 走 GET /user/balance 查账户余额，
它不携带任何书籍正文/选中文本，因此不在防剧透管道的覆盖范围内。

@param messages 消息数组 { {role=..., content=...}, ... }
@param opts { model, temperature, max_tokens, timeout,
              spoiler_progress=table（Spoiler.readProgress 的产物，可空） }
@return result, err
       result = { content=string, usage={...}, raw=table, spoiler_hit=bool }
--]]
function DeepSeek:chat(messages, opts)
    opts = opts or {}
    local api_key, key_err = self:getApiKey()
    if not api_key then return nil, key_err end
    if type(messages) ~= "table" or #messages == 0 then
        return nil, "messages 为空"
    end

    -- ---- 管道第 1 道：截断待发送文本 ----
    local prog = Spoiler.withConfig(opts.spoiler_progress, Spoiler.currentConfig())
    local guarded, guard_info = Spoiler.guardMessages(messages, prog)

    -- ---- 管道第 2 道：UTF-8 合法性净化 ----
    -- epub 正文里混着脏字节（截断的多字节序列、孤立续字节、代理对、超长编码），
    -- json.encode 会照原样写进 JSON，DeepSeek 那边直接 400：
    --   "Failed to parse the request body as JSON: ... invalid unicode code point"
    -- 表现为「选中某段文字就报错」，取决于那段有没有脏字节，偶发且难复现。
    -- 必须在出口统一净化，不能指望每个调用点自觉。
    guarded = Util.sanitizeMessages(guarded)

    local payload = {
        model = opts.model or Config:get("model") or "deepseek-chat",
        messages = guarded,
        temperature = opts.temperature or Config:get("temperature_fact"),
        max_tokens = opts.max_tokens or Config:get("max_tokens_chat"),
        stream = false,
    }

    local ok_enc, body = pcall(json.encode, payload)
    if not ok_enc then return nil, "请求序列化失败：" .. tostring(body) end

    local resp, code, status, err = HttpClient.post(
        self.ENDPOINT,
        {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. api_key,
            ["Content-Length"] = tostring(#body),
        },
        body,
        opts.timeout or Config:get("request_timeout")
    )

    if err then return nil, "网络请求失败：" .. err end
    local brief = Util.utf8sub(resp or "", 300)  -- 按字符截，避免切出半个汉字
    if code ~= 200 then
        return nil, string.format("DeepSeek 返回错误 %s (%s): %s",
            tostring(code), tostring(status), brief)
    end

    local ok_dec, decoded = pcall(json.decode, resp or "")
    if not ok_dec then return nil, "响应解析失败：" .. brief end
    if type(decoded) ~= "table" then return nil, "响应格式异常" end

    if decoded.error then
        return nil, "API 错误：" .. tostring(decoded.error.message or decoded.error)
    end

    local choice = decoded.choices and decoded.choices[1]
    if not choice or not choice.message then
        return nil, "响应缺少 choices/message"
    end

    local usage = decoded.usage or {}
    Config:addUsage(usage.prompt_tokens or 0, usage.completion_tokens or 0)

    -- ---- 管道第 2 道：回答里的剧透预警替换（本地正则，零额外调用） ----
    local content = choice.message.content or ""
    local safe, hit, reason = Spoiler.sanitizeAnswer(content, prog)
    if hit then
        logger.dbg("YWBF: spoiler hit in answer, replaced:", tostring(reason))
    end

    return {
        content = safe,
        usage = usage,
        raw = decoded,
        spoiler_hit = hit,
        spoiler_reason = reason,
        guard_truncated = guard_info and (guard_info.hits or 0) or 0,
    }
end

--[[--
查询账户余额（GET /user/balance，只读，不消耗额度）。

返回结构直接照 DeepSeek 的接口原样解析：
  { is_available = true, balance_infos = { { currency="CNY", total_balance="19.73",
    granted_balance="0.00", topped_up_balance="19.73" } } }
这里归一化成 balances 数组，避免 UI 层去猜嵌套字段名。

@return result, err
       result = { is_available=bool, balances={ {currency, total_balance,
                 granted_balance, topped_up_balance} }, raw=table }
--]]
function DeepSeek:balance()
    local api_key, key_err = self:getApiKey()
    if not api_key then return nil, key_err end

    local resp, code, status, err = HttpClient.get(
        self.BALANCE_ENDPOINT,
        {
            ["Accept"] = "application/json",
            ["Authorization"] = "Bearer " .. api_key,
        },
        Config:get("request_timeout")
    )
    if err then return nil, "网络请求失败：" .. err end

    local brief = Util.utf8sub(resp or "", 300)  -- 按字符截，避免切出半个汉字
    if code ~= 200 then
        return nil, string.format("DeepSeek 返回错误 %s (%s): %s",
            tostring(code), tostring(status), brief)
    end

    local ok_dec, decoded = pcall(json.decode, resp or "")
    if not ok_dec or type(decoded) ~= "table" then
        return nil, "响应解析失败：" .. brief
    end
    if decoded.error then
        return nil, "API 错误：" .. tostring(decoded.error.message or decoded.error)
    end

    local balances = {}
    if type(decoded.balance_infos) == "table" then
        for _i, b in ipairs(decoded.balance_infos) do
            if type(b) == "table" then
                -- dkjson 把 JSON null 解成一个 function，展示层 tostring 会印出地址，
                -- 所以这里只收字符串和数字，其余一律当缺失
                balances[#balances + 1] = {
                    currency = scalar(b.currency),
                    total_balance = scalar(b.total_balance),
                    granted_balance = scalar(b.granted_balance),
                    topped_up_balance = scalar(b.topped_up_balance),
                }
            end
        end
    end

    return {
        is_available = decoded.is_available,
        balances = balances,
        raw = decoded,
    }
end

return DeepSeek
