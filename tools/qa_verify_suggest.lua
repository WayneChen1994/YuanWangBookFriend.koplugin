--[[--
QA 独立验证：「你可能想问」建议问题的**接线**。

跟前几轮同一套办法：给 KOReader UI 打桩后 require **真的** ui/suggestpicker.lua、
ui/chatdialog.lua、ui/toastcard.lua，走真的 ChatDialog:open / ToastCard:open，
然后**真的点按钮**。

第二次改版后的新契约（真机翻车后改的）：
  选择层不能叠在还开着的 InputDialog 上——InputDialog 连同虚拟键盘会盖住弹层，
  点了没反应、也关不掉。所以调用方必须先 `UIManager:close(dialog)` 再弹选择层，
  选中后用**问题作为 prefill 重新打开输入框**（`input = prefill or ""`），
  「返回」/点空白处则用 on_cancel 空着重新打开。

为此本脚本的 UIManager 桩维护了一个**真实的 widget 栈**（show 压栈 / close 出栈），
并记录每次入栈前的栈快照——"弹层弹出时栈里还有没有输入框"就是这次事故唯一能
防住它的断言，桩里没有层级这个维度正是上一版 159 条全绿却漏掉 bug 的原因。

跑法（KPW4）：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     YWBF_PLUGIN_DIR=/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin \
     YWBF_TEST_DIR=/mnt/us/ywbf_dev/testdata \
     ./luajit /mnt/us/ywbf_dev/tools/qa_verify_suggest.lua
--]]

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR") or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"
local TEST_DIR = os.getenv("YWBF_TEST_DIR") or "/mnt/us/ywbf_dev/testdata"

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

-- ================= KOReader UI 打桩（记录型 + 真 widget 栈） =================
local stack = {}    -- 屏幕上的 widget 栈（后 show 的在上面）
local events = {}   -- { op="show"/"close", kind=..., before={栈内 kind 列表} }
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

