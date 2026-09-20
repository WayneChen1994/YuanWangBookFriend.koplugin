--[==[
QA 独立验证：**提示语拟人化**（等待/结果/失败这几处提示，从"AI …"改成"小望…"）。

为什么单独写一份：
  提示语是**用户唯一能感知到"有个角色在跟他对话"的地方**。这类改动最容易"看起来改了"（源码里 grep 得到），
  但真正跑到 UI 上可能根本没走到那一行（比如走了缓存分支、走了另一条提示分支）。
  所以这里一律做**行为断言**：打桩记下 Trapper:info / Notification:notify 收到的**真实字符串**，
  再对那串字符做断言 —— 不看源码有没有那一行。

三条硬规矩（团队 2026-09-19 定的）：
  1. 断言里**不许写死"小望"**，一律拿 Prompts.PERSONA_NAME 去比 —— 写死了以后改名就假红；
  2. 只验该改的：等待中 / 已提交 / 回复就绪 / 请求失败这四处；
  3. **反向守住不该改的**：「AI 回复风格」是功能名（设置菜单项 + prompts 注释），必须**保留字面**，
     防止有人"顺手统一"把它也改成"小望回复风格"。

跑法（KPW4）：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     YWBF_PLUGIN_DIR=/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin \
     YWBF_TEST_DIR=/mnt/us/ywbf_dev/testdata \
     ./luajit /mnt/us/ywbf_dev/tools/qa_verify_persona.lua
--]==]

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR") or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"
local TEST_DIR = os.getenv("YWBF_TEST_DIR") or "/mnt/us/ywbf_dev/testdata"

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

-- ================= KOReader UI 打桩（记录型） =================
local notified, trapped, infos = {}, {}, {}

local function newInputDialog(_self, t)
    local o = { _kind = "input", _t = t or {}, _input = (t and t.input) or "" }
    function o:setInputText(s) self._input = s end
    function o:getInputText() return self._input end
    function o:onShowKeyboard() end
    return o
