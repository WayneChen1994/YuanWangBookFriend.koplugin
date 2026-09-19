--[==[
QA 独立验证：「AI 引导式提问」（kind = ideas）。

为什么还要写第二份：工程师自己的 probe_ideas.lua 是**直接调 Asker:askSync**
并把 progress 亲手塞进去的——它验的是管道，不是接线。而 M3 那次 P0 事故
（main.lua 忘了传 progress，四道防线静默失效）恰恰就是"管道没问题、接线漏了"。
所以这份脚本专门走**完整 UI 路径**：
  ChatDialog:open / ToastCard:open → 点「你可能想问」→ 点「让小望来问（用一次额度）」
  → SuggestPicker:showAi → Asker:askSync → DeepSeek:chat → 抓真请求体
进度是由 UI 自己从 opts 里带下来的，我在断言之外不碰它——这样"UI 漏传 progress"
才可能变红。

另一条独立性的来源：夹具全是我自己的（10 章《灯下漫笔》，读到第 3 章，
第 7 章是未读），AI 返回样本也是我自己编的，不复用他的 CANNED。

跑法（KPW4）：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     YWBF_PLUGIN_DIR=/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin \
     YWBF_TEST_DIR=/mnt/us/ywbf_dev/testdata \
     ./luajit /mnt/us/ywbf_dev/tools/qa_verify_ideas.lua
--]==]

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR") or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"
local TEST_DIR = os.getenv("YWBF_TEST_DIR") or "/mnt/us/ywbf_dev/testdata"

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

-- ================= KOReader UI 打桩（记录型 + 真 widget 栈） =================
local stack, events = {}, {}
local input_dialogs, button_dialogs = {}, {}

local function kindOf(w)
    if type(w) ~= "table" then return "?" end
    return w._kind or "?"
