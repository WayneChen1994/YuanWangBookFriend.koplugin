--[[--
设置页与主菜单（M1 版本）：API Key 配置（掩码输入 + 加密保存）、连通性测试、
模型选择、防剧透开关、用量统计、关于。

PRD 对应：F8.4（Key 加密存储）、F8.5（无遥测声明）、F4.1（防剧透总开关）、§4.3（用量透明）
--]]--

local Config = require("ywbf/config")
local Crypto = require("ywbf/crypto")
local DeepSeek = require("ywbf/deepseek")
local Prompts = require("ywbf/prompts")
local Queue = require("ywbf/queue")
local Spoiler = require("ywbf/spoiler")
local Tokens = require("ywbf/tokens")

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local SettingsUI = {}

--[[--
关于 API Key 的显示方式（真机反馈后定的口径）：**菜单上不显示内容，对话框里全明文**。

两个方向都试过、都被否掉了：
  · 菜单里显示掩码（"sk-****…"）：DeepSeek 的 Key 全是 sk- 开头，掩码后只剩
    一串星号加省略号，既看不出是哪个 Key、也没法核对抄错了没有 —— 毫无意义；
  · 菜单里全明文：菜单是常驻可见的，旁边有人时等于把密钥摊在屏幕上。

所以：菜单行只给**状态**（已设置 / 未设置），要核对内容就点进去看——
对话框里把当前明文 Key 预填进输入框，可直接编辑、也可整段粘贴覆盖。
--]]
function SettingsUI:showApiKeyDialog()
    local current = DeepSeek:getApiKey()
    local dialog
    dialog = InputDialog:new{
        title = _("配置 DeepSeek API Key"),
        description = _([[Key 会加密保存在插件目录内，永不以明文落盘。
粘贴后点击「保存」。]]),
        -- 预填当前明文 Key：让人能真的核对"是不是这一个"，
        -- 而不是对着一串星号猜。原样保存等于没改，保存逻辑不用动。
        input = current or "",
        input_hint = current and _("已设置（可直接编辑，或粘贴新的覆盖）") or _("尚未配置"),
        input_type = "string",
        -- 刻意**不设** text_type = "password"：
        -- 它是 KOReader 那个「显示密码」勾选框的唯一来源
        -- （inputtext.lua: is_password_type = text_type == "password"，
        --  为 false 时 _password_toggle 直接是 nil，inputdialog 不会挂出来）。
        -- 去掉它 → 输入框明文、勾选项根本不出现，比去改 KOReader 内置文案干净。
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputText()
                        UIManager:close(dialog)
                        value = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        if value == "" then
                            UIManager:show(InfoMessage:new{ text = _("未输入内容，未做修改") })
                            return
                        end
                        local ok = DeepSeek:setApiKey(value)
                        UIManager:show(InfoMessage:new{
                            text = ok and _("API Key 已加密保存") or _("保存失败"),
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--[[--
从文件导入 API Key：墨水屏上手输 32 位密钥太痛苦。
USB 拷贝一个文本文件到插件 data 目录，命名 api_key.txt，这里一键导入。
导入成功后自动删除明文文件。
--]]
function SettingsUI:importApiKeyFromFile()
    local path = Config.paths.data .. "/api_key.txt"
    local f = io.open(path, "r")
    if not f then
        UIManager:show(InfoMessage:new{
            text = T(_([[没有找到 Key 文件。

请用 USB 连电脑，把写着 DeepSeek API Key 的文本文件放到插件 data 目录，命名为 api_key.txt：

%1

放好后回到这里点击导入。导入成功会自动删除明文文件。]]), path),
        })
        return
    end
    local key = (f:read("*l") or "")
    f:close()
    key = key:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^[\"']", ""):gsub("[\"']$", "")
    if key == "" then
        UIManager:show(InfoMessage:new{ text = _("文件内容为空") })
        return
    end
    if not DeepSeek:setApiKey(key) then
        UIManager:show(InfoMessage:new{ text = _("保存失败") })
        return
    end
    os.remove(path)
    -- 不回显 Key 内容（同菜单口径：要核对就进配置对话框看明文）
    UIManager:show(InfoMessage:new{
        text = _("已导入并加密保存。\n\n明文文件已删除。"),
    })
end

function SettingsUI:testConnection()
    if not DeepSeek:hasApiKey() then
        UIManager:show(InfoMessage:new{ text = _("请先配置 API Key") })
        return
    end
    UIManager:show(InfoMessage:new{ text = _("正在测试连接…"), timeout = 1 })

    Queue:submit({
        name = "test_connection",
        fn = function()
            return DeepSeek:chat({
                { role = "system", content = "你是阅读助手，回答务必简短。" },
                { role = "user",   content = "用一句话说明《红楼梦》的作者是谁。" },
            }, { max_tokens = 128, temperature = 0.3 })
        end,
        on_done = function(result)
            UIManager:show(InfoMessage:new{
                text = T(_("连接成功\n\n模型回复：%1\n\n本次消耗：%2 tokens"),
                    result.content or "", tostring((result.usage or {}).total_tokens or "?")),
            })
        end,
        on_error = function(err)
            UIManager:show(InfoMessage:new{ text = _("连接失败：") .. tostring(err) })
        end,
    })
    Queue:process()
end

-- 余额展示用的货币符号；接口返回的是 ISO 代码（CNY / USD）
local CURRENCY_SYMBOL = {
    CNY = "¥",
    USD = "$",
}

--[[--
把余额结果排成一段可直接展示的文本。

必须把"总余额 / 充值余额 / 赠送余额"分开写：赠送余额有有效期，
用户看到总数多就够了，但想知道自己充了多少时不能让他猜。
--]]
function SettingsUI.formatBalance(res)
    if type(res) ~= "table" then return _("没有拿到余额信息") end

    local lines = { _("DeepSeek 账户余额"), "" }

    if type(res.balances) == "table" and #res.balances > 0 then
        -- 循环变量不能用 `_`：文件头 `local _ = require("gettext")` 会被它遮蔽，
        -- 循环体里再调 _("…") 就变成「attempt to call a number value」。
        -- 这个坑踩过一次（余额页正常路径必崩），所以这里一律用 _i。
        for _i, b in ipairs(res.balances) do
            local cur = tostring(b.currency or "?")
            local sym = CURRENCY_SYMBOL[cur] or ""
            lines[#lines + 1] = T(_("%1%2（%3）"),
                sym, tostring(b.total_balance or "?"), cur)
            if b.topped_up_balance ~= nil or b.granted_balance ~= nil then
                lines[#lines + 1] = T(_("  充值 %1%2 · 赠送 %3%4"),
                    sym, tostring(b.topped_up_balance or "0.00"),
                    sym, tostring(b.granted_balance or "0.00"))
            end
        end
    else
        lines[#lines + 1] = _("接口没有返回余额条目")
    end

    lines[#lines + 1] = ""
    if res.is_available == false then
        lines[#lines + 1] = _("状态：不可用（余额不足或未开通，调用会失败）")
    else
        lines[#lines + 1] = _("状态：可用")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = _("本查询只读，不消耗额度。")

    return table.concat(lines, "\n")
end

--[[--
查询账户余额（GET /user/balance）。

只查余额，不发任何书籍内容；失败要立刻报错（retries=0），
不要像聊天请求那样退避重试——重试会白等 1s+2s，界面像卡住。
--]]
function SettingsUI:queryBalance()
    if not DeepSeek:hasApiKey() then
        UIManager:show(InfoMessage:new{ text = _("请先配置 API Key") })
        return
    end
    UIManager:show(InfoMessage:new{ text = _("正在查询余额…"), timeout = 1 })

    Queue:submit({
        name = "balance",
        retries = 0,
        fn = function() return DeepSeek:balance() end,
        on_done = function(res)
            UIManager:show(InfoMessage:new{ text = SettingsUI.formatBalance(res) })
        end,
        on_error = function(err)
            UIManager:show(InfoMessage:new{
                text = _("余额查询失败：") .. tostring(err),
            })
        end,
    })
    Queue:process()
end

local MODELS = {
    { key = "deepseek-chat",     text = _("deepseek-chat（常规，成本低）") },
    { key = "deepseek-reasoner", text = _("deepseek-reasoner（深度推理，成本高）") },
}

-- 防剧透粒度（PRD F4.5）
local GRANULARITIES = {
    {
        key = Spoiler.GRANULARITY_CHAPTER,
        text = _("按章节边界（推荐）"),
        help = _("用目录定位当前章节，未读章节的文本在进入请求前就被物理截断。"),
    },
    {
        key = Spoiler.GRANULARITY_COLLECTION,
        text = _("按作品（合集）"),
        help = _([[一本 epub 里含多部独立作品时用这个（如《十本书读懂阿加莎》）。

读合集的人不会从头读到尾，而是直接跳到其中某一部去读；按"读到第几章"判断的话，
排在它前面的那些部会被误判成已读而剧透。选这项后，除当前在读的那一部之外，
其余各部不论排在前面还是后面都算未读。]]),
    },
    {
        key = Spoiler.GRANULARITY_PERCENT,
        text = _("按全书百分比"),
        help = _("没有可用目录时的粗粒度方案：按当前进度比例限制「向前看」的文本量。"),
    },
}

-- 合集判定的三种取值（对应 Config 的 spoiler_collection）
local COLLECTION_MODES = {
    {
        key = Spoiler.COLLECTION_AUTO,
        text = _("自动识别（默认）"),
        help = _("按目录结构自动判断：一级条目不少于 3 个、条目下还有更深层级，"
            .. "且一级标题不大多是「第 X 章/篇/卷/部」这类序号式标题时，判为合集。"),
    },
    {
        key = Spoiler.COLLECTION_ON,
        text = _("是，本书是合集"),
        help = _("强制按合集隔离：目录里的每个一级条目都当作一部独立作品，"
            .. "当前部之外的全都算未读。自动识别漏判时用这个。"),
    },
    {
        key = Spoiler.COLLECTION_OFF,
        text = _("不是合集"),
        help = _("强制按普通单本书处理：只有当前位置之后的章节算未读。"
            .. "自动识别误判（如带卷/篇结构的小说）时用这个。"),
    },
}

local function collectionModeName(key)
    if key == Spoiler.COLLECTION_ON then return _("是") end
    if key == Spoiler.COLLECTION_OFF then return _("不是") end
    return _("自动")
end

--[[--
无目录时的强度说明。

书没有可用目录时，"进度百分之几"只能估算每一句话是否已读 —— 这不是隔离，
只是把暴露窗口压小。必须对用户讲清楚，否则他会以为关掉开关之外的所有情况
都已经挡住了。
--]]
local function fallbackNotice(prog)
    if type(prog) ~= "table" or prog.granularity_auto ~= true then return "" end
    return T(_([[

注意：这本书没有可用的目录，找不到章节边界。
此时的防护是**弱防护**——只会把向后看的原文压缩到 %1 字以内，并不能保证
紧贴阅读位置之后的句子一定是已读的。想要真正的章节级隔离，请换用带目录的
EPUB，或暂时关闭依赖语境的功能。]]), tostring(Spoiler.AUTO_FALLBACK_MAX_CHARS))
end

--[[--
合集状态一句话（设置页用）。
自动识别只能给"疑似"，最终判定权在用户手上，所以这里必须把"生效/未生效 + 原因"
说清楚，否则用户会以为一切都挡住了。
--]]
local function collectionStatus(prog)
    if type(prog) ~= "table" then return _("未识别到阅读进度") end
    if prog.collection_active then
        if type(prog.work_index) == "number" and prog.work_index >= 1
            and type(prog.work_total) == "number" then
            return T(_("生效：当前第 %1 / %2 部%3，其余各部全部算未读"),
                tostring(prog.work_index), tostring(prog.work_total),
                (type(prog.work_title) == "string" and prog.work_title ~= "")
                    and ("（" .. prog.work_title .. "）") or "")
        end
        return _("生效：还没进入第 1 部，全部未读")
    end
    if prog.collection_detected then
        return _("未生效：目录疑似合集，但当前设置按普通单本书处理")
    end
    return _("未生效：未识别为合集（只有当前位置之后的章节算未读）")
end

--[[--
合集诊断页（PRD F4.5：把判定依据讲给用户，让他能自己拍板）。
--]]
function SettingsUI:collectionDiagnose(plugin)
    local prog = (plugin and plugin.currentProgress) and plugin:currentProgress() or nil
    local detected = (type(prog) == "table" and prog.collection_detected == true)
    local active = (type(prog) == "table" and prog.collection_active == true)
    local mode = Config:get("spoiler_collection") or Spoiler.COLLECTION_AUTO
    local works = (type(prog) == "table" and type(prog.work_total) == "number")
        and tostring(prog.work_total) or _("未知")

    local hint
    if active then
        hint = _([[已按合集隔离：除当前这一部之外的其余各部（不论排在它前面还是后面），
以及当前这一部里你还没读到的章节，都不会进入发给 AI 的内容。]])
    elseif detected then
        hint = _([[这本书的目录看起来像合集：一级条目下还有更深一层的章节。
若它确实是合集，请把「本书是合集」设为「是」，否则排在前面的那些部会被当成已读。]])
    else
        hint = _([[未识别为合集，按普通单本书处理：只有当前位置之后的章节算未读。
如果这本书其实是合集（一本里含多部独立作品），请手动把开关设为「是」。]])
    end

    return T(_([[· 目录一级条目数（作品数）：%1
· 自动识别结果：%2
· 「本书是合集」开关：%3
· 隔离状态：%4

%5

自动识别阈值：一级条目不少于 %6 个，且条目下还有更深层级的章节，
且一级标题不大多是「第 X 章 / 篇 / 卷 / 部」这类序号式标题。]]),
        works,
        detected and _("疑似合集") or _("不像合集"),
        collectionModeName(mode),
        collectionStatus(prog),
        hint,
        tostring(Spoiler.COLLECTION_MIN_WORKS))
end

--[[--
防剧透子菜单（PRD F4.1 全局开关 + F4.5 粒度选择 + 合集判定 + 当前进度展示）。
所有改动即时写入 Config，下一次提问立刻生效。
--]]
function SettingsUI:buildSpoilerMenu(plugin)
    local items = {}

    items[#items + 1] = {
        text = _("启用防剧透"),
        checked_func = function() return Config:get("spoiler_guard") == true end,
        callback = function()
            local v = Config:get("spoiler_guard")
            Config:set("spoiler_guard", not v)
            UIManager:show(InfoMessage:new{
                text = (not v) and _("防剧透已开启：未读章节不会进入发给 AI 的内容")
                              or _("防剧透已关闭：AI 可以看到完整上下文"),
            })
        end,
    }

    items[#items + 1] = {
        text = _("截断粒度"),
        sub_item_table = (function()
            local subs = {}
            for _i, g in ipairs(GRANULARITIES) do
                subs[#subs + 1] = {
                    text = g.text,
                    help_text = g.help,
                    checked_func = function() return Config:get("spoiler_granularity") == g.key end,
                    callback = function()
                        Config:set("spoiler_granularity", g.key)
                        UIManager:show(InfoMessage:new{
                            text = T(_("已切换为：%1\n\n%2"), g.text, g.help),
                        })
                    end,
                }
            end
            return subs
        end)(),
    }

    -- 合集判定（M3-COL）：自动识别是猜测，用户必须能强制开关
    items[#items + 1] = {
        text_func = function()
            return T(_("本书是合集（%1）"),
                collectionModeName(Config:get("spoiler_collection"))) -- luacheck: ignore
        end,
        sub_item_table = (function()
            local subs = {}
            for _i, m in ipairs(COLLECTION_MODES) do
                subs[#subs + 1] = {
                    text = m.text,
                    help_text = m.help,
                    checked_func = function()
                        return (Config:get("spoiler_collection") or Spoiler.COLLECTION_AUTO) == m.key
                    end,
                    callback = function()
                        Config:set("spoiler_collection", m.key)
                        UIManager:show(InfoMessage:new{
                            text = T(_("已设为：%1\n\n%2"), m.text, m.help),
                        })
                    end,
                }
            end
            return subs
        end)(),
    }

    items[#items + 1] = {
        text = _("合集判定诊断"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(InfoMessage:new{ text = SettingsUI:collectionDiagnose(plugin) })
        end,
    }

    items[#items + 1] = {
        text = _("查看当前识别到的进度"),
        keep_menu_open = true,
        callback = function()
            local prog = nil
            if plugin and plugin.currentProgress then
                prog = plugin:currentProgress()
            end
            local label = Spoiler.progressLabel(prog)
            local detail
            if type(prog) == "table" and prog.ok then
                detail = T(_([[当前进度：%1

· 定位方式：%2
· 文档类型：%3
· 截断粒度：%4
· 未读章节标题数：%5

防剧透会用这个位置决定截断点。若显示「未识别到阅读进度」，
防剧透会退化为只靠提示词约束，不会阻塞你的提问。]]),
                    label,
                    tostring(prog.source or "未知"),
                    prog.has_pages and _("分页文档（PDF 类）") or _("滚动文档（EPUB 类）"),
                    prog.granularity_auto and _("百分比（无可用目录，已自动回落）")
                        or (prog.granularity == Spoiler.GRANULARITY_PERCENT and _("百分比") or _("章节边界")),
                    tostring(prog.unread_titles and #prog.unread_titles or 0))
                    .. fallbackNotice(prog)
                    .. "\n\n· 合集判定：" .. collectionStatus(prog)
            else
                detail = T(_([[当前进度：%1

没有读到有效的页码/目录信息，防剧透退化为只靠提示词约束，不阻塞提问。]]), label)
            end
            UIManager:show(InfoMessage:new{ text = detail })
        end,
    }

    return items
end

--[[--
AI 回复风格子菜单（7 选 1，单选 = 后选的覆盖先选的）。
选项列表直接取自 Prompts.STYLES，不在 UI 里复制一份：
加风格时只改 prompts.lua 一处，菜单自动跟上。
--]]
function SettingsUI:buildReplyStyleMenu()
    local subs = {}
    -- 循环变量用 _i：文件头 `local _ = require("gettext")` 会被 `_` 遮蔽成数字，
    -- 循环体里再调 _("…") 就是「attempt to call a number value」。
    for _i, s in ipairs(Prompts.STYLES) do
        subs[#subs + 1] = {
            text = _(s.text),
            help_text = _(s.help),
            checked_func = function()
                return Prompts.normalizeStyleKey(Config:get("reply_style")) == s.key
            end,
            callback = function()
                Config:set("reply_style", s.key)
                UIManager:show(InfoMessage:new{
                    text = T(_([[已切换 AI 回复风格：%1
回复时请以“%2”的身份说话。

%3

下一次提问立即生效；同一段话按风格分别缓存，换风格不会命中旧回答。]]),
                        _(s.text), Prompts.PERSONA_NAME, _(s.help)),
                })
            end,
        }
    end
    return subs
end

function SettingsUI:buildMenu(plugin)
    local items = {}

    -- 高频入口放最前（一级子菜单，点击即达）
    items[#items + 1] = {
        text = _("呼出 AI 助手"),
        keep_menu_open = true,
        callback = function()
            if plugin and plugin.onYWBFOpenAssistant then
                plugin:onYWBFOpenAssistant()
            end
        end,
    }

    -- API Key
    local current = DeepSeek:getApiKey()
    items[#items + 1] = {
        text = _("API Key 配置"),
        keep_menu_open = true,
        -- 括号里只给状态，不给内容（见 showApiKeyDialog 上方那段说明）
        text_func = function()
            return DeepSeek:getApiKey()
                and _("API Key 配置（已设置）")
                or _("API Key 配置（未设置）")
        end,
        callback = function() SettingsUI:showApiKeyDialog() end,
    }

    items[#items + 1] = {
        text = _("从文件导入 API Key"),
        keep_menu_open = true,
        callback = function() SettingsUI:importApiKeyFromFile() end,
    }

    items[#items + 1] = {
        text = _("测试 DeepSeek 连接"),
        keep_menu_open = true,
        callback = function() SettingsUI:testConnection() end,
    }

    -- 模型选择
    local model_items = {}
    for _i, m in ipairs(MODELS) do
        model_items[#model_items + 1] = {
            text = m.text,
            checked_func = function() return Config:get("model") == m.key end,
            callback = function()
                Config:set("model", m.key)
                UIManager:show(InfoMessage:new{ text = T(_("已切换模型：%1"), m.key) })
            end,
        }
    end
    items[#items + 1] = {
        text = _("模型选择"),
        sub_item_table = model_items,
    }

    -- AI 回复风格（7 选 1）：parent 项实时显示当前风格，不用点进去才知道选了啥
    items[#items + 1] = {
        text = _("AI 回复风格"),
        help_text = T(_([[
决定“%1”用什么样的语气说话——无论选哪一种，跟你对话的都是他。

只影响表达方式，不影响事实边界：无论哪种风格，都仍受「只基于上下文回答」
和防剧透约束的限制，两者冲突时以那些约束为准。]]), Prompts.PERSONA_NAME),
        text_func = function()
            return T(_("AI 回复风格（%1）"),
                _(Prompts.styleText(Config:get("reply_style")))) -- luacheck: ignore
        end,
        sub_item_table = SettingsUI:buildReplyStyleMenu(),
    }

    -- 防剧透（M3：开关 + 粒度 + 进度自检，改完即时生效）
    items[#items + 1] = {
        text = _("防剧透模式"),
        text_func = function()
            local on = Config:get("spoiler_guard") == true
            local g = Config:get("spoiler_granularity")
            local gname = (g == Spoiler.GRANULARITY_PERCENT) and _("百分比")
                or (g == Spoiler.GRANULARITY_COLLECTION and _("作品") or _("章节"))
            return T(_("防剧透模式（%1 · %2）"), on and _("已开启") or _("已关闭"), gname) -- luacheck: ignore
        end,
        sub_item_table = SettingsUI:buildSpoilerMenu(plugin),
    }

    -- 轻问的异步回复入口
    items[#items + 1] = {
        text = _("查看最近回复"),
        keep_menu_open = true,
        callback = function()
            if plugin and plugin.showLastReply then
                plugin:showLastReply()
            end
        end,
    }

    -- 轻问回复的呈现方式（默认直接弹出，不用去菜单里找）
    items[#items + 1] = {
        text = _("轻问回复直接弹出"),
        help_text = _([[
开启（默认）：轻问的回复到达后直接弹出结果卡片，问题和回答一起显示，不必去菜单里翻。
关闭：只在顶部发一条通知，回复存在「查看最近回复」里，不打断你的阅读。]]),
        checked_func = function() return Config:get("light_auto_popup") ~= false end,
        callback = function()
            local v = Config:get("light_auto_popup")
            Config:set("light_auto_popup", not v)
            UIManager:show(InfoMessage:new{
                text = (not v) and _("轻问回复会直接弹出")
                              or _("轻问只在顶部通知，回复可在「查看最近回复」中查看"),
            })
        end,
    }

    -- 「你可能想问」：给提不出问题的用户几条本地生成的建议问题
    items[#items + 1] = {
        text = _("提问框显示建议问题"),
        help_text = _([[开启（默认）：深聊和轻问的输入框里多一个「你可能想问」入口，
        点开是几条根据当前选中文本现算的问题，选中后回填到输入框，可改可发。

        建议问题是本地生成的，不走 AI，不消耗额度、也不用等网络。
        觉得占地方就关掉。]]),
        checked_func = function() return Config:get("show_suggestions") ~= false end,
        callback = function()
            local v = Config:get("show_suggestions")
            Config:set("show_suggestions", not v)
            UIManager:show(InfoMessage:new{
                text = (not v) and _("提问框会显示「你可能想问」")
                              or _("提问框不再显示建议问题"),
            })
        end,
    }

    -- 「你可能想问」里的 AI 出题按钮（kind = ideas）
    items[#items + 1] = {
        text = T(_("让%1帮我提问"), Prompts.PERSONA_NAME),
        help_text = T(_([[开启（默认）：「你可能想问」里多一个「让%1来问（用一次额度）」按钮，
        点一下由 AI 针对你选中的那段文字现出几条问题。

        这跟本地建议不是一回事：本地那几条是通用的（「这段讲了什么」），
        AI 才能问出「他为什么偏偏在这个时点说这句话」这种贴着文本的问题。

        代价是它会真实调用一次 API（上限 300 token），所以按钮上写明了「用一次额度」。
        同一段文字再点会命中缓存，不重复花钱。
        不想花这个额度就关掉，关掉后「你可能想问」仍是零开销的本地建议。

        同样受防剧透保护：AI 只会基于你已经读到的内容提问。]]), Prompts.PERSONA_NAME),
        checked_func = function() return Config:get("ai_suggestions") ~= false end,
        callback = function()
            local v = Config:get("ai_suggestions")
            Config:set("ai_suggestions", not v)
            UIManager:show(InfoMessage:new{
                text = (not v) and T(_("「你可能想问」里会出现「让%1来问」按钮"), Prompts.PERSONA_NAME)
                              or _("「你可能想问」只保留本地建议，不再消耗额度"),
            })
        end,
    }

    -- 用量统计
    items[#items + 1] = {
        text = _("用量统计"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(InfoMessage:new{ text = Tokens.formatUsage() })
        end,
    }

    -- 账户余额（只读取 DeepSeek 的 /user/balance，不携带任何书籍内容）
    items[#items + 1] = {
        text = _("查询账户余额"),
        help_text = _([[向 api.deepseek.com 查询当前 API Key 还剩多少额度。

只读取余额，不发送任何书籍正文或选中文本，也不消耗额度。]]),
        keep_menu_open = true,
        callback = function() SettingsUI:queryBalance() end,
    }

    -- 数据与隐私
    items[#items + 1] = {
        text = _("数据与隐私"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(InfoMessage:new{
                text = T(_([[数据位置：%1

· 阅读进度、笔记、对话、X-Ray 数据全部只存本机插件目录
· AI 请求只在你主动触发时发生，且仅发往 api.deepseek.com
· 插件无任何使用统计上报]]), tostring(Config.paths.data)),
            })
        end,
    }

    items[#items + 1] = {
        text = _("清空全部本地数据"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("将删除对话记录、缓存与 X-Ray 数据（不含 API Key）。确定？"),
                ok_text = _("删除"),
                cancel_text = _("取消"),
                ok_callback = function()
                    -- TODO(M4/M5)：实现目录清理
                    UIManager:show(InfoMessage:new{ text = _("（M1 占位）清理功能将在后续里程碑实现") })
                end,
            })
        end,
    }

    return items
end

return SettingsUI