end
package.loaded["ui/widget/inputdialog"] = { new = newInputDialog }
package.loaded["ui/widget/buttondialog"] = { new = function(_self, t) return t or {} end }
package.loaded["ui/widget/infomessage"] = {
    new = function(_self, t) t = t or {} infos[#infos + 1] = t return t end,
}
package.loaded["ui/widget/confirmbox"] = { new = function(_self, t) return t or {} end }
package.loaded["ui/widget/textviewer"] = { new = function(_self, t) return t or {} end }
-- Notification 打桩：**记下每一次 notify 的真实文案**（这才是行为断言的对象）
package.loaded["ui/widget/notification"] = {
    SOURCE_ALWAYS_SHOW = 1,
    notify = function(_self, text)
        notified[#notified + 1] = tostring(text)
    end,
}
package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function() end,
    scheduleIn = function(_self, _n, fn) return fn() end,
}
-- Trapper 打桩：wrap 直接跑（不进真协程），info 记下真实文案
package.loaded["ui/trapper"] = {
    wrap = function(_self, fn) return fn() end,
    info = function(_self, text) trapped[#trapped + 1] = tostring(text) end,
    isWrapped = function() return false end,
    clear = function() end,
}
package.loaded["device"] = { screen = nil }
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/size"] = { padding = { large = 1 }, margin = { small = 1 } }
package.loaded["ui/rendertext"] = { sizeUtf8Text = function() return { x = 0 } end }
package.loaded["gettext"] = setmetatable({}, {
    __call = function(_self, s) return s end,
})
package.loaded["logger"] = {
    info = function() end, warn = function() end,
    dbg = function() end, err = function() end,
}

-- Queue 打桩：同步跑完 fn → on_done / on_error，不做退避重试（真队列会 sleep 1s/2s/4s，测试里没必要等）
package.loaded["ywbf/queue"] = {
    items = {},
    init = function(self) self.items = {} return self end,
    clear = function(self) self.items = {} end,
    size = function(self) return #self.items end,
    submit = function(self, task)
        if type(task) ~= "table" or type(task.fn) ~= "function" then return false end
        self.items[#self.items + 1] = task
        return true
    end,
    process = function(self)
        while #self.items > 0 do
            local task = table.remove(self.items, 1)
            local ok, result, err = pcall(task.fn)
            if ok and err == nil then
                if task.on_done then pcall(task.on_done, result) end
            else
                local msg = ok and tostring(err) or tostring(result)
                if task.on_error then pcall(task.on_error, msg) end
            end
        end
        return true
    end,
}

-- T（模板替换 %1）：优先用真 ffi/util，取不到才回落自己的一份，免得环境差异把脚本带崩
local util_ok, real_util = pcall(require, "ffi/util")
if not (util_ok and type(real_util) == "table" and type(real_util.template) == "function") then
    package.loaded["ffi/util"] = {
        template = function(fmt, ...)
            local args = { ... }
            return (tostring(fmt):gsub("%%(%d)", function(n)
                return tostring(args[tonumber(n)])
            end))
        end,
    }
end

local Config = require("ywbf/config")
local HttpClient = require("ywbf/httpclient")
local Prompts = require("ywbf/prompts")
Config:init(TEST_DIR)
-- 配置是同步落盘的（我踩过）：先把本套件依赖的开关钉成基线
Config:set("cache_enabled", true)
Config:set("ai_suggestions", true)
Config:set("spoiler_guard", true)
Config:set("spoiler_granularity", "chapter")
local Cache = require("ywbf/cache")
local Crypto = require("ywbf/crypto")
local DeepSeek = require("ywbf/deepseek")
Cache:init()

-- ================= 断言骨架 =================
local TOTAL, PASSED, FAILED = 0, 0, 0
local function ok(cond, name, extra)
    TOTAL = TOTAL + 1
    if cond then PASSED = PASSED + 1; print("  PASS  " .. name)
    else
        FAILED = FAILED + 1
        print("  FAIL  " .. name .. (extra and (" -> " .. tostring(extra)) or ""))
    end
end
local function section(t) print(""); print("=== " .. t .. " ===") end
local function has(s, sub)
    return type(s) == "string" and type(sub) == "string" and sub ~= "" and s:find(sub, 1, true) ~= nil
end
local function hasNot(s, sub) return not has(s, sub) end
local function readFile(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local s = f:read("*all"); f:close(); return s
end
local function dump(t)
    local out = {}
    for _i, v in ipairs(t or {}) do out[#out + 1] = tostring(v) end
    return table.concat(out, " ｜ ")
end

-- ================= 0 前置：人设名从源码取，绝不写死 =================
section("0. 前置：人设名只能从 Prompts.PERSONA_NAME 取")
local NAME = Prompts.PERSONA_NAME
ok(type(NAME) == "string" and NAME ~= "",
    "0：（前置）Prompts.PERSONA_NAME 是个非空字符串（后面所有断言都以它为准，不写死字眼）",
    tostring(NAME))
-- 旧字面清单：这些是"看起来像中转站"的说法，改完之后一处都不该出现
local OLD = {
    "AI 思考中",      -- 等待中（asker:231 / chatdialog:245）
    "已提交给 AI",    -- 轻问提交（asker:253）
    "AI 回复已就绪",  -- 回复就绪（asker:282）
    "AI 请求失败",    -- 请求失败（asker:295）
}
-- 行为断言的统一口径：含人设名 + 不含任何旧字面
local function checkPersona(s, what)
    ok(has(s, NAME),
        what .. "：提示里有人设名（" .. NAME .. "）——用户看到的是「有个角色在跟他说话」",
        tostring(s))
    local hit = nil
    for _i, old in ipairs(OLD) do if has(s, old) then hit = old end end
    ok(hit == nil, what .. "：提示里没有旧字面（AI 思考中 / 已提交给 AI / AI 回复已就绪 / AI 请求失败）",
        tostring(s))
end

-- ================= HTTP 桩 =================
local REPLY = "这段写的是雪夜里的灯。"
local FAIL_NOW = false
HttpClient.post = function(_url, _headers, _body)
    if FAIL_NOW then return nil, 0, "", "qa: simulated failure" end
    local json = require("json")
    return json.encode({
        choices = { { message = { content = REPLY }, finish_reason = "stop" } },
        usage = { prompt_tokens = 10, completion_tokens = 10, total_tokens = 20 },
    }), 200, "OK", nil
end

if Crypto:init() then DeepSeek:setApiKey("qa-persona-key") end
if not DeepSeek:hasApiKey() then DeepSeek.getApiKey = function() return "qa-persona-key" end end

local Asker = require("ui/asker")
local ChatDialog = require("ui/chatdialog")
ok(type(Asker) == "table" and type(ChatDialog) == "table",
    "0：ui/asker.lua 与 ui/chatdialog.lua 在打桩环境里被真的 require 进来（跑的是真代码）")

local SELECTED = "雪停了，檐下的铁马不再作响，他却偏偏在这时提起了灯。"
local PAGE_TEXT = "（已读）第一章 灯下\n" .. SELECTED .. "\n（已读）第二章 寒砧"
local PROG = { chapter = 3, total = 10, title = "第三章", read_chapters = { [1] = true, [2] = true, [3] = true } }

-- ================= 1 深聊提交（chatdialog 的等待提示） =================
section("1. 深聊提交：等待提示要说人话")
do
    trapped = {}
    ChatDialog:open(nil, {
        seed_question = "他为什么偏偏此时提灯？",
        selected = SELECTED, page_text = PAGE_TEXT,
        book_fp = "persona_chat_fp", progress = PROG,
    })
    ok(#trapped >= 1, "1：深聊提交确实弹过等待提示（前置：这条路径真的走到了）", dump(trapped))
    if #trapped >= 1 then checkPersona(trapped[1], "1：深聊等待提示") end
end

-- ================= 2 即时提问（asker:askAndShow 的等待提示） =================
section("2. 即时提问（释义/摘要/深聊即时）的等待提示")
do
    trapped = {}
    Asker:askAndShow({
        kind = "explain", title = "远望书友",
        selected = SELECTED, page_text = PAGE_TEXT,
        book_fp = "persona_ask_fp", progress = PROG,
    })
    ok(#trapped >= 1, "2：即时提问确实弹过等待提示（前置）", dump(trapped))
    if #trapped >= 1 then checkPersona(trapped[1], "2：即时提问等待提示") end
end

-- ================= 3 轻问提交 + 回复就绪 =================
section("3. 轻问：提交提示 与 回复就绪提示")
do
    Cache:clear()
    notified = {}
    local plugin = {}
    Asker:submitAsync(plugin, {
        kind = "light", question = "这盏灯意味着什么？",
        selected = SELECTED, page_text = PAGE_TEXT,
        book_fp = "persona_light_fp", progress = PROG,
    })
    ok(#notified >= 1, "3：轻问提交后确实发过一条通知（前置）", dump(notified))
    if #notified >= 1 then checkPersona(notified[1], "3：轻问提交提示") end

    -- 队列在我的 UIManager 桩里是同步跑完的（scheduleIn 直接执行 fn），
    -- 所以"提交"和"就绪"两条通知在 submitAsync 返回时就都已经在记录了：
    -- 第 1 条 = 提交提示，最后 1 条 = 就绪提示。
    -- 不按关键词去筛：按"就绪/回复"筛会让断言依赖措辞，万一文案换成「小望想好了」，
    -- 筛选先红、真正的断言反而跑不到（那是措辞问题，不该和拟人化混在一起报）。
    ok(#notified >= 2, "3：轻问走完后至少留下 2 条通知（提交 + 就绪）", dump(notified))
    if #notified >= 2 then checkPersona(notified[#notified], "3：回复就绪提示") end
end

-- ================= 4 失败通知 =================
section("4. 失败通知：也要说人话")
do
    Cache:clear()
    notified = {}
    FAIL_NOW = true
    local plugin = {}
    Asker:submitAsync(plugin, {
        kind = "light", question = "这盏灯意味着什么？",
        selected = SELECTED, page_text = PAGE_TEXT,
        book_fp = "persona_fail_fp", progress = PROG,
    })
    FAIL_NOW = false
    ok(#notified >= 2, "4：失败时至少留下 2 条通知（提交 + 失败）", dump(notified))
    if #notified >= 2 then
        local failed = notified[#notified]
        checkPersona(failed, "4：请求失败提示")
        -- 措辞这条是单加的：拟人化是为了"有个角色在跟你对话"，不是让它背故障的锅。
        -- 网络/鉴权失败时请求根本没送达，写「%1没答上来」等于告诉用户"它答不上来" ——
        -- 那是把一个工程故障说成了人设的能力问题。所以这条和"含人设名"必须同时成立。
        ok(hasNot(failed, "没答上来"),
            "4：失败措辞里没有「没答上来」（失败的是送达，不是他答不上来）", failed)
    end
end

-- ================= 5 静态兜底：旧字面一处不留 =================
-- 行为断言只能覆盖我跑得到的那几条路径；源码里若还藏着一处没被我触发的旧字面，
-- 静态扫描能把它兜出来（两条互补，不是二选一）。
section("5. 静态兜底：该改的两个文件里一处旧字面都不留")
do
    local files = { "ui/asker.lua", "ui/chatdialog.lua" }
    for _i, rel in ipairs(files) do
        local src = readFile(PLUGIN_DIR .. "/" .. rel)
        ok(type(src) == "string" and #src > 200,
            "5：（前置）" .. rel .. " 读得到（读不到的话下面几条就是假绿）",
            src and #src or nil)
        if type(src) == "string" then
            for _j, old in ipairs(OLD) do
                ok(hasNot(src, old), "5：" .. rel .. " 里没有旧字面「" .. old .. "」")
            end
        end
    end
end

-- ================= 6 反向：功能名「AI 回复风格」必须保留字面 =================
-- 这是"帮倒忙的统一"高发区：有人看到满屏「小望」，顺手把设置菜单里的功能名也改了。
-- 那不是提示语，是**功能名**，改了会让用户找不到原来的设置项。
section("6. 反向守住：「AI 回复风格」是功能名，必须保留字面")
do
    local targets = {
        { rel = "ui/settings.lua", why = "设置菜单项" },
        { rel = "ywbf/prompts.lua", why = "prompts 注释里的引用" },
    }
    for _i, t in ipairs(targets) do
        local src = readFile(PLUGIN_DIR .. "/" .. t.rel)
        ok(type(src) == "string" and #src > 200,
            "6：（前置）" .. t.rel .. " 读得到（读不到的话下面两条就是假绿）",
            src and #src or nil)
        if type(src) == "string" then
            ok(has(src, "AI 回复风格"),
                "6：" .. t.rel .. "（" .. t.why .. "）仍然保留字面「AI 回复风格」（功能名不许跟着拟人化）")
            ok(hasNot(src, NAME .. "回复风格"),
                "6：" .. t.rel .. " 没有被改成「" .. NAME .. "回复风格」（那会让用户找不到原设置项）")
        end
    end
end

-- ================= 7 设置菜单里的拟人化（行为级） =================
-- 这一节同样是**行为断言**：真的 buildMenu 建出菜单表，再对菜单标题 / help_text /
-- 点开关后弹出的回执文案做断言 —— 不看源码里那一行写没写。
-- 为什么连菜单都要拟人：菜单标题写「让 AI 帮我提问」、实际按钮却是「让%1来问」，
-- 同一屏两种叫法，用户会以为是两个不同的功能。
section("7. 设置菜单：同一功能统一叫法 + help_text 不再自相矛盾")
do
    local SettingsUI = require("ui/settings")
    Config:set("reply_style", "professional")
    local okm, menu = pcall(function() return SettingsUI:buildMenu(nil) end)
    ok(okm and type(menu) == "table" and #menu > 0,
        "7：（前置）设置菜单真的建出来了（建不出来下面全是假绿）",
        okm and (type(menu) == "table" and #menu or tostring(menu)) or tostring(menu))
    if okm and type(menu) == "table" then
        local function shown(it)
            if type(it.text) == "string" then return it.text end
            if type(it.text_func) == "function" then
                local okf, s = pcall(it.text_func)
                if okf and type(s) == "string" then return s end
            end
            return ""
        end
        local texts, ai_item, style_item = {}, nil, nil
        for _i, it in ipairs(menu) do
            local t = type(it) == "table" and shown(it) or ""
            texts[#texts + 1] = t
            if has(t, "帮我提问") then ai_item = it end
            if has(t, "回复风格") then style_item = it end
        end

        -- ① 菜单标题：「让 AI 帮我提问」→「让%1帮我提问」
        ok(ai_item ~= nil, "7：（前置）菜单里找得到「让…帮我提问」那个开关", table.concat(texts, " ｜ "))
        if ai_item then
            local t = shown(ai_item)
            ok(has(t, NAME), "7①：菜单标题用的是人设名（让" .. NAME .. "帮我提问）", t)
            ok(hasNot(t, "AI"),
                "7①：标题里没有「AI」——菜单叫 AI、按钮叫" .. NAME .. "，同一屏两种叫法", t)
            -- ② help_text：原来同一句里既有 AI 又有角色名，自相矛盾
            local help = type(ai_item.help_text) == "string" and ai_item.help_text or ""
            ok(has(help, NAME), "7②：help_text 里有人设名", help)
            ok(hasNot(help, "决定 AI 用什么样的语气说话"),
                "7②：help_text 不再是「决定 AI 用什么样的语气说话」（同一句里既有 AI 又有角色名是自相矛盾）",
                help)
            -- ③ 回执：把开关切到"开"，抓真实弹出的 InfoMessage 文案
            if type(ai_item.callback) == "function" then
                infos = {}
                Config:set("ai_suggestions", false)   -- 从"关"切到"开"，才会走那句回执
                local okc, errc = pcall(ai_item.callback)
                ok(okc, "7③：（前置）点开关的回调没抛异常", errc)
                local receipt = (type(infos[#infos]) == "table") and infos[#infos].text or nil
                ok(type(receipt) == "string", "7③：（前置）开关回执真的弹出来了", tostring(receipt))
                if type(receipt) == "string" then
                    ok(has(receipt, "让" .. NAME .. "来问"),
                        "7③：回执里说的是「让" .. NAME .. "来问」按钮（跟实际按钮同一个叫法）", receipt)
                    ok(hasNot(receipt, "AI 出题"),
                        "7③：回执里不再有「AI 出题」（菜单/回执叫 AI、按钮叫" .. NAME .. "的日子结束了）",
                        receipt)
                end
                Config:set("ai_suggestions", true)
            end
        end

        -- ④ 反向：功能名「AI 回复风格」在**菜单里**也必须是字面（行为级，不只是源码扫描）
        ok(style_item ~= nil, "7：（前置）菜单里找得到回复风格那一项", table.concat(texts, " ｜ "))
        if style_item then
            local st = shown(style_item)
            ok(has(st, "AI 回复风格"),
                "7④：菜单名仍是字面「AI 回复风格」（功能名，不是交互提示，不许跟着拟人化）", st)
            ok(hasNot(st, NAME .. "回复风格"),
                "7④：菜单名没被顺手改成「" .. NAME .. "回复风格」（用户会找不到原设置项）", st)
        end
    end
end

print("")
print(string.format("TOTAL: %d  PASSED: %d  FAILED: %d", TOTAL, PASSED, FAILED))
print("（人设名取自 Prompts.PERSONA_NAME = " .. tostring(NAME) .. "，本脚本未写死任何字眼）")