-- 注意：业务代码一律写 `InputDialog:new{...}`（冒号），第一个参数是 self。
-- 第一版我写成 `new = function(t)`，t 拿到的是模块表，直接导致"找不到按钮"的假红。
local function newInputDialog(_self, t)
    local o = {
        _kind = "input",
        _t = t or {},
        _input = (t and t.input) or "",
        _set_count = 0,
    }
    function o:setInputText(s)
        self._input = s
        self._set_count = self._set_count + 1
        self._last_set = s
    end
    function o:getInputText() return self._input end
    function o:onShowKeyboard() end
    input_dialogs[#input_dialogs + 1] = o
    return o
end

package.loaded["ui/widget/inputdialog"] = { new = newInputDialog }
package.loaded["ui/widget/buttondialog"] = {
    new = function(_self, t)
        t = t or {}
        t._kind = "button"
        button_dialogs[#button_dialogs + 1] = t
        return t
    end,
}
package.loaded["ui/widget/infomessage"] = {
    new = function(_self, t) t = t or {} t._kind = "info" return t end,
}
package.loaded["ui/widget/confirmbox"] = {
    new = function(_self, t) t = t or {} t._kind = "confirm" return t end,
}
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
package.loaded["device"] = { screen = nil }                       -- 无头：buildSeparator 走兜底
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/size"] = { padding = { large = 1 }, margin = { small = 1 } }
package.loaded["ui/rendertext"] = { sizeUtf8Text = function() return { x = 0 } end }
package.loaded["gettext"] = function(s) return s end
package.loaded["logger"] = {
    info = function() end, warn = function() end,
    dbg = function() end, err = function() end,
}

local Util = require("ywbf/util")
local Config = require("ywbf/config")
local HttpClient = require("ywbf/httpclient")
Config:init(TEST_DIR)
local Suggest = require("ywbf/suggest")
local DeepSeek = require("ywbf/deepseek")

-- ================= 计数器：零 token 这条全靠它 =================
local http_calls, chat_calls = 0, 0
HttpClient.post = function()
    http_calls = http_calls + 1
    return '{"id":"s","choices":[{"index":0,"message":{"role":"assistant","content":"x"}}],'
        .. '"usage":{"prompt_tokens":1,"completion_tokens":1}}', 200, "OK", nil
end
DeepSeek.chat = function() chat_calls = chat_calls + 1 return "x", nil end

-- ================= 断言骨架 =================
local TOTAL, PASSED, FAILED = 0, 0, 0
local failures = {}
local function ok(cond, name, extra)
    TOTAL = TOTAL + 1
    if cond then
        PASSED = PASSED + 1; print("  PASS  " .. name)
    else
        FAILED = FAILED + 1
        failures[#failures + 1] = name
        print("  FAIL  " .. name .. (extra and (" -> " .. tostring(extra)) or ""))
    end
end
local function eq(a, b, name)
    ok(a == b, name, string.format("got=%s want=%s", tostring(a), tostring(b)))
end
local function section(t) print(""); print("=== " .. t .. " ===") end
local function has(s, sub)
    return type(s) == "string" and type(sub) == "string" and s:find(sub, 1, true) ~= nil
end
local function readFile(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local s = f:read("*all"); f:close(); return s
end

local function checkList(list, tag, maxlen)
    local bad_len, bad_utf8, bad_type = 0, 0, 0
    for _, q in ipairs(list) do
        if type(q) ~= "string" or q == "" then bad_type = bad_type + 1 end
        if type(q) == "string" then
            if Util.utf8len(q) > (maxlen or Suggest.MAX_LEN) then bad_len = bad_len + 1 end
            if Util.sanitizeUtf8(q) ~= q then bad_utf8 = bad_utf8 + 1 end
        end
    end
    eq(bad_type, 0, tag .. "：非空字符串")
    eq(bad_len, 0, tag .. "：每条 <= " .. tostring(maxlen or Suggest.MAX_LEN) .. " 字")
    eq(bad_utf8, 0, tag .. "：每条都是合法 UTF-8（sanitizeUtf8(q)==q）")
end

-- 从输入框的 buttons 里找「你可能想问」按钮
local function findSuggestButton(d)
    for _, row in ipairs((d and d._t and d._t.buttons) or {}) do
        for _, b in ipairs(row) do
            if has(b.text, "你可能想问") then return b end
        end
    end
end

local SEL = "他把灯放下，回头看了一眼门口，低声说道：“你还回来吗？”"
local CTX = "前文：雪下了整夜。后文：门外的脚印一直延伸到河边。"
local LONG = string.rep("这一段写的是雪夜里两个人隔着桌子说话，谁也不肯先把话挑明。", 4)

-- ================= 0 前置 =================
section("0. 前置：三个 UI 模块真的被 require 进来（跑的是真代码）")
local SuggestPicker = require("ui/suggestpicker")
local ChatDialog = require("ui/chatdialog")
local ToastCard = require("ui/toastcard")
local Asker = require("ui/asker")
ok(type(SuggestPicker) == "table" and type(SuggestPicker.list) == "function"
    and type(SuggestPicker.show) == "function" and type(SuggestPicker.enabled) == "function",
    "ui/suggestpicker.lua 真加载：list/show/enabled 都在")
ok(type(ChatDialog) == "table" and type(ChatDialog.open) == "function", "ui/chatdialog.lua 真加载")
ok(type(ToastCard) == "table" and type(ToastCard.open) == "function", "ui/toastcard.lua 真加载")

local ask_sync_calls, submit_async_calls = 0, 0
local real_askSync, real_submitAsync = Asker.askSync, Asker.submitAsync
Asker.askSync = function(...) ask_sync_calls = ask_sync_calls + 1 return real_askSync(...) end
Asker.submitAsync = function(...) submit_async_calls = submit_async_calls + 1 return real_submitAsync(...) end

Config:set("show_suggestions", true)
eq(SuggestPicker:enabled(), true, "开关默认开：enabled() == true")
eq(Config.DEFAULTS.show_suggestions, true, "Config.DEFAULTS.show_suggestions 默认 true（变异 2 的命门）")
do
    local cfg = readFile(PLUGIN_DIR .. "/ywbf/config.lua") or ""
    ok(#cfg > 2000, "config.lua 真的读到了字节（静态断言非空转）", #cfg)
    ok(has(cfg, "show_suggestions = true"), "config 源码里默认值确实是 true")
end

-- ================= 1 模块契约 =================
section("1. 模块契约：永不返回 nil、永不抛异常、条数受 max 约束")
do
    local cases = {
        { name = "list(nil)",                opts = nil },
        { name = "list({})",                 opts = {} },
        { name = "list({max=0})",            opts = { max = 0 } },
        { name = "list({kind=\"乱写\"})",    opts = { kind = "乱写", selected = SEL } },
        { name = "list({selected=123})",     opts = { selected = 123 } },
        { name = "list({selected=true,max=\"x\"})", opts = { selected = true, max = "x" } },
        { name = "list({max=99})",           opts = { max = 99, selected = SEL } },
        { name = "list({selected=nil,context=nil})", opts = { selected = nil, context = nil } },
    }
    for _, c in ipairs(cases) do
        local okc, res = pcall(Suggest.list, c.opts)
        ok(okc, c.name .. " 不抛异常", tostring(res))
        if okc then
            ok(type(res) == "table", c.name .. " 返回 table", tostring(res))
            ok(type(res) == "table" and #res >= 1, c.name .. " 条数 >= 1", type(res) == "table" and #res or res)
            if type(res) == "table" then
                local lim = (type(c.opts) == "table" and type(c.opts.max) == "number"
                    and c.opts.max >= 1) and math.min(math.floor(c.opts.max), Suggest.MAX_LIMIT)
                    or Suggest.DEFAULT_MAX
                ok(#res <= lim, c.name .. " 条数 <= " .. lim, #res)
                checkList(res, c.name)
            end
        end
    end
end

-- ================= 2 深聊新契约（含层级栈回归） =================
section("2. 深聊（chatdialog）：先关输入框再弹层，选中后带问题重开")
do
    http_calls, chat_calls = 0, 0
    ask_sync_calls, submit_async_calls = 0, 0
    resetUI()

    local expected = Suggest.list({ kind = "chat",
        selected = Util.sanitizeForDisplay(SEL), context = CTX })
    print("  [证据] 深聊建议列表(" .. #expected .. ")：" .. table.concat(expected, " ｜ "))
    ChatDialog:open(nil, { selected = SEL, page_text = CTX, book_fp = "s_fp" })

    eq(#input_dialogs, 1, "深聊打开后弹出了一个输入框")
    ok(stackHas("input"), "前置：此时栈里确实有输入框（下面的层级断言不是空转）")
    local d = input_dialogs[1]
    eq(d._t.input, "", "首次打开时输入框为空")

    local btn = findSuggestButton(d)
    ok(btn ~= nil, "输入框里有「你可能想问」按钮")
    if not btn then return end
    -- 真机反馈（2026-09-19）：按钮右侧那个括号数字会让用户误以为是"几条里中选了第几条"，
    -- 已要求去掉计数，文案回归纯文本「你可能想问」。
    -- 这里反过来钉：文案必须**不含**任何括号数字（半角/全角都算），防止哪天又悄悄加回来。
    eq(btn.text, "你可能想问", "按钮文案就是「你可能想问」，不带括号计数", btn.text)
    eq(btn.text:match("[（(]%d+[）)]"), nil, "按钮文案里没有任何形式的括号数字", btn.text)
    eq(btn.enabled, true, "有建议时按钮 enabled=true")
    eq(http_calls, 0, "打开提问框 + 生成建议期间 HttpClient.post = 0（零 token）")

    -- 真的点「你可能想问」
    local inputs_before, buttons_before = #input_dialogs, #button_dialogs
    btn.callback()

    -- ---- 本次事故的回归断言：弹层弹出时，栈里不该还有输入框 ----
    eq(#button_dialogs, buttons_before + 1, "点了入口后真的弹出了建议页（ButtonDialog）")
    local bd = button_dialogs[#button_dialogs]
    local show_ev = nil
    for _i = #events, 1, -1 do
        if events[_i].op == "show" and events[_i].w == bd then show_ev = events[_i] break end
    end
    ok(show_ev ~= nil, "找到了建议页入栈那一次事件")
    if show_ev then
        ok(not listHas(show_ev.before, "input"),
            "【本次事故回归】建议页弹出时，栈里没有未关闭的输入框（否则弹层会被键盘盖住点不动）",
            table.concat(show_ev.before, ","))
        local prev = nil
        for _i = #events, 1, -1 do
            if events[_i] == show_ev then prev = events[_i - 1] break end
        end
        ok(prev ~= nil and prev.op == "close" and prev.kind == "input",
            "顺序正确：紧邻建议页 show 之前的那一步就是 close(输入框)",
            prev and (prev.op .. "/" .. prev.kind) or "none")
    end
    ok(not stackHas("input"), "弹层打开期间，栈里确实已经没有输入框了")
    ok(stackHas("button"), "弹层打开期间，栈里确实有建议页")

    -- 弹层内容
    eq(bd.title, "你可能想问：", "建议页标题是「你可能想问：」")
    -- 「AI 引导式提问」上线后，本地建议页比原先多一行「让小望来问」：
    -- 布局固定为 [问题 × N] + [AI 入口] + [返回]，三样都得钉住，别只数总数。
    eq(#bd.buttons, #expected + 2, "建议页行数 = 问题数 + AI 入口 + 「返回」")
    local ai_row_text = bd.buttons[#expected + 1]
        and bd.buttons[#expected + 1][1] and bd.buttons[#expected + 1][1].text or ""
    ok(ai_row_text:find("用一次额度", 1, true) ~= nil,
        "倒数第二行是「让小望来问（用一次额度）」", ai_row_text)
    for i, q in ipairs(expected) do
        eq(bd.buttons[i] and bd.buttons[i][1] and bd.buttons[i][1].text, q,
            "建议页第 " .. i .. " 行就是列表第 " .. i .. " 条")
    end
    eq(bd.buttons[#bd.buttons] and bd.buttons[#bd.buttons][1].text, "返回", "最后一行是「返回」")
    eq(http_calls, 0, "弹建议页期间 HttpClient.post 仍为 0")

    -- 真的点第 2 条
    bd.buttons[2][1].callback()
    eq(#input_dialogs, inputs_before + 1, "选中一条后重新打开了一个输入框（不是回填旧框）")
    local nd = input_dialogs[#input_dialogs]
    eq(nd._t.input, expected[2], "新输入框的初始内容就是被点中的那条问题（prefill 没丢）")
    ok(nd._t.input ~= nil, "prefill 为空时是空串而不是 nil")
    ok(not stackHas("button"), "选中后建议页已出栈")
    ok(stackHas("input"), "选中后栈里是重新打开的输入框")
    eq(http_calls, 0, "选中回填后 HttpClient.post = 0（误触不花钱）")
    eq(chat_calls, 0, "选中回填后 DeepSeek 调用数为 0")
    eq(ask_sync_calls, 0, "选中回填后**没有**发起提问（只回填是设计意图）")
    eq(submit_async_calls, 0, "选中回填后没有提交任何任务")
    print(string.format("  [证据] prefill=%s ｜ 按钮文案=%s ｜ http=%d chat=%d askSync=%d submit=%d",
        tostring(nd._t.input), tostring(btn.text),
        http_calls, chat_calls, ask_sync_calls, submit_async_calls))

    -- 「返回」→ 空着重开
    local nd_btn = findSuggestButton(nd)
    ok(nd_btn ~= nil, "重开的输入框里仍有「你可能想问」入口")
    if nd_btn then
        local before2 = #input_dialogs
        nd_btn.callback()
        local bd2 = button_dialogs[#button_dialogs]
        local back_row = bd2.buttons[#bd2.buttons][1]
        eq(back_row.text, "返回", "最后一行是「返回」")
        back_row.callback()
        eq(#input_dialogs, before2 + 1, "点「返回」后重新打开了输入框")
        local d3 = input_dialogs[#input_dialogs]
        eq(d3._t.input, "", "点「返回」后新输入框为空（不是上一条问题）")
        ok(d3._t.input ~= expected[2], "返回后不会把刚才那条问题带回来")
        ok(not stackHas("button"), "返回后建议页已出栈")
    end

    -- tap_close_callback（点空白处）→ 同样要空着重开
    do
        local before3 = #input_dialogs
        local dcur = input_dialogs[#input_dialogs]
        local bcur = findSuggestButton(dcur)
        if bcur then
            bcur.callback()
            local bd3 = button_dialogs[#button_dialogs]
            ok(type(bd3.tap_close_callback) == "function", "建议页挂了 tap_close_callback（点空白也能关）")
            if type(bd3.tap_close_callback) == "function" then
                bd3.tap_close_callback()
                eq(#input_dialogs, before3 + 1, "点空白关闭后也重新打开了输入框")
                eq(input_dialogs[#input_dialogs]._t.input, "", "点空白关闭后新输入框为空")
            end
        end
    end
end

-- ================= 3 开关 =================
section("3. 开关：show_suggestions=false 后列表为空、入口置灰、点开不弹窗")
do
    Config:set("show_suggestions", false)
    eq(SuggestPicker:enabled(), false, "关掉后 enabled() == false")
    eq(#SuggestPicker:list({ kind = "chat", selected = SEL }), 0,
        "关掉后 SuggestPicker:list 返回空表（变异 4 的命门）")

    resetUI()
    ChatDialog:open(nil, { selected = SEL, page_text = CTX, book_fp = "s_fp" })
    local d = input_dialogs[#input_dialogs]
    local btn = findSuggestButton(d)
    ok(btn ~= nil, "关掉后按钮仍在（只是置灰），不是整行消失")
    if btn then
        eq(btn.enabled, false, "关掉后按钮 enabled=false（变异 3 的命门）")
        eq(btn.text, "你可能想问", "关掉后按钮文案仍是「你可能想问」（没有括号计数，也没有别的字样）", btn.text)
        eq(btn.text:match("[（(]%d+[）)]"), nil, "关掉后按钮文案里同样没有括号数字", btn.text)
    end
    local before = #button_dialogs
    local popped = SuggestPicker:show({ kind = "chat", selected = SEL }, function() end)
    eq(popped, false, "关掉后 SuggestPicker:show 返回 false（不该弹窗）")
    eq(#button_dialogs, before, "关掉后确实没有弹出建议页")

    Config:set("show_suggestions", true)
    resetUI()
    ChatDialog:open(nil, { selected = SEL, page_text = CTX, book_fp = "s_fp" })
    eq(findSuggestButton(input_dialogs[#input_dialogs]).enabled, true, "改回 true 后入口恢复可用")
end

-- ================= 4 个性化 =================
section("4. 个性化：不同选中文本给出不同列表；空选中回落通用兜底")
do
    local inputs = {
        { tag = "短词",       sel = "望乡" },
        { tag = "长段",       sel = LONG },
        { tag = "含对话引号", sel = "他说道：“你来了。”" },
        { tag = "含问号",     sel = "你真的要走吗？" },
        { tag = "含人称",     sel = "父亲把手放下，没有看他" },
    }
    local seen_sig = {}
    for _, c in ipairs(inputs) do
        local l = Suggest.list({ kind = "chat", selected = c.sel, context = CTX })
        ok(type(l) == "table" and #l >= 1, c.tag .. "：列表非空")
        checkList(l, c.tag)
        local sig = table.concat(l, "|")
        ok(seen_sig[sig] == nil, c.tag .. "：与其他输入得到的列表不同", sig)
        seen_sig[sig] = true
    end
    local distinct = 0
    for _ in pairs(seen_sig) do distinct = distinct + 1 end
    eq(distinct, 5, "五份列表两两互不相同（个性化真的按文本走）")

    local short_l = Suggest.list({ kind = "chat", selected = "望乡" })
    local embedded = false
    for _, q in ipairs(short_l) do if has(q, "望乡") then embedded = true end end
    ok(embedded, "短词被真的嵌进问题里（如「「望乡」这个词该怎么理解？」）", table.concat(short_l, " / "))

    local empty_l = Suggest.list({ kind = "chat", selected = "" })
    ok(type(empty_l) == "table" and #empty_l >= 1, "空选中仍返回非空列表")
    local with_term = 0
    for _, q in ipairs(empty_l) do if has(q, "「") then with_term = with_term + 1 end end
    eq(with_term, 0, "空选中时不会出现「…」这种个性化提问（已回落通用兜底）")
end

-- ================= 5 脏字节 =================
section("5. 脏字节：非法 UTF-8 不得泄漏进建议问题")
do
    local dirty = "A\128B\237\160\128望乡\255“你来了”"
    local l = Suggest.list({ kind = "chat", selected = dirty, context = dirty })
    ok(type(l) == "table" and #l >= 1, "脏字节输入下仍返回非空列表")
    checkList(l, "脏字节")
    local dirty_hit = 0
    for _, q in ipairs(l) do if Util.sanitizeUtf8(q) ~= q then dirty_hit = dirty_hit + 1 end end
    eq(dirty_hit, 0, "每条建议都已是合法 UTF-8（脏字节被净化在生成之前）")
    local l2 = SuggestPicker:list({ kind = "chat", selected = dirty })
    local dirty_hit2 = 0
    for _, q in ipairs(l2) do if Util.sanitizeUtf8(q) ~= q then dirty_hit2 = dirty_hit2 + 1 end end
    eq(dirty_hit2, 0, "UI 层拿到的同样是净化后的文本")
end

-- ================= 6 轻问新契约（同一套，独立验一遍） =================
section("6. 轻问（toastcard）：先关再弹、带问题重开、取消空着重开")
do
    http_calls, chat_calls = 0, 0
    ask_sync_calls, submit_async_calls = 0, 0
    resetUI()

    Config:set("show_suggestions", true)
    local expected = Suggest.list({ kind = "light",
        selected = Util.sanitizeForDisplay(SEL), context = CTX })
    print("  [证据] 轻问建议列表(" .. #expected .. ")：" .. table.concat(expected, " ｜ "))
    ToastCard:open(nil, { selected = SEL, page_text = CTX, book_fp = "s_fp" })

    eq(#input_dialogs, 1, "轻问打开后弹出了一个输入框")
    ok(stackHas("input"), "前置：此时栈里确实有输入框（层级断言不是空转）")
    local d = input_dialogs[1]
    local btn = findSuggestButton(d)
    ok(btn ~= nil, "轻问输入框里有「你可能想问」按钮")
    if not btn then return end
    eq(btn.text, "你可能想问", "轻问按钮文案就是「你可能想问」，不带括号计数", btn.text)
    eq(btn.text:match("[（(]%d+[）)]"), nil, "轻问按钮文案里没有任何形式的括号数字", btn.text)
    eq(btn.enabled, true, "轻问有建议时 enabled=true")

    local inputs_before = #input_dialogs
    btn.callback()
    local bd = button_dialogs[#button_dialogs]
    local show_ev = nil
    for _i = #events, 1, -1 do
        if events[_i].op == "show" and events[_i].w == bd then show_ev = events[_i] break end
    end
    ok(show_ev ~= nil, "轻问：找到了建议页入栈事件")
    if show_ev then
        ok(not listHas(show_ev.before, "input"),
            "【本次事故回归·轻问】建议页弹出时栈里没有未关闭的输入框",
            table.concat(show_ev.before, ","))
        local prev = nil
        for _i = #events, 1, -1 do
            if events[_i] == show_ev then prev = events[_i - 1] break end
        end
        ok(prev ~= nil and prev.op == "close" and prev.kind == "input",
            "顺序正确·轻问：紧邻建议页 show 之前的那一步就是 close(输入框)",
            prev and (prev.op .. "/" .. prev.kind) or "none")
    end
    ok(not stackHas("input"), "弹层打开期间（轻问），栈里确实已经没有输入框了")
    ok(stackHas("button"), "弹层打开期间（轻问），栈里确实有建议页")
    eq(bd.buttons[1][1].text, expected[1], "轻问建议页第 1 行 == 列表第 1 条")

    bd.buttons[1][1].callback()
    eq(#input_dialogs, inputs_before + 1, "轻问选中后重新打开了输入框")
    local nd = input_dialogs[#input_dialogs]
    eq(nd._t.input, expected[1], "轻问新输入框的初始内容 == 被点中的问题")
    eq(http_calls, 0, "轻问：回填后 HttpClient.post = 0")
    eq(submit_async_calls, 0, "轻问：回填后没有提交任务（只回填）")

    -- 轻问取消：返回 → 空着重开
    local nd_btn = findSuggestButton(nd)
    if nd_btn then
        local before = #input_dialogs
        nd_btn.callback()
        local bd2 = button_dialogs[#button_dialogs]
        bd2.buttons[#bd2.buttons][1].callback()
        eq(#input_dialogs, before + 1, "轻问点「返回」后重新打开了输入框")
        eq(input_dialogs[#input_dialogs]._t.input, "", "轻问返回后输入框为空")
    end
    -- 轻问点空白关闭
    do
        local before = #input_dialogs
        local bcur = findSuggestButton(input_dialogs[#input_dialogs])
        if bcur then
            bcur.callback()
            local bd3 = button_dialogs[#button_dialogs]
            ok(type(bd3.tap_close_callback) == "function", "轻问建议页也挂了 tap_close_callback")
            if type(bd3.tap_close_callback) == "function" then
                bd3.tap_close_callback()
                eq(#input_dialogs, before + 1, "轻问点空白关闭后重新打开了输入框")
                eq(input_dialogs[#input_dialogs]._t.input, "", "轻问点空白关闭后输入框为空")
            end
        end
    end

    Config:set("show_suggestions", false)
    resetUI()
    ToastCard:open(nil, { selected = SEL, page_text = CTX, book_fp = "s_fp" })
    eq(findSuggestButton(input_dialogs[#input_dialogs]).enabled, false, "轻问：关掉开关后入口置灰")
    Config:set("show_suggestions", true)
end

-- ================= 7 变异命门 =================
section("7. 变异命门（每条都要能被对应变异打红）")
do
    -- 7a 去掉 SuggestPicker:list 的 pcall → 异常冒泡
    local saved_list = Suggest.list
    Suggest.list = function() error("QA: 模拟 suggest 内部炸了") end
    local okc, res = pcall(SuggestPicker.list, SuggestPicker, { kind = "chat", selected = SEL })
    Suggest.list = saved_list
    ok(okc, "Suggest.list 抛异常时 SuggestPicker:list 不冒泡（pcall 还在）", tostring(res))
    ok(type(res) == "table", "降级后仍返回 table（不是 nil）", tostring(res))
    eq(type(res) == "table" and #res or -1, 0, "降级后是空表（入口据此置灰）")
    ok(#SuggestPicker:list({ kind = "chat", selected = SEL }) >= 1, "还原后列表恢复正常（无副作用）")

    -- 7b 传了 precomputed 就不该再算第二遍
    local saved2 = Suggest.list
    Suggest.list = function() error("QA: 不该在弹层里重新计算") end
    local ok2 = pcall(SuggestPicker.show, SuggestPicker, { kind = "chat" },
        function() end, { "问题一", "问题二" })
    Suggest.list = saved2
    ok(ok2, "传了 precomputed 时不再二次生成（弹层与按钮上的 N 必然是同一份）", tostring(ok2))

    -- 7c 静态：源码里的关键接线还在
    local sp_src = readFile(PLUGIN_DIR .. "/ui/suggestpicker.lua") or ""
    local cd_src = readFile(PLUGIN_DIR .. "/ui/chatdialog.lua") or ""
    local tc_src = readFile(PLUGIN_DIR .. "/ui/toastcard.lua") or ""
    ok(#sp_src > 1000 and #cd_src > 5000 and #tc_src > 2000, "三个源码文件都真的读到了字节")
    ok(has(sp_src, "if not self:enabled() then return {} end"),
        "suggestpicker 里「开关关掉返回空表」的判断还在")
    ok(has(cd_src, "enabled = #suggestions > 0"), "chatdialog 里 enabled 仍按条数算（没写死 true）")
    ok(has(tc_src, "enabled = #suggestions > 0"), "toastcard 里 enabled 仍按条数算（没写死 true）")
    ok(has(cd_src, "input = prefill or \"\""), "chatdialog 用 prefill 作为新输入框的初值")
    ok(has(tc_src, "input = prefill or \"\""), "toastcard 用 prefill 作为新输入框的初值")
    ok(has(sp_src, "tap_close_callback"), "suggestpicker 挂了 tap_close_callback（点空白也能关）")
end

-- ================= 8 全程零 token =================
section("8. 全程零 token 复核（重构后仍不许有请求）")
do
    http_calls, chat_calls = 0, 0
    ask_sync_calls, submit_async_calls = 0, 0
    resetUI()
    Config:set("show_suggestions", true)
    for _i = 1, 20 do
        Suggest.list({ kind = "chat", selected = LONG, context = CTX })
        Suggest.list({ kind = "light", selected = "望乡" })
        SuggestPicker:list({ kind = "chat", selected = SEL, context = CTX })
    end
    ChatDialog:open(nil, { selected = SEL, page_text = CTX, book_fp = "s_fp" })
    ToastCard:open(nil, { selected = SEL, page_text = CTX, book_fp = "s_fp" })
    SuggestPicker:show({ kind = "chat", selected = SEL }, function() end)
    eq(http_calls, 0, "60 次生成 + 3 次开框 + 1 次弹窗后 HttpClient.post 仍为 0")
    eq(chat_calls, 0, "DeepSeek:chat 调用数为 0")
    eq(ask_sync_calls, 0, "Asker:askSync 调用数为 0")
    eq(submit_async_calls, 0, "Asker:submitAsync 调用数为 0")
end

Config:set("show_suggestions", true)

section("RESULTS")
print(string.format("TOTAL: %d  PASSED: %d  FAILED: %d", TOTAL, PASSED, FAILED))
if FAILED > 0 then
    print("")
    print("失败明细：")
    for _, m in ipairs(failures) do print("  - " .. m) end
end