end
local function snapshot()
    local out = {}
    for _i, w in ipairs(stack) do out[#out + 1] = kindOf(w) end
    return out
end
local function push(w)
    events[#events + 1] = { op = "show", kind = kindOf(w), w = w, before = snapshot() }
    stack[#stack + 1] = w
end
local function pop(w)
    for i = #stack, 1, -1 do
        if stack[i] == w then table.remove(stack, i) break end
    end
    events[#events + 1] = { op = "close", kind = kindOf(w), w = w, before = snapshot() }
end
local function stackHas(kind)
    for _i, w in ipairs(stack) do if kindOf(w) == kind then return true end end
    return false
end
local function listHas(t, kind)
    for _i, k in ipairs(t) do if k == kind then return true end end
    return false
end
local function resetUI()
    stack, events, input_dialogs, button_dialogs = {}, {}, {}, {}
end

local function newInputDialog(_self, t)
    local o = { _kind = "input", _t = t or {}, _input = (t and t.input) or "" }
    function o:setInputText(s) self._input = s end
    function o:getInputText() return self._input end
    function o:onShowKeyboard() end
    input_dialogs[#input_dialogs + 1] = o
    return o
end

package.loaded["ui/widget/inputdialog"] = { new = newInputDialog }
package.loaded["ui/widget/buttondialog"] = {
    new = function(_self, t) t = t or {} t._kind = "button" button_dialogs[#button_dialogs + 1] = t return t end,
}
package.loaded["ui/widget/infomessage"] = {
    new = function(_self, t) t = t or {} t._kind = "info" return t end,
}
package.loaded["ui/widget/confirmbox"] = { new = function(_self, t) return t or {} end }
package.loaded["ui/widget/textviewer"] = {
    new = function(_self, t) t = t or {} t._kind = "viewer" return t end,
}
package.loaded["ui/widget/notification"] = { SOURCE_ALWAYS_SHOW = 1, notify = function() end }
package.loaded["ui/uimanager"] = {
    show = function(_self, w) push(w) end,
    close = function(_self, w) pop(w) end,
    scheduleIn = function(_self, _n, fn) return fn() end,
}
package.loaded["ui/trapper"] = {
    wrap = function(_self, fn) return fn() end,
    info = function() end, isWrapped = function() return false end, clear = function() end,
}
package.loaded["device"] = { screen = nil }
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/size"] = { padding = { large = 1 }, margin = { small = 1 } }
package.loaded["ui/rendertext"] = { sizeUtf8Text = function() return { x = 0 } end }
package.loaded["gettext"] = function(s) return s end
package.loaded["logger"] = {
    info = function() end, warn = function() end,
    dbg = function() end, err = function() end,
}

-- Store 换成记录仪：ideas 不该往历史里写一个字
local store_calls = {}
package.loaded["ywbf/store"] = {
    append = function(_self, _fp, item)
        store_calls[#store_calls + 1] = { kind = item and item.kind }
    end,
}

-- 假网络层：记账 + 回一段我自己编的 AI 输出
local http_calls, bodies = 0, {}
local CANNED = "好的，以下是我想到的：\n"
    .. "1. 他为什么偏偏此时提灯？\n"
    .. "- 雪夜的沉默说明了什么？\n"
    .. "「仔细」二字在提醒谁？\n"
    .. "他为何不答\n"
    .. "4、窗外的人是谁？"
local REPLY = CANNED
-- 桩里能注入 DeepSeek 的 finish_reason（"stop" = 正常结束 / "length" = 被 max_tokens 截断）。
-- 这是"被截断的残句"唯一可靠的判据来源：parseList 只看文本，区分不了残句和漏写问号的整句。
local FINISH = "stop"
package.loaded["ywbf/httpclient"] = {
    post = function(_url, _headers, body, _timeout)
        http_calls = http_calls + 1
        bodies[#bodies + 1] = body
        local json = require("json")
        return json.encode({
            choices = { { message = { content = REPLY }, finish_reason = FINISH } },
            usage = { prompt_tokens = 120, completion_tokens = 60, total_tokens = 180 },
        }), 200, "OK", nil
    end,
    get = function() return nil, 0, "", "qa: no network" end,
}

local json = require("json")
local Util = require("ywbf/util")
local Config = require("ywbf/config")
local Spoiler = require("ywbf/spoiler")
local Prompts = require("ywbf/prompts")
Config:init(TEST_DIR)
--[[--
基线钉死：**配置是同步落盘的**（Config:set 立刻写 settings.json）。
我踩过一次：2d 把 cache_enabled 设成 false，那一节中途抛异常就没走到还原那行，
于是下一轮进程一启动就是"缓存关着"，2b 四条凭空变红（164 里红 4 条，重跑又全绿）。
已用 /mnt/us/ywbf_dev/tools/qa_setcache.lua 反向复现过：手工把落盘值设成 false，
再跑一次就是那同样的 4 条红 —— 根因确认是"上一轮的残留配置"，不是源码。
所以开局先把本套件依赖的两个开关按基线写入，任何一轮都不继承上一轮的状态。
--]]
Config:set("cache_enabled", true)
Config:set("ai_suggestions", true)
local Cache = require("ywbf/cache")
local Crypto = require("ywbf/crypto")
local DeepSeek = require("ywbf/deepseek")
local Suggest = require("ywbf/suggest")

-- ================= 断言骨架 =================
local TOTAL, PASSED, FAILED = 0, 0, 0
local failures = {}
local function ok(cond, name, extra)
    TOTAL = TOTAL + 1
    if cond then PASSED = PASSED + 1; print("  PASS  " .. name)
    else
        FAILED = FAILED + 1
        failures[#failures + 1] = name
        print("  FAIL  " .. name .. (extra and (" -> " .. tostring(extra)) or ""))
    end
end
local function eq(a, b, name)
    ok(a == b, name, string.format("got=%s want=%s", tostring(a), tostring(b)))
end
local function known(cond, name, extra)
    -- 已知边界：写下来给人看，不计红（一旦修好它会变绿吗？不会——所以名字里写清"待什么条件"）
    TOTAL = TOTAL + 1
    PASSED = PASSED + 1
    print(string.format("  KNOWN %s%s", name,
        cond and "" or ("  [现状不符] " .. tostring(extra))))
end
local function section(t) print(""); print("=== " .. t .. " ===") end
-- 驱动层保护：被测代码抛异常时要记成一条 FAIL，而不是让脚本半路崩掉没有结论。
-- （只在真的抛了异常时才计数，所以基线总数不受它影响。）
local function callp(fn, name)
    local ok_c, err = pcall(fn)
    if not ok_c then
        TOTAL = TOTAL + 1
        FAILED = FAILED + 1
        failures[#failures + 1] = name
        print(string.format("  FAIL  %s -> %s", name, tostring(err)))
    end
    return ok_c
end
local function has(s, sub)
    return type(s) == "string" and type(sub) == "string" and s:find(sub, 1, true) ~= nil
end
local function readFile(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local s = f:read("*all"); f:close(); return s
end

-- 把请求体解成 { system=, user=, max_tokens=, whole= }
local function lastPayload()
    local body = bodies[#bodies] or ""
    local ok_dec, payload = pcall(json.decode, body)
    if not ok_dec or type(payload) ~= "table" then return nil end
    local system, user = "", ""
    for _i, m in ipairs(payload.messages or {}) do
        if m.role == "system" then system = m.content or "" end
        if m.role == "user" then user = m.content or "" end
    end
    return {
        raw = body, payload = payload,
        system = system, user = user,
        whole = system .. "\n" .. user,
        max_tokens = payload.max_tokens,
    }
end

-- ================= 夹具：10 章《灯下漫笔》，读到第 3 章，第 7 章未读 =================
local TOC = {}
for i = 1, 10 do
    TOC[i] = { title = "第" .. tostring(i) .. "章 灯下其" .. tostring(i), page = (i - 1) * 20 + 1 }
end
TOC[7].title = "第七章 孤灯密语"

local LEAK_TITLE = "第七章 孤灯密语"
local LEAK_BODY = "真凶是提灯的哑巴仆人QWERTY"
local SELECTED = "他把灯放到窗下，回头看了一眼门槛，低声说：“仔细风大。”"
local PAGE_TEXT = "（已读）雪停了，檐下的铁马不再作响。\n" .. SELECTED .. "\n"
    .. LEAK_TITLE .. "\n" .. LEAK_BODY .. "，这件事要到很久以后才有人提起。"

local PROG = {
    ok = true, enabled = true,
    granularity = Spoiler.GRANULARITY_CHAPTER,
    chapter = "第三章 灯下其三", chapter_index = 3, chapter_total = 10,
    page = 41, total = 200, percent = 20.5, toc = TOC,
}

-- ================= 0 前置 =================
section("0. 前置：模块真加载、默认值、夹具本身含泄漏串")
local SuggestPicker = require("ui/suggestpicker")
local ChatDialog = require("ui/chatdialog")
local ToastCard = require("ui/toastcard")
local Asker = require("ui/asker")
ok(type(SuggestPicker) == "table" and type(SuggestPicker.showAi) == "function",
    "ui/suggestpicker.lua 真加载，showAi 在")
ok(type(ChatDialog) == "table" and type(ToastCard) == "table", "chatdialog / toastcard 真加载")
if Crypto:init() then DeepSeek:setApiKey("qa-ideas-key") end
if not DeepSeek:hasApiKey() then DeepSeek.getApiKey = function() return "qa-ideas-key" end end
Cache:init()
Config:set("show_suggestions", true)
Config:set("ai_suggestions", true)
Config:set("spoiler_guard", true)
Config:set("spoiler_granularity", "chapter")

eq(Config:get("ai_suggestions"), true, "ai_suggestions 默认开启")
eq(Config:get("max_tokens_ideas"), 300, "max_tokens_ideas = 300")
eq(Prompts.LIMIT.ideas, 300, "Prompts.LIMIT.ideas = 300")
ok(has(PAGE_TEXT, LEAK_TITLE) and has(PAGE_TEXT, LEAK_BODY),
    "前置：夹具原文里确实含未读章节标题与未读正文（下面的零命中断言不是空转）")

-- 走 UI 到「让小望来问」这一步：返回 AI 按钮行；没找到就返回 nil
local function openPickerAndFindAi(openFn, opts)
    resetUI()
    openFn(opts)
    local d = input_dialogs[#input_dialogs]
    local sbtn = nil
    for _, row in ipairs((d and d._t and d._t.buttons) or {}) do
        for _, b in ipairs(row) do if has(b.text, "你可能想问") then sbtn = b end end
    end
    if not sbtn then return nil, "输入框里没有「你可能想问」" end
    callp(sbtn.callback, "点「你可能想问」没有抛异常")
    local bd = button_dialogs[#button_dialogs]
    if not bd then return nil, "没弹出建议页" end
    for _i, row in ipairs(bd.buttons or {}) do
        if has(row[1] and row[1].text or "", "用一次额度") then
            return bd, row[1]
        end
    end
    return bd, nil
end

-- ================= 1 深聊 UI 全链路 =================
section("1. 深聊全链路：UI 自己把进度带下来，请求体里防剧透齐全")
do
    Cache:clear(); http_calls = 0; bodies = {}
    local bd, airow = openPickerAndFindAi(function(opts)
        ChatDialog:open(nil, opts)
    end, { selected = SELECTED, page_text = PAGE_TEXT, book_fp = "ideas_chat_fp", progress = PROG })
    ok(bd ~= nil, "建议页弹出来了")
    ok(type(airow) == "table", "建议页里有「让小望来问（用一次额度）」按钮", tostring(airow))
    if type(airow) == "table" then
        callp(airow.callback, "点 AI 出题按钮没有抛异常")
        eq(http_calls, 1, "点 AI 按钮后只发了 1 个请求")
        local p = lastPayload()
        ok(p ~= nil, "抓到了请求体且是合法 JSON")
        if p then
            eq(p.max_tokens, 300, "request body 的 max_tokens = 300")
            ok(has(p.system, "【防剧透约束（最高优先级）】"), "system 含防剧透抬头")
            ok(has(p.system, "第 3 / 10 章"), "system 里声明了当前进度「第 3 / 10 章」")
            local hint = Prompts.spoilerHint(PROG)
            ok(hint ~= "" and has(p.user, hint), "user 含双保险提醒：" .. hint)
            ok(has(p.user, "不得涉及尚未读到的内容"), "user 含「不得涉及尚未读到的内容」")
            -- 下面四条是变异 1 的第二类后果：把 ideas 从那一分支里摘出来，
            -- system 侧的四道防线其实都还在（spoiler_note / 物理截断 / sanitize 都不看 kind），
            -- 真正丢的是"这条回复必须能被 parseList 切成按钮"的输出契约——
            -- 不盯住它，功能就退化成"花一次钱换一段读不了的文字"。
            ok(has(p.user, "替读到这里的读者提出"), "user 确实用的是 ideas 模板本体（不是裸上下文）")
            ok(has(p.user, string.format("全部输出控制在 %d 字以内", Prompts.LIMIT.ideas)),
                "user 里的字数上限就是 Prompts.LIMIT.ideas 的真实取值（不是源码里写死的数字）")
            ok(has(p.user, string.format("每条不超过 %d 个字", Suggest.MAX_LEN)),
                "user 里的单条字数上限与 Suggest.MAX_LEN 同步（改一边忘一边这里会红）")
            ok(has(p.user, string.format("一共 %d 条", Suggest.DEFAULT_MAX)),
                "user 里的条数上限与 Suggest.DEFAULT_MAX 同步")
            ok(has(p.whole, LEAK_TITLE) == false, "未读章节标题「" .. LEAK_TITLE .. "」不在请求体里")
            ok(has(p.whole, LEAK_BODY) == false, "未读正文「" .. LEAK_BODY .. "」不在请求体里")
            ok(has(p.whole, "他把灯放到窗下"), "已读的选中原文在请求体里（否则等于没发）")
        end
        -- AI 结果页：4 条 + 返回，且不再挂 AI 按钮（防二次付费）
        local bd2 = button_dialogs[#button_dialogs]
        ok(bd2 ~= nil and bd2 ~= bd, "AI 结果页是新的一层")
        if bd2 then
            local n_ai = 0
            for _i, row in ipairs(bd2.buttons or {}) do
                if has(row[1] and row[1].text or "", "用一次额度") then n_ai = n_ai + 1 end
            end
            eq(n_ai, 0, "AI 结果页不再挂「让小望来问」（避免第二次付费）")
            eq(#bd2.buttons, 5, "AI 结果页 = 4 条问题 + 1 行「返回」")
            eq(bd2.title, "小望建议问：", "AI 结果页标题区分于本地建议")
            -- 选一条 → 回填到输入框
            local picked = bd2.buttons[1][1].text
            callp(bd2.buttons[1][1].callback, "点第 1 条建议没有抛异常")
            local nd = input_dialogs[#input_dialogs]
            eq(nd._t.input, picked, "选中一条后带回输入框（prefill == 该问题）")
            local _ok_show, shown = pcall(table.concat, Suggest.parseList(CANNED, 4), " ｜ ")
            print("  [证据] AI 解析结果：" .. tostring(shown))
        end
    end
end

-- ---------- 1b 前置（反向）：关掉防剧透，同样的路必须能看到泄漏串 ----------
section("1b. 反向对照：关掉防剧透后，同样的路径里泄漏串确实会出现")
do
    Config:set("spoiler_guard", false)
    Cache:clear(); http_calls = 0; bodies = {}
    local bd, airow = openPickerAndFindAi(function(opts) ChatDialog:open(nil, opts) end,
        { selected = SELECTED, page_text = PAGE_TEXT, book_fp = "ideas_chat_fp_off", progress = PROG })
    if type(airow) == "table" then
        callp(airow.callback, "1b 反向对照：点 AI 按钮没有抛异常")
        local p = lastPayload()
        ok(p ~= nil and has(p.whole, LEAK_BODY),
            "关掉防剧透后泄漏串确实进了请求体（证明上面的零命中是防剧透在起作用，不是夹具没送到）",
            p and (has(p.whole, LEAK_BODY) and "in" or "still missing") or "no body")
        ok(p ~= nil and has(p.system, "【防剧透约束（最高优先级）】") == false,
            "关掉后 system 里不再有防剧透抬头")
    else
        ok(false, "关掉防剧透后仍能走到 AI 按钮")
    end
    Config:set("spoiler_guard", true)
end

-- ================= 2 轻问 UI 全链路 =================
section("2. 轻问全链路：同一套接线再走一遍")
do
    Cache:clear(); http_calls = 0; bodies = {}
    local bd, airow = openPickerAndFindAi(function(opts) ToastCard:open(nil, opts) end,
        { selected = SELECTED, page_text = PAGE_TEXT, book_fp = "ideas_light_fp", progress = PROG })
    ok(type(airow) == "table", "轻问建议页里也有 AI 出题按钮", tostring(airow))
    if type(airow) == "table" then
        callp(airow.callback, "轻问：点 AI 按钮没有抛异常")
        eq(http_calls, 1, "轻问：点了 AI 按钮只发 1 个请求")
        local p = lastPayload()
        if p then
            eq(p.max_tokens, 300, "轻问：max_tokens = 300")
            ok(has(p.system, "第 3 / 10 章"), "轻问：system 里声明了进度")
            ok(has(p.user, Prompts.spoilerHint(PROG)), "轻问：user 含双保险提醒（不只是 system 那条）")
            ok(has(p.whole, LEAK_BODY) == false, "轻问：未读正文不在请求体里")
            ok(has(p.whole, LEAK_TITLE) == false, "轻问：未读章节标题不在请求体里")
            ok(has(p.user, "替读到这里的读者提出"), "轻问：用的是 ideas 模板本体")
            ok(has(p.user, string.format("每条不超过 %d 个字", Suggest.MAX_LEN)),
                "轻问：单条字数上限与 Suggest.MAX_LEN 同步")
        end
        local bd2 = button_dialogs[#button_dialogs]
        if bd2 then
            local picked = bd2.buttons[1][1].text
            callp(bd2.buttons[1][1].callback, "点第 1 条建议没有抛异常")
            eq(input_dialogs[#input_dialogs]._t.input, picked, "轻问：选中后回填到输入框")
        end
    end
end

-- AI 返回的一段"解析不出任何条目"的垃圾输出（没有问号、一行到底、远超 20 字）
local JUNK_TEXT = "好的，我想了一下，这段文字确实挺有意思，人物和情节都值得再琢磨琢磨。"

-- 正好 20 字、结尾是「一天」、模型漏写句尾问号的完整问句（真机反馈①的现场照搬）
local Q20_TEXT = "他写下的那封信到底为什么会偏偏落在这一天"

-- ================= 2b AI 出题没给出可用东西时的回落 =================
-- 这一段是工程师打完 ③ 那行保底之后才有的行为：parseList 收不出任何条目时，
-- 必须回落到本地建议页。保底写对了但回落没写对，用户就停在一条报错上哪都去不了。
section("2b. AI 出题没给出可用问题：必须回落到本地建议，不能把用户晾在半路")
do
    Cache:clear(); http_calls = 0; bodies = {}
    -- 一段 parseList 必然收不出条目的回复：没有问号、一行到底、远超 20 字
    REPLY = "好的，我想了一下，这段文字确实挺有意思，人物和情节都值得再琢磨琢磨。"
    local bd, airow = openPickerAndFindAi(function(opts) ChatDialog:open(nil, opts) end,
        { selected = SELECTED, page_text = PAGE_TEXT, book_fp = "ideas_junk_fp", progress = PROG })
    ok(type(airow) == "table", "2b：还是走到了 AI 出题按钮")
    if type(airow) == "table" then
        callp(airow.callback, "2b：AI 返回收不出条目的内容时不抛异常")
        eq(http_calls, 1, "2b：只发了 1 个请求（没有悄悄重试，不会二次付费）")
        local info_text = nil
        for _i, ev in ipairs(events) do
            if ev.op == "show" and ev.kind == "info" and type(ev.w.text) == "string" then
                info_text = ev.w.text
            end
        end
        ok(type(info_text) == "string" and info_text:find("本地建议", 1, true) ~= nil,
            "2b：给了用户一句说明（含「本地建议」），不是静默失败", tostring(info_text))
        local bdj = button_dialogs[#button_dialogs]
        ok(bdj ~= nil and bdj ~= bd, "2b：回落后重新弹了一层建议页（不是停在报错上）")
        if bdj then
            eq(bdj.title, "你可能想问：", "2b：回落页是本地建议页（标题说清楚来源，不冒充 AI 结果）")
            ok(#bdj.buttons >= 2, "2b：回落页至少有 1 条建议 + 1 行返回（不是空页）", #bdj.buttons)
            local shown = nil
            for _i, ev in ipairs(events) do
                if ev.w == bdj and ev.op == "show" then shown = ev end
            end
            ok(shown ~= nil and not listHas(shown.before, "input"),
                "2b：回落页弹出时栈里没有未关闭的输入框（层级铁律在这条新路径上同样成立）")
            local picked = bdj.buttons[1][1].text
            callp(bdj.buttons[1][1].callback, "2b：点回落页第一条不抛异常")
            eq(input_dialogs[#input_dialogs]._t.input, picked, "2b：回落页选中的一条照样回填到输入框")

            -- 团队决定（2026-09-19）：回落页**保留**「让小望来问」入口，不去 allow_ai=false。
            -- 这个决定有一个必须经过实测才算数的前提：
            --   · 网络失败那次本来就不计费，重试零成本；
            --   · "请求成功但没解析出条目"这次的原文已经进了缓存，再点一次应当命中缓存、
            --     不再发请求 —— 钱包不动。
            -- 所以下面两条要同时成立：入口还在，且重试时 http 计数不增加。
            -- 谁改成 allow_ai=false，第一条红；谁让这条路不好好命中缓存，第二条红。
            local ai_row2 = nil
            local rows_dump = {}
            for _i, row in ipairs(bdj.buttons or {}) do
                rows_dump[#rows_dump + 1] = tostring(row[1] and row[1].text)
                if has(row[1] and row[1].text or "", "用一次额度") then ai_row2 = row[1] end
            end
            -- 源码现状（2026-09-19 核对 suggestpicker.lua:258 `local allow_ai = (content == nil)`）：
            --   · content == nil（网络/请求失败）→ 回落页**保留** AI 入口（失败不计费，可免费重试）
            --   · content ~= nil 但解析不出条目 → 回落页**不挂** AI 入口（再点只会命中同一份缓存）
            -- 团队那条"失败重试永远不额外花钱"只覆盖前一种；这里是后一种。
            -- 我不替产品决定对错：把**这件事依赖的前提**钉死——那条回复必须真的进了缓存，
            -- 否则"不给用户重试点"就是凭空收走他的选择权。
            ok(ai_row2 == nil,
                "2b：请求成功但解析不出条目时，回落页不挂 AI 入口（源码现状：再点只会命中缓存）",
                "回落页各行 = " .. table.concat(rows_dump, " ｜ "))
            local _junk, _jerr, junk_cached = Asker:askSync({
                kind = "ideas", selected = SELECTED, page_text = PAGE_TEXT,
                book_fp = "ideas_junk_fp", progress = PROG,
            })
            eq(junk_cached, true, "2b：那条「解析不出东西」的回复确实进了缓存（不挂 AI 入口的前提）")
            local calls_before = http_calls
            local _j2, _e2, c2 = Asker:askSync({
                kind = "ideas", selected = SELECTED, page_text = PAGE_TEXT,
                book_fp = "ideas_junk_fp", progress = PROG,
            })
            eq(c2, true, "2b：同一段书再问一次仍然命中缓存")
            eq(http_calls, calls_before, "2b：再问一次不再发出请求（证明「再点也拿不到新东西」是真的）")
        end
    end
    REPLY = CANNED
end

-- ================= 2c 请求失败那一支 =================
-- 团队那条"失败重试永远不额外花钱"还依赖一件事：失败本身不能写进缓存。
-- 否则这一段书就会被永久锁在"再也问不出 AI 问题"的状态里。
section("2c. 请求失败：给用户一句说真话的提示，且失败不被缓存")
do
    Cache:clear(); http_calls = 0; bodies = {}
    local http_stub = package.loaded["ywbf/httpclient"]
    local real_post = http_stub.post
    -- 失败桩也要记账，否则这一段的 http 计数全是假的（我自己踩过：got=0 是没数，不是没发）
    http_stub.post = function(_url, _h, _b, _t)
        http_calls = http_calls + 1
        return nil, 0, "", "qa: simulated failure"
    end
    local bd, airow = openPickerAndFindAi(function(opts) ChatDialog:open(nil, opts) end,
        { selected = SELECTED, page_text = PAGE_TEXT, book_fp = "ideas_fail_fp", progress = PROG })
    ok(type(airow) == "table", "2c：失败场景也能走到 AI 出题按钮")
    if type(airow) == "table" then
        callp(airow.callback, "2c：请求失败时不抛异常")
        eq(http_calls, 1, "2c：失败之前确确实实发过 1 次请求")
        local info_text = nil
        for _i, ev in ipairs(events) do
            if ev.op == "show" and ev.kind == "info" and type(ev.w.text) == "string" then
                info_text = ev.w.text
            end
        end
        ok(type(info_text) == "string" and info_text:find("请求失败", 1, true) ~= nil,
            "2c：失败时给的是「请求失败：…」，不是「AI 没给出可用问题」（提示要说真话）",
            tostring(info_text))
        local bdf = button_dialogs[#button_dialogs]
        ok(bdf ~= nil and bdf ~= bd, "2c：失败后仍然落到建议页（用户没被晾在一条报错上）")
        local ai_row_fail, rows_fail = nil, {}
        if bdf then
            for _i, row in ipairs(bdf.buttons or {}) do
                rows_fail[#rows_fail + 1] = tostring(row[1] and row[1].text)
                if has(row[1] and row[1].text or "", "用一次额度") then ai_row_fail = row[1] end
            end
        end
        -- 团队决定在这里落地：失败那一次根本不计费，重试零成本，这条免费重试路径不许堵死
        ok(type(ai_row_fail) == "table",
            "2c：请求失败的回落页保留「让小望来问」入口（失败不计费，别改成 allow_ai=false）",
            "回落页各行 = " .. table.concat(rows_fail, " ｜ "))
        if type(ai_row_fail) == "table" then
            local calls_before = http_calls
            callp(ai_row_fail.callback, "2c：失败后重试不抛异常")
            eq(http_calls, calls_before + 1, "2c：失败没有被写进缓存，重试是真的重新发了请求")
        end
    end

    -- 关键的那一问：失败有没有污染缓存？恢复之后必须还能真的再问一次。
    http_stub.post = real_post
    REPLY = CANNED
    http_calls = 0
    local _bd2, airow2 = openPickerAndFindAi(function(opts) ChatDialog:open(nil, opts) end,
        { selected = SELECTED, page_text = PAGE_TEXT, book_fp = "ideas_fail_fp", progress = PROG })
    ok(type(airow2) == "table", "2c：恢复后仍能走到 AI 出题按钮")
    if type(airow2) == "table" then
        callp(airow2.callback, "2c：恢复后再问一次不抛异常")
        eq(http_calls, 1, "2c：失败没有污染缓存——同一段书恢复后仍然真的发了新请求")
        local bd3 = button_dialogs[#button_dialogs]
        eq(bd3 and bd3.title or nil, "小望建议问：", "2c：恢复后拿到的是真正的 AI 结果页")
    end
end

-- ================= 2d 缓存关闭时的重试语义 =================
-- 工程师提的 B+ 是 `local allow_ai = (content == nil) or not Config:get("cache_enabled")`：
-- 判据从"这次失败了吗"改成"这次重试会不会拿到新东西"。
-- 取向由团队定，我不管；但**这个判据脚下的两个事实**必须先量出来：
--   ① 缓存关着时，同一段书再问一次确实会重新发请求（也就是确实会再花一次钱）；
--   ② 那次重试确实可能拿到跟上次不同的、可用的结果（输出的多样性不是假的）。
-- 两条都成立，B+ 才是站得住的一行；否则"缓存关着就给重试"等于骗用户去花钱。
section("2d. 缓存关闭时的重试语义：B+ 判据赖以成立的两个事实")
do
    -- 整段包一层 pcall：这一段会把 cache_enabled 改成 false，而配置是同步落盘的，
    -- 中途任何一句抛异常都会把 false 留在盘上，污染后面的小节乃至下一轮进程。
    -- 所以还原必须放在 pcall 外面，保证"改了就一定还原回来"。
    local function body2d()
    Cache:clear(); http_calls = 0; bodies = {}
    Config:set("cache_enabled", false)
    REPLY = "好的，我想了一下，这段文字确实挺有意思，人物和情节都值得再琢磨琢磨。"
    local _c1, _e1, fc1 = Asker:askSync({
        kind = "ideas", selected = SELECTED, page_text = PAGE_TEXT,
        book_fp = "ideas_nocache_fp", progress = PROG,
    })
    eq(fc1, false, "2d：缓存关着时第一次调用没有命中缓存")
    eq(http_calls, 1, "2d：第一次调用发了 1 个请求")
    local calls_after_first = http_calls
    REPLY = CANNED
    local c2, _e2, fc2 = Asker:askSync({
        kind = "ideas", selected = SELECTED, page_text = PAGE_TEXT,
        book_fp = "ideas_nocache_fp", progress = PROG,
    })
    eq(fc2, false, "2d：缓存关着时第二次调用也不命中缓存")
    eq(http_calls, calls_after_first + 1,
        "2d：① 缓存关着时再问一次真的会重新发请求（也就真的会再花一次钱）")
    local parsed_retry = Suggest.parseList(c2, 4)
    eq(#parsed_retry, 4,
        "2d：② 重试确实可能拿到跟上次不同的可用结果（上次 0 条、这次 4 条）")

    -- B+ 落地后才有的一条新分支：缓存关着 + 解析不出条目 → **必须保留** AI 入口。
    -- 上面两条事实刚验完：这种情形下再点会真的重新发请求、而且真可能抽到能解析的结果，
    -- 所以这时候摘按钮就是平白收走用户的重试权。
    Cache:clear(); http_calls = 0; bodies = {}
    REPLY = JUNK_TEXT
    local bd_off, airow_off = openPickerAndFindAi(function(opts) ChatDialog:open(nil, opts) end,
        { selected = SELECTED, page_text = PAGE_TEXT, book_fp = "ideas_off_cache_fp", progress = PROG })
    ok(type(airow_off) == "table", "2d：缓存关着的场景也能走到 AI 出题按钮")
    if type(airow_off) == "table" then
        callp(airow_off.callback, "2d：缓存关着时不抛异常")
        local bdoff = button_dialogs[#button_dialogs]
        ok(bdoff ~= nil and bdoff ~= bd_off, "2d：缓存关着时也回落到建议页（不是停在报错上）")
        if bdoff then
            local ai_row_off, rows_off = nil, {}
            for _i, row in ipairs(bdoff.buttons or {}) do
                rows_off[#rows_off + 1] = tostring(row[1] and row[1].text)
                if has(row[1] and row[1].text or "", "用一次额度") then ai_row_off = row[1] end
            end
            ok(type(ai_row_off) == "table",
                "2d：缓存关着且解析不出条目时，回落页保留 AI 入口（再点会真发请求，没有理由摘）",
                "回落页各行 = " .. table.concat(rows_off, " ｜ "))
            if type(ai_row_off) == "table" then
                local before_off = http_calls
                callp(ai_row_off.callback, "2d：在回落页再点一次不抛异常")
                eq(http_calls, before_off + 1, "2d：这次重试真的重新发了请求（按钮说的和发生的是一回事）")
            end
        end
    end
    end
    local okd, errd = pcall(body2d)
    Config:set("cache_enabled", true)
    REPLY = CANNED
    Cache:clear()
    ok(okd, "2d：整段没抛异常（抛了也不能把 cache_enabled 留在 false 上）", errd)
end

-- ================= 2e 被 max_tokens 截断（finish_reason = "length"） =================
-- 团队定的口径（方案 A）：截断**不返回 nil**，照常给内容，只把最后那行没写问号的
-- 残句丢掉；前面解析出来的完整问句保住——这次额度已经花了，把几条针对这本书的
-- 好问题扔掉、退回通用本地建议才是真浪费。于是有**两种结果**，两条都要钉：
--   ① 截断但解析出 ≥1 条 → AI 结果页（按既有规则不挂重试入口，结果已经给了）；
--   ② 截断且解析出 0 条 → 回落本地页，且**必须保留**重试入口：
--      摘入口的唯一理由是"再点也拿到同一份东西"，而截断那次特意**不写缓存**，
--      再点是真重试真扣费，所以按钮写着「用一次额度」是诚实的 —— 摘它属于误伤。
-- 注：残句与"漏写问号的完整整句"在文本层面无法区分，截断这件事只能由上游
-- finish_reason 告知（见 2f①：stop 时同一个形状必须照收，不能误杀）。
section("2e. 截断：保住完整问句、丢掉残句、不写缓存、0 条时给重试")
do
    -- ---------- ① 截断但解析出 ≥1 条 ----------
    Cache:clear(); http_calls = 0; bodies = {}
    FINISH = "length"
    REPLY = "他为什么偏偏此时提灯？\n雪夜的沉默说明了什么？\n窗外雪停了以后他才发"
    local bd, airow = openPickerAndFindAi(function(opts) ChatDialog:open(nil, opts) end,
        { selected = SELECTED, page_text = PAGE_TEXT, book_fp = "ideas_trunc_fp", progress = PROG })
    ok(type(airow) == "table", "2e①：截断场景也能走到 AI 出题按钮")
    if type(airow) == "table" then
        callp(airow.callback, "2e①：被截断时不抛异常")
        eq(http_calls, 1, "2e①：只发了 1 个请求（没有自动重试）")
        local bdt = button_dialogs[#button_dialogs]
        ok(bdt ~= nil and bdt ~= bd, "2e①：截断后弹了一层建议页")
        if bdt then
            eq(bdt.title, "小望建议问：",
                "2e①：截断但解析出条目 → 弹 AI 结果页（这几次额度已经花了，不该退回通用建议）",
                bdt.title)
            eq(#bdt.buttons, 3, "2e①：2 条完整问句 + 1 行返回（残句被丢掉）", #bdt.buttons)
            local tail_hit = false
            local ai_row_t = nil
            for _i, row in ipairs(bdt.buttons or {}) do
                local txt = row[1] and row[1].text or ""
                if has(txt, "窗外雪停了以后") then tail_hit = true end
                if has(txt, "用一次额度") then ai_row_t = row[1] end
            end
            ok(tail_hit == false, "2e①：被截断的那半句没有出现在任何按钮上（点了就是花钱问残句）")
            ok(ai_row_t == nil, "2e①：AI 结果页不挂重试入口（结果已经给出来了）")
        end
        -- ---------- ② 截断不写缓存 ----------
        local before2 = http_calls
        local _tc, _te, tfc = Asker:askSync({
            kind = "ideas", selected = SELECTED, page_text = PAGE_TEXT,
            book_fp = "ideas_trunc_fp", progress = PROG,
        })
        eq(tfc, false, "2e②：截断那次没有写进缓存（再点不是命中同一份）")
        eq(http_calls, before2 + 1, "2e②：截断后重试确实会重新发请求")

        -- ---------- ② 正常侧对照：同一条件下「没被截断」的 ideas 必须照常进缓存 ----------
        --   这条是工程师实测催出来的：他那边 d3/d4（截断不进缓存）在缓存被整体关掉时
        --   照样是绿的 —— 只测"不缓存"这一侧，遇到"为了不缓存截断结果而一刀切关掉缓存"
        --   这种改法会全绿放行。所以同一段里必须配一条反向对照：
        --   同样 kind=ideas、同样缓存开着、只是 finish_reason=stop，它就**必须**进缓存，
        --   第二次必须命中且不再发请求。这条绿了，"截断没进缓存"才是真的挑出来的事实。
        Cache:clear(); http_calls = 0
        FINISH = "stop"
        REPLY = CANNED
        local _cn1, _en1, _fcn1 = Asker:askSync({
            kind = "ideas", selected = SELECTED, page_text = PAGE_TEXT,
            book_fp = "ideas_stop_cached_fp", progress = PROG,
        })
        eq(http_calls, 1, "2e②对照：没被截断那次真的发了 1 个请求（对照的前置条件）")
        local _cn2, _en2, fcn2 = Asker:askSync({
            kind = "ideas", selected = SELECTED, page_text = PAGE_TEXT,
            book_fp = "ideas_stop_cached_fp", progress = PROG,
        })
        eq(fcn2, true,
            "2e②对照：同一条件下没被截断的 ideas 照常进缓存（否则上面那条'截断不写缓存'就是假绿）")
        eq(http_calls, 1, "2e②对照：第二次命中缓存、没再发请求（缓存这条通路本身是通的）")
        FINISH = "length"
    end

    -- ---------- ③ 截断且解析出 0 条 → 回落本地页 + 保留重试入口 ----------
    Cache:clear(); http_calls = 0; bodies = {}
    FINISH = "length"
    REPLY = JUNK_TEXT
    local bd0, airow0 = openPickerAndFindAi(function(opts) ChatDialog:open(nil, opts) end,
        { selected = SELECTED, page_text = PAGE_TEXT, book_fp = "ideas_trunc0_fp", progress = PROG })
    ok(type(airow0) == "table", "2e③：截断且 0 条的场景也能走到 AI 出题按钮")
    if type(airow0) == "table" then
        callp(airow0.callback, "2e③：截断且解析不出条目时不抛异常")
        local bd2 = button_dialogs[#button_dialogs]
        ok(bd2 ~= nil and bd2 ~= bd0, "2e③：回落后重新弹了一层建议页")
        if bd2 then
            eq(bd2.title, "你可能想问：",
                "2e③：截断且解析不出条目 → 回落本地建议页", bd2.title)
            --[[--
            「宁可一条都不剩，也不留残句」的**安全网**，两条必须同时成立（团队 2026-09-19 钉死）：

              ① 截断且 0 条时确实弹了本地建议页，而且那一页**至少有 1 条能点的建议**（不是空页）；
              ② 那一页上还留着「让小望来问」（截断那次没进缓存，再点是真重试、真扣费）。

            不给 AI 结果是可以的（残句不能当结果给），但**不能什么都不给** —— 用户会停在
            一条报错上哪都去不了，这个失败模式本项目在别处踩过。
            只钉 ② 不钉 ① 是不够的：谁把回落页整个砍掉（不弹、或弹一个空列表），
            ② 会因为"压根没有按钮"而变成 nil 判断的游戏，安全网就漏了。
            --]]
            local ai_row0, rows0, real_rows0 = nil, {}, 0
            for _i, row in ipairs(bd2.buttons or {}) do
                local t = tostring(row[1] and row[1].text)
                rows0[#rows0 + 1] = t
                if has(row[1] and row[1].text or "", "用一次额度") then ai_row0 = row[1] end
                -- 只数"真建议"：返回行和 AI 入口都不算，否则砍空回落页时这条会假绿
                if t ~= "返回" and not has(t, "用一次额度") then real_rows0 = real_rows0 + 1 end
            end
            ok(real_rows0 >= 1,
                "2e③：回落页至少有 1 条真建议（不是空页）——不给 AI 结果可以，不能什么都不给",
                "回落页各行 = " .. table.concat(rows0, " ｜ "))
            -- 这条就是补 `or truncated` 的理由：摘入口的前提（命中缓存）在截断时不成立
            ok(type(ai_row0) == "table",
                "2e③：截断且 0 条时回落页保留「让小望来问」（再点是真重试，按钮没骗人）",
                "回落页各行 = " .. table.concat(rows0, " ｜ "))
            if type(ai_row0) == "table" then
                local before_retry = http_calls
                callp(ai_row0.callback, "2e③：点重试入口不抛异常")
                eq(http_calls, before_retry + 1,
                    "2e③：重试真的重新发了请求（不是命中缓存，所以按钮文案是诚实的）")
            end
        end
    end
    -- ---------- ④ 只有一行、且那行没问号、又被截断 → 一条都不收 ----------
    --   这是工程师正在补的第二个洞：parseList 里「只有一行就不丢残句」的守卫
    --   （#lines > 1）会让这种半句话被当成一条完整建议收进来 —— 用户点它
    --   就是花一次额度问一句没问完的话，和「补问号不许削字」是同一类错误。
    --   为什么还要单独补这一条：③ 的 JUNK_TEXT 有 34 字，是被 MAX_LEN 挡掉的，
    --   挡住它的是长度而不是截断逻辑，压根没打到那个守卫上。
    --   所以必须再给一条「单行短残句」样本（6 字、无问号），才真正打到那个守卫。
    Cache:clear(); http_calls = 0; bodies = {}
    local FRAG1 = "雪停之后他才"
    -- 素材自检（工程师把这条也做成了断言，做法我照搬）：这条样本必须落在
    -- 「不丢就会被 pushIdea 收下」的区间（≥ MIN_IDEA_LEN 且 ≤ MAX_LEN）。
    -- 否则拦住它的是长度门槛而不是截断逻辑，下面那两条就会空转成**假绿**
    -- 而"截断了但一条没丢"这种改法正好能从空转里溜过去。
    ok(Util.utf8len(FRAG1) >= Suggest.MIN_IDEA_LEN and Util.utf8len(FRAG1) <= Suggest.MAX_LEN,
        "2e④：（素材自检）残句样本落在会被收下的区间——丢它的是截断逻辑，不是长度门槛",
        string.format("len=%d min=%d max=%d",
            Util.utf8len(FRAG1), Suggest.MIN_IDEA_LEN, Suggest.MAX_LEN))
    FINISH = "length"
    REPLY = FRAG1
    local bd1, airow1 = openPickerAndFindAi(function(opts) ChatDialog:open(nil, opts) end,
        { selected = SELECTED, page_text = PAGE_TEXT, book_fp = "ideas_trunc1_fp", progress = PROG })
    ok(type(airow1) == "table", "2e④：单行残句场景也能走到 AI 出题按钮")
    if type(airow1) == "table" then
        callp(airow1.callback, "2e④：单行残句时不抛异常")
        local bd3 = button_dialogs[#button_dialogs]
        ok(bd3 ~= nil and bd3 ~= bd1, "2e④：单行残句后重新弹了一层建议页")
        if bd3 then
            local rows1, bad, real_rows1 = {}, false, 0
            for _i, row in ipairs(bd3.buttons or {}) do
                local t = tostring(row[1] and row[1].text)
                rows1[#rows1 + 1] = t
                if has(t, "雪停之后他才") then bad = true end
                if t ~= "返回" and not has(t, "用一次额度") then real_rows1 = real_rows1 + 1 end
            end
            ok(bad == false, "2e④：单行残句没被做成按钮（点了就是花钱问半句话）",
                "弹窗各行 = " .. table.concat(rows1, " ｜ "))
            eq(bd3.title, "你可能想问：",
                "2e④：单行残句解析出 0 条 → 回落本地建议页（不是 AI 结果页）", bd3.title)
            -- 同一张安全网：这里也是"一条都不剩"，同样不能什么都不给
            ok(real_rows1 >= 1,
                "2e④：回落页至少有 1 条真建议（不是空页）——不给 AI 结果可以，不能什么都不给",
                "回落页各行 = " .. table.concat(rows1, " ｜ "))
        end
    end
    FINISH = "stop"
    REPLY = CANNED
    Cache:clear()
end

-- ================= 2f 反例对照：别把正常的整句和非 ideas 一起误杀 =================
section("2f. 反例对照：stop 的完整整句照收，非 ideas 的截断不受影响")
do
    -- ① finish_reason = "stop"，最后一行是**没写问号的完整整句** → 必须照常收下并补问号。
    --   这是 2e 的另一半：两条路行为必须相反，而且各自都有断言。
    Cache:clear(); http_calls = 0; bodies = {}
    FINISH = "stop"
    REPLY = "他为什么偏偏此时提灯？\n" .. Q20_TEXT
    local c_stop, _e_stop, fc_stop = Asker:askSync({
        kind = "ideas", selected = SELECTED, page_text = PAGE_TEXT,
        book_fp = "ideas_stop_fp", progress = PROG,
    })
    ok(type(c_stop) == "string" and c_stop ~= "",
        "2f①：正常结束（stop）时结果照常返回（不能被截断逻辑误杀）", tostring(c_stop))
    local rstop = Suggest.parseList(c_stop, 4)
    eq(#rstop, 2, "2f①：两条都收下（前一条带问号、后一条漏写问号）")
    eq(rstop[2], Q20_TEXT .. "？",
        "2f①：漏写问号的**完整整句**照常收下并补问号，一个字都不能少", rstop[2])
    ok(fc_stop == false, "2f①：这一次是真实请求（前置，不是缓存干扰）")

    -- ② 非 ideas（释义/摘要）被截断 → 行为不变：仍返回内容、仍写缓存。
    --   截断拦截只针对 ideas，别把释义/摘要一起改坏。
    Cache:clear(); http_calls = 0
    FINISH = "length"
    REPLY = "这段写的是雪夜里的灯，作者用它来表示一种说不清的牵挂，后面还有"
    local c_ex, _e_ex, fc_ex = Asker:askSync({
        kind = "explain", selected = SELECTED, page_text = PAGE_TEXT,
        book_fp = "explain_trunc_fp", progress = PROG,
    })
    ok(type(c_ex) == "string" and c_ex ~= "",
        "2f②：非 ideas（explain）被截断时行为不变，仍然返回内容（截断拦截只管 ideas）",
        tostring(c_ex))
    local _c2, _e2, fc_ex2 = Asker:askSync({
        kind = "explain", selected = SELECTED, page_text = PAGE_TEXT,
        book_fp = "explain_trunc_fp", progress = PROG,
    })
    eq(fc_ex2, true, "2f②：explain 该写缓存还是写缓存（没被 ideas 的规则波及）")

    FINISH = "stop"
    REPLY = CANNED
    Cache:clear()
end

-- ================= 3 开关 ai_suggestions =================
section("3. 开关：ai_suggestions=false 后不该出现 AI 出题入口")
do
    -- 同上：这一节会把 ai_suggestions 改成 false，还原必须放在 pcall 外面，
    -- 否则中途抛异常就把"开关关着"留在盘上（配置同步落盘），下一轮开局就带着它跑。
    local function body3()
    Config:set("ai_suggestions", false)
    Cache:clear(); http_calls = 0
    local bd, airow = openPickerAndFindAi(function(opts) ChatDialog:open(nil, opts) end,
        { selected = SELECTED, page_text = PAGE_TEXT, book_fp = "ideas_off_fp", progress = PROG })
    ok(bd ~= nil, "关掉 AI 后本地建议页仍然弹得出来")
    ok(airow == nil, "关掉 AI 后建议页里没有「让小望来问」按钮", tostring(airow))
    -- 零 token 底线：就算入口因为改代码又漏出来了，点下去也不许发请求。
    -- 这条和上面那条同时成立，才算把"开关关着也会偷偷花钱"堵死。
    if type(airow) == "table" then callp(airow.callback, "开关关着时点漏出来的 AI 入口不该崩") end
    eq(http_calls, 0, "开关关着时点了 AI 入口也没有发出任何请求（零 token 底线）")
    eq(http_calls, 0, "关掉 AI 后一路没有发出任何请求")
    Config:set("ai_suggestions", true)
    Cache:clear()
    local bd2, airow2 = openPickerAndFindAi(function(opts) ChatDialog:open(nil, opts) end,
        { selected = SELECTED, page_text = PAGE_TEXT, book_fp = "ideas_on_fp", progress = PROG })
    ok(type(airow2) == "table", "改回 true 后 AI 入口恢复", tostring(airow2))
    -- 没有选中文本时不该给 AI 入口（问不出东西还花钱）
    eq(SuggestPicker:aiEnabled({ selected = "" }), false, "没有选中文本时 AI 入口关闭")
    eq(SuggestPicker:aiEnabled({ selected = SELECTED }), true, "有选中文本时 AI 入口开启")
    end
    local ok3, err3 = pcall(body3)
    Config:set("ai_suggestions", true)
    ok(ok3, "3：整段没抛异常（抛了也不能把 ai_suggestions 留在 false 上）", err3)
end

-- ================= 4 缓存是历史泄漏路径 =================
section("4. 缓存里的旧回复出库时也要过防剧透（历史泄漏路径）")
do
    -- ① 先在"防剧透关着"的状态下攒一条带未读章节标记的回复进缓存
    Config:set("spoiler_guard", false)
    Cache:clear(); http_calls = 0
    REPLY = LEAK_TITLE .. "里，" .. LEAK_BODY .. "。以上就是答案。"
    local _bd, airow = openPickerAndFindAi(function(opts) ChatDialog:open(nil, opts) end,
        { selected = SELECTED, page_text = PAGE_TEXT, book_fp = "ideas_cache_fp", progress = PROG })
    if type(airow) == "table" then callp(airow.callback, "4 缓存准备：点 AI 按钮没有抛异常") end
    ok(http_calls >= 1, "（准备）防剧透关着时攒下了一条带未读标记的缓存", http_calls)

    -- ② 打开防剧透，同一个 book_fp 再点一次：应命中缓存，但出库要被 sanitize
    Config:set("spoiler_guard", true)
    http_calls = 0
    local raw_from_cache = nil
    local bd2, airow2 = openPickerAndFindAi(function(opts) ChatDialog:open(nil, opts) end,
        { selected = SELECTED, page_text = PAGE_TEXT, book_fp = "ideas_cache_fp", progress = PROG })
    if type(airow2) == "table" then
        local _c, _e, from_cache
        -- 再走一次同 book_fp 的 askSync：这次必然命中缓存，用来观察出库结果
        _c, _e, from_cache = Asker:askSync({
            kind = "ideas", selected = SELECTED, page_text = PAGE_TEXT,
            book_fp = "ideas_cache_fp", progress = PROG,
        })
        raw_from_cache = _c
        eq(from_cache, true, "第二次确实命中了缓存（不是重新发的）")
        eq(http_calls, 0, "命中缓存时没有发出新请求")
    end
    ok(type(raw_from_cache) == "string", "缓存命中返回了内容")
    if type(raw_from_cache) == "string" then
        ok(has(raw_from_cache, LEAK_BODY) == false,
            "缓存里的未读正文在出库时被 sanitizeAnswer 挡住了", raw_from_cache)
        print("  [证据] 缓存原文=" .. (LEAK_TITLE .. "里，" .. LEAK_BODY .. "。以上就是答案。"))
        print("  [证据] 出库内容=" .. tostring(raw_from_cache))
    end
    REPLY = CANNED
    Config:set("spoiler_guard", true)
    Cache:clear()
end

-- ================= 5 parseList 契约（我自己编的样本） =================
section("5. Suggest.parseList：永不 nil、永不抛异常、条数 ≤ max、每条合规")
do
    local DIRTY = "袭人\128为何\237\160\128提玉？\n宝玉为何不语？"   -- 含 UTF-16 代理对 ED A0 80
    local cases = {
        { name = "nil",          text = nil,        max = 4 },
        { name = "空串",         text = "",         max = 4 },
        { name = "纯空白",       text = "  \n\n\t ", max = 4 },
        { name = "number",       text = 12345,      max = 4 },
        { name = "table",        text = {},         max = 4 },
        { name = "boolean",      text = true,       max = 4 },
        { name = "max=nil",      text = CANNED,     max = nil },
        { name = "max=0(回落4)", text = CANNED,     max = 0 },
        { name = "max=-3(回落4)", text = CANNED,    max = -3 },
        { name = "max=2",        text = CANNED,     max = 2 },
        { name = "max=999(压6)", text = CANNED,     max = 999 },
        { name = "max=字符串",   text = CANNED,     max = "4" },
        { name = "标准样本",     text = CANNED,     max = 4 },
        { name = "项目符号混排", text = "- 袭人为何提玉？\n* 宝玉为何不语？\n1. 雪夜有何意味？\n4、老管家是谁？", max = 4 },
        { name = "全挤一行",     text = "袭人为何提玉？宝玉为何不语？雪夜有何意味？老管家是谁？", max = 4 },
        { name = "没写问号",     text = "袭人为何提玉\n宝玉为何不语\n雪夜有何意味", max = 4 },
        { name = "CRLF 行尾",    text = "袭人为何提玉？\r\n宝玉为何不语？\r\n", max = 4 },
        { name = "空行很多",     text = "\n\n\n袭人为何提玉？\n\n\n宝玉为何不语？\n\n", max = 4 },
        { name = "脏字节",       text = DIRTY,      max = 4 },
        { name = "全脏字节",     text = "\255\254\237\160\128", max = 4 },
        { name = "只有问号",     text = "？\n？\n？", max = 4 },
        { name = "重复条目",     text = "袭人为何提玉？\n袭人为何提玉？\n宝玉为何不语？", max = 4 },
        { name = "整段超长不换行", text = string.rep("这一段里模型啰啰嗦嗦说了一大堆完全不成问题的话", 3), max = 4 },
        { name = "开场白+一条",  text = "好的，以下是我的建议：\n1. 袭人为何提玉？", max = 4 },
        { name = "制表符分隔",   text = "袭人为何提玉？\t宝玉为何不语？", max = 4 },
        { name = "中英混排",     text = "Why did 袭人 mention the 玉？\n宝玉为何不语？", max = 4 },
        { name = "编号+符号",    text = "1. - 袭人为何提玉？\n2. - 宝玉为何不语？", max = 4 },
    }
    for _, c in ipairs(cases) do
        local want_max = (type(c.max) == "number" and c.max >= 1)
            and math.min(math.floor(c.max), Suggest.MAX_LIMIT) or Suggest.DEFAULT_MAX
        local ok_run, res = pcall(Suggest.parseList, c.text, c.max)
        if not ok_run then
            ok(false, c.name .. "：抛异常", tostring(res))
        elseif type(res) ~= "table" then
            ok(false, c.name .. "：返回类型不是 table", tostring(res))
        else
            local bad = nil
            for _j, q in ipairs(res) do
                -- 长度口径（2026-09-19 真机修正）：MAX_LEN 是**内容**上限，
                -- 句尾问号是标点、不计入；所以允许"20 内容 + 1 问号 = 21"。
                -- 去掉一个句尾问号后再量内容长度，防止把"不准删字"那条偷偷放宽回去。
                local body = q
                if body:sub(-3) == "？" then body = body:sub(1, -4)
                elseif body:sub(-1) == "?" then body = body:sub(1, -2) end
                if type(q) ~= "string" then bad = "元素不是字符串"
                elseif Util.utf8len(body) > Suggest.MAX_LEN then bad = "内容超过 20 字：" .. q
                elseif Util.utf8len(q) > Suggest.MAX_LEN + 1 then bad = "含问号也超长：" .. q
                elseif Util.trim(q) == "" then bad = "空串"
                elseif q:find("\n") or q:find("\t") or q:find("\r") then bad = "含换行/制表符"
                elseif Util.sanitizeUtf8(q) ~= q then bad = "含非法 UTF-8：" .. q
                elseif not (q:sub(-3) == "？" or q:sub(-1) == "?") then bad = "不以问号结尾：" .. q
                end
            end
            if not bad and #res > want_max then bad = "条数 " .. #res .. " 超上限 " .. want_max end
            if bad then ok(false, c.name .. "：" .. bad)
            else ok(true, string.format("%s：%d 条 %s", c.name, #res, table.concat(res, " / "))) end
        end
    end

    -- 关键行为单独钉死。
    -- 用 safeParse 包一层：parseList 的合约是「永不 nil、永不抛异常」，
    -- 变异把这两条打掉时脚本要能报红，而不是自己先崩（否则拿不到结论）。
    local function safeParse(t, m)
        local ok_run2, r = pcall(Suggest.parseList, t, m)
        if not ok_run2 then return nil, tostring(r) end
        return r, nil
    end
    local p4, e4 = safeParse(CANNED, 4)
    ok(type(p4) == "table", "标准样本：parseList 返回 table（不是 nil，不是异常）", e4)
    ok(type(p4) == "table" and #p4 == 4, "标准样本解析出 4 条", e4)
    local q4 = type(p4) == "table" and p4 or {}
    eq(q4[1], "他为什么偏偏此时提灯？", "第 1 条剥掉了「1. 」编号")
    eq(q4[2], "雪夜的沉默说明了什么？", "第 2 条剥掉了「- 」项目符号")
    eq(q4[3], "「仔细」二字在提醒谁？", "第 3 条保留了成对的中文引号（没有留下孤儿 」）")
    eq(q4[4], "他为何不答？", "第 4 条原本没写问号，被补上了（不是半句陈述）")
    local LONG = string.rep("这一段里模型啰啰嗦嗦说了一大堆完全不成问题的话", 3)
    local rl, el = safeParse(LONG, 4)
    ok(type(rl) == "table", "整段超长不换行：返回 table（不是 nil）", el)
    eq(type(rl) == "table" and #rl or -1, 0, "整段超长不换行 → 一条都不收（丢弃而不是硬切成半句）")
    local rd, ed = safeParse("袭人为何提玉？\n袭人为何提玉？\n宝玉为何不语？", 4)
    ok(type(rd) == "table", "重复条目样本：返回 table（不是 nil）", ed)
    eq(type(rd) == "table" and #rd or -1, 2, "重复条目被去重")
    -- ===== 真机反馈①：补问号绝不能削掉最后一个字 =====
    -- 用户实测「…偏偏在这一天」被削成「…偏偏在这一？」。下面这条直接照他的场景造：
    -- 正好 20 字、结尾就是「一天」、模型漏写句尾问号 —— 结果必须原样完整 + 补一个问号。
    local Q20 = Q20_TEXT
    eq(Util.utf8len(Q20), Suggest.MAX_LEN, "（前置）我这条样本确实是 20 字（少一个字这条就测不到 nth=20 的边界）")
    local r20 = Suggest.parseList(Q20, 4)
    eq(#r20, 1, "20 字、漏写句尾问号：仍然收下（不能被当成残句丢掉）")
    eq(r20[1], Q20 .. "？", "20 字 + 补问号：一个字都不能少（用户踩的就是末尾被削）")
    ok(type(r20[1]) == "string" and r20[1]:sub(-9) == "一天？",
        "句尾完整保留「一天？」而不是「一？」", tostring(r20[1]))

    -- ===== 真机反馈①的第二道防线：问号之后的余料不再收 =====
    -- 残成一行的场景：最后一个问号后面跟着半句话（开场白碎屑 / max_tokens 截断）。
    local REMAINDER = "袭人为何提玉？可是在那之后他才发现自己的思路有问题"
    local rrem = Suggest.parseList(REMAINDER, 4)
    eq(#rrem, 1, "同一行里最后一个问号之后的余料不再收进来")
    eq(rrem[1], "袭人为何提玉？", "收下的那一条是完整的、不是被截断的半句")
    local has_tail = false
    for _i, q in ipairs(rrem) do
        if q:find("思路有问题", 1, true) then has_tail = true end
    end
    ok(has_tail == false,
        "那半句残料没有出现在任何按钮上（点了就是花一次额度问一句读不通的话）",
        table.concat(rrem, " ｜ "))

    -- 说明（不是断言，也不是 KNOWN）：parseList 单独看文本时，"独立成行且没写问号"的
    -- 那一行到底是"完整句子漏写问号"（必须收）还是"被截断的半句"（必须丢），**文本层面
    -- 无法区分**——所以这条不能靠 parseList 自己解决，必须由上游 finish_reason 拦截
    -- （见 2e：管道层已经钉成硬断言）。这里只在单元层确认"前两条完整问句照常收下"。
    local TRUNC = "他为什么偏偏此时提灯？\n雪夜的沉默说明了什么？\n窗外雪停了以后他才发"
    local rtr = Suggest.parseList(TRUNC, 4)
    eq(#rtr >= 2, true, "截断输出里前两条完整问句照常收下")
    -- 10000 字不换行的极端输入：不崩、不卡死、返回空数组
    local big = string.rep("啰", 10000)
    local t0 = os.clock()
    local ok_big, res_big = pcall(Suggest.parseList, big, 4)
    ok(ok_big and type(res_big) == "table", "10000 字不换行：不崩且返回 table")
    ok(os.clock() - t0 < 2, "10000 字不换行：解析耗时 < 2s（没有病理性回溯）",
        string.format("%.3fs", os.clock() - t0))
end

-- ================= 6 ideas 不进 Store =================
section("6. ideas 不写进历史（对照组 explain 会写）")
do
    Cache:clear()
    store_calls = {}
    local c1 = Asker:askSync({
        kind = "ideas", selected = SELECTED, page_text = PAGE_TEXT,
        book_fp = "ideas_store_fp", progress = PROG,
    })
    ok(c1 ~= nil, "ideas 调用成功")
    eq(#store_calls, 0, "ideas 没有往 Store 写一个字")
    store_calls = {}
    local c2 = Asker:askSync({
        kind = "explain", selected = SELECTED, page_text = PAGE_TEXT,
        book_fp = "ideas_store_fp", progress = PROG,
    })
    ok(c2 ~= nil, "对照组 explain 调用成功")
    ok(#store_calls >= 1, "对照组 explain 确实写了 Store（证明跳过只针对 ideas）", #store_calls)
end

-- ================= 7 二次点击不重复付费 =================
section("7. 同一段文字第二次点 AI 走缓存，不再发请求")
do
    Cache:clear(); http_calls = 0
    for _i = 1, 2 do
        local bd, airow = openPickerAndFindAi(function(opts) ChatDialog:open(nil, opts) end,
            { selected = SELECTED, page_text = PAGE_TEXT, book_fp = "ideas_twice_fp", progress = PROG })
        if type(airow) == "table" then
            callp(airow.callback, "7 连点两次：点 AI 按钮没有抛异常")
            local bd2 = button_dialogs[#button_dialogs]
            if bd2 and bd2.buttons[1] then
                callp(bd2.buttons[1][1].callback, "7 连点两次：点建议条目没有抛异常")
            end
        end
    end
    eq(http_calls, 1, "连点两次 AI 入口只发了 1 个请求（第二次命中缓存）")
end

-- ================= 8 变异命门（静态） =================
section("8. 变异命门：源码里的关键接线还在")
do
    local p_src = readFile(PLUGIN_DIR .. "/ywbf/prompts.lua") or ""
    local sp_src = readFile(PLUGIN_DIR .. "/ui/suggestpicker.lua") or ""
    local cd_src = readFile(PLUGIN_DIR .. "/ui/chatdialog.lua") or ""
    local tc_src = readFile(PLUGIN_DIR .. "/ui/toastcard.lua") or ""
    ok(#p_src > 5000 and #sp_src > 1000 and #cd_src > 5000 and #tc_src > 2000, "源码都真的读到了字节")
    ok(has(p_src, 'kind == "explain" or kind == "summary" or kind == "concept" or kind == "ideas"'),
        "Prompts.build 里 ideas 与 explain/summary/concept 同一分支（变异 1 的命门）")
    ok(has(sp_src, "progress = o.progress"), "showAi 把 progress 传给了 askSync（变异 2 的命门）")
    ok(has(cd_src, "book_fp = opts.book_fp,\n            progress = Asker:fetchProgress() or opts.progress,"),
        "chatdialog 的 suggest_opts 带了 progress（变异 3 的命门）")
    -- 只盯着带上下文的那一处：toastcard 里提交路径也有同样字样的 progress=opts.progress，
    -- 曾经只搜这一行的话，把 suggest_opts 里的那行摘掉静态断言也不会红（M3b 暴露的）。
    ok(has(tc_src, "book_fp = opts.book_fp,\n        progress = opts.progress,\n    }"),
        "toastcard 的 suggest_opts（不是提交路径那一处）带了 progress")
    ok(has(sp_src, 'if Config:get("ai_suggestions") == false then return false end'),
        "aiEnabled 里的开关判断还在（变异 5 的命门）")
    local ak_src = readFile(PLUGIN_DIR .. "/ui/asker.lua") or ""
    ok(has(ak_src, 'ideas   = { temperature = "temperature_chat", max_tokens = "max_tokens_ideas" }'),
        "TASK_PARAMS.ideas 用的是 max_tokens_ideas（变异 6 的命门）")
end

section("RESULTS")
print(string.format("TOTAL: %d  PASSED: %d  FAILED: %d", TOTAL, PASSED, FAILED))
if FAILED > 0 then
    print("")
    print("失败明细：")
    for _, m in ipairs(failures) do print("  - " .. m) end
end
