--[[--
QA 第二次独立复核：GAP-D'（目录标题带副标题 → 序号短写法并行匹配）与
P1-2 收紧（无目录绝对上限 AUTO_FALLBACK_MAX_CHARS）。

同样原则：**不复用工程师夹具、不复用他改过的断言**。第三本假书《寒江独钓》，
8 章、阿拉伯数字序号 + 副标题混排，另一组页码。

跑法（KPW4）：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     YWBF_PLUGIN_DIR=/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin \
     YWBF_TEST_DIR=/mnt/us/ywbf_dev/testdata \
     ./luajit /mnt/us/ywbf_dev/tools/qa_audit_gapD.lua
--]]--

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR") or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"
local TEST_DIR = os.getenv("YWBF_TEST_DIR") or "/mnt/us/ywbf_dev/testdata"

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

local Config = require("ywbf/config")
local Context = require("ywbf/context")
local HttpClient = require("ywbf/httpclient")
local Prompts = require("ywbf/prompts")
local Spoiler = require("ywbf/spoiler")
local Util = require("ywbf/util")
Config:init(TEST_DIR)
local DeepSeek = require("ywbf/deepseek")
local Crypto = require("ywbf/crypto")

local TOTAL, PASSED, FAILED = 0, 0, 0
local failures = {}
local function ok(cond, name, extra)
    TOTAL = TOTAL + 1
    if cond then PASSED = PASSED + 1; print("  PASS  " .. name)
    else
        FAILED = FAILED + 1
        failures[#failures + 1] = name .. (extra and (" -> " .. tostring(extra)) or "")
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
local function hasNot(s, sub) return not has(s, sub) end
local function contains(list, v)
    if type(list) ~= "table" then return false end
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

-- ---------------- stub ----------------
local captured, reply = nil, ""
local function jstr(s)
    if type(s) ~= "string" then return '""' end
    return '"' .. (s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")) .. '"'
end
HttpClient.post = function(url, headers, body, timeout)
    captured = { url = url, body = body }
    return '{"id":"s","choices":[{"index":0,"message":{"role":"assistant","content":'
        .. jstr(reply) .. '}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}', 200, "OK", nil
end
local function bodyText()
    if not captured or type(captured.body) ~= "string" then return "" end
    return (captured.body:gsub("\\/", "/"):gsub("\\n", "\n"):gsub('\\"', '"'):gsub("\\\\", "\\"))
end

-- ---------------- 第三本假书：《寒江独钓》8 章 ----------------
local TITLES = {
    "第1章 寒江", "第2章 雪夜", "第3章 独钓", "第4章 远行",
    "第5章 归舟", "第6章 故人", "第7章 灯下", "第8章 终局",
}
local function tocC()
    local t = {}
    for i = 1, 8 do t[i] = { title = TITLES[i], page = 7 + (i - 1) * 10, depth = 0 } end
    return t
end
local function uiC(toc, page, total)
    return {
        document = {
            info = { has_pages = false, number_of_pages = total or 90 },
            getPageCount = function() return total or 90 end,
            getCurrentPage = function() return page end,
            getXPointer = function() return "/body/DocFragment[9]" end,
            getToc = function() return toc end,
        },
    }
end

local SEL = "他把钓竿收起来，江面上只剩一层薄雾。"
local BEFORE = "渡口的石阶结了冰。"
local AFTER = "远处传来两声橹响。"
local LEAK_SHORT = "第7章 灯下密语ASDFGH"   -- 只有序号 + 自造词（模拟正文里的简写/误拼）
local LEAK_TOKEN = "第7章 后面全是未读内容"  -- 纯序号短写法
local LEAK_FULL = "第7章 灯下 未读原文QWERTY" -- 完整标题（含副标题）

local function pageC(mid)
    if mid == "head" then
        return table.concat({ BEFORE, SEL, LEAK_FULL .. "这里写明真凶。", AFTER }, "\n")
    end
    return table.concat({ BEFORE, SEL, AFTER, "\n" .. LEAK_FULL .. "这里写明真凶。" }, "\n")
end

local function runPipe(progress, question, opts)
    opts = opts or {}
    local pt = opts.page_text or pageC("tail")
    local win = Context.fromSelection(pt, SEL, 800)
    local w2, cut = Spoiler.truncateWindow(win, progress)
    local ctx = Prompts.contextFromWindow(w2)
    if Util.isEmpty(ctx) then ctx = "【选中内容】\n" .. SEL end
    local msgs = Prompts.build(opts.kind or "explain", {
        context = ctx, selected = SEL, question = question, history = opts.history,
        spoiler_note = Prompts.spoilerNote(progress),
        spoiler_hint = Prompts.spoilerHint(progress),
    })
    return DeepSeek:chat(msgs, { spoiler_progress = progress }), nil, cut, w2
end

-- ---------------- 0 前置 ----------------
section("0. 第三本夹具自检")
if Crypto:init() then DeepSeek:setApiKey("qa-audit-key2") end
if not DeepSeek:hasApiKey() then DeepSeek.getApiKey = function() return "qa-audit-key2" end end
Config:set("spoiler_guard", true)
Config:set("spoiler_granularity", "chapter")

local prog = Spoiler.readProgress(uiC(tocC(), 30, 90), Spoiler.currentConfig())
eq(prog.chapter_index, 3, "夹具：读到第 3 章（page=30，第3章在 27 页）")
eq(prog.chapter_total, 8, "夹具：共 8 章")
eq(#prog.unread_titles, 5, "夹具：未读 5 章（第 4–8 章）")
ok(has(pageC("tail"), LEAK_FULL), "前置：原文确实含完整标题泄漏串")

-- ---------------- 1 字段语义 ----------------
section("1. 字段语义：短写法不能污染 unread_titles 计数")
eq(#(prog.unread_tokens or {}), 5, "unread_tokens 抽出 5 个序号短写法")
ok(not contains(prog.unread_titles, "第7章"), "短写法没有被塞进 unread_titles（计数语义未被污染）")
ok(contains(prog.unread_titles, "第7章 灯下"), "unread_titles 仍是完整标题")
ok(contains(prog.unread_tokens, "第7章"), "unread_tokens 里确实有「第7章」")
local ml = Spoiler.markerList(prog)
eq(#ml, 10, "markerList = 5 条整标题 + 5 个短写法（去重后 10）")
ok(contains(ml, "第7章") and contains(ml, "第7章 灯下"), "markerList 两种写法都在")

-- ---------------- 2 GAP-D'：四条消费路径 ----------------
section("2. GAP-D'：短写法在四条路径上都被识别")
-- (a) 截断
local a1, ia1 = Spoiler.truncate("他说到" .. LEAK_TOKEN .. "。", prog)
eq(ia1.truncated, true, "截断：正文里的序号短写法被识别（修复前不认）")
ok(hasNot(a1, "后面全是未读内容"), "截断：其后正文零残留")
-- (b) 截断：完整标题（不能因为加了短写法就丢了整条匹配）
local a2, ia2 = Spoiler.truncate("他说到第7章 灯下的时候就停了，后面未读。", prog)
eq(ia2.truncated, true, "截断：完整标题（含副标题）仍命中")
ok(hasNot(a2, "后面未读"), "截断：完整标题后的正文也剪掉")
-- (c) 回答预警
local s1, h1 = Spoiler.sanitizeAnswer("这个伏笔要到第7章才揭晓。", prog)
eq(h1, true, "回答预警：短写法命中未读章节（修复前会漏）")
eq(s1, Spoiler.WARNING, "回答预警：替换为标准化模糊提示")
local s2, h2 = Spoiler.sanitizeAnswer("如第2章所述，人物已出场。", prog)
eq(h2, false, "回答预警误伤回归：已读章节短写法不拦")
local s3, h3 = Spoiler.sanitizeAnswer("这段用白描写江面，笔法克制。", prog)
eq(h3, false, "回答预警误伤回归：普通回答不拦")
-- (d) 提问拦截
local e1, _, r1 = Spoiler.evaluate({ enabled = true }, prog, "第7章讲了什么")
eq(e1, true, "提问拦截：问题里的未读短写法被拦")
eq(r1, Spoiler.REFUSAL, "提问拦截：返回模糊话术")
local e2 = Spoiler.evaluate({ enabled = true }, prog, "第3章讲了什么")
eq(e2, false, "提问拦截误伤回归：已读章节不拦")
-- (e) guardMessages（多轮历史）
local g1, gi1 = Spoiler.guardMessages({ { role = "user", content = "上轮贴的：第6章 未读原文ZZZ。" } }, prog)
eq(gi1.hits, 1, "guardMessages：历史里的短写法被剪")
ok(hasNot(g1[1].content, "未读原文ZZZ"), "guardMessages：未读原文零残留")
ok(has(g1[1].content, "上轮贴的"), "guardMessages：已读部分保留")

section("3. GAP-D' 误伤回归（短写法带来的新风险）")
local b1, ib1 = Spoiler.truncate("他一共写了八章，第3章最长。", prog)
eq(ib1.truncated, false, "短写法不误伤：只提到已读章节不截断")
local b2, ib2 = Spoiler.truncate("这本书第二十章以后才精彩。", prog)
eq(ib2.truncated, false, "短写法不误伤：「第二十章」不会命中「第X章」短写法")
local b3, ib3 = Spoiler.truncate("第一百零五章是后人补的。", prog)
eq(ib3.truncated, false, "短写法不误伤：长序号里不含短写法子串时不命中")
-- 非序号标题仍要求边界（不能被短写法逻辑带偏）
local pw = { enabled = true, granularity = "chapter", chapter_index = 3, chapter_total = 8,
             unread_titles = { "终局", "灯下" } }
local c1, ic1 = Spoiler.truncate("这个故事的终局很精彩。", pw)
eq(ic1.truncated, false, "非序号标题：句中同名仍不截断")
local c2, ic2 = Spoiler.truncate("铺垫完了。终局那一段还没到。", pw)
eq(ic2.truncated, true, "非序号标题：句首/标点后仍截断")

-- ---------------- 4 P1-2 绝对上限 ----------------
section("4. P1-2：无目录收紧（AUTO_FALLBACK_MAX_CHARS）")
local pn = Spoiler.readProgress(uiC({}, 72, 90), Spoiler.currentConfig())
eq(pn.granularity, "percent", "无目录：回落 percent")
eq(pn.granularity_auto, true, "无目录：标记自动回落")
ok(pn.percent > 75, "反例前置：当前进度 >75%", pn.percent)
-- 泄漏紧贴选中句 → 仍会进 payload（工程师已声明无法消灭，我保持这条为"未隔离"证据）
local long_after = string.rep("字", 200) .. LEAK_SHORT
local r5, _, cut5, w5 = runPipe(pn, "这句话什么意思",
    { kind = "explain", page_text = table.concat({ BEFORE, SEL, LEAK_SHORT, long_after }, "\n") })
ok(r5 ~= nil, "无目录高进度：能正常提问")
ok(has(bodyText(), LEAK_SHORT), "P1-2 反例（保持）：无目录且泄漏紧贴选中句 → 仍进 payload，属未隔离")
-- 但暴露窗口必须被压到上限以内
ok(type(w5) == "table", "无目录：拿到窗口")
ok(Util.utf8len(w5.after) <= Spoiler.AUTO_FALLBACK_MAX_CHARS,
    "P1-2 收紧生效：后文被压到绝对上限以内", Util.utf8len(w5.after))
ok(Util.utf8len(w5.after) < 200, "P1-2 收紧生效：确实比原始 200+ 字短", Util.utf8len(w5.after))
eq(cut5.reason, "percent", "P1-2：走的是百分比截断分支")
-- 有目录时不该被这道上限误伤
local win_big = { before = BEFORE, selected = SEL, after = string.rep("字", 300) }
local w6, i6 = Spoiler.truncateWindow(win_big, prog)
eq(i6.truncated, false, "有目录时不套用绝对上限（章内长文本原样保留）")
eq(Util.utf8len(w6.after), 300, "有目录时后文长度不被压缩")

-- ---------------- 5 端到端回归 ----------------
section("5. 端到端回归（第三本夹具，chat + 多轮历史）")
local hist = {
    { role = "user", content = "上轮我问过：第6章 未读原文POIUYT。" },
    { role = "user", content = "还有：第5章 归舟 那段也贴过。" },
}
reply = "这个伏笔要到第8章才揭晓。"
local r7, err7 = runPipe(prog, "请解释这段", { kind = "chat", history = hist })
ok(r7 ~= nil, "chat 流程跑通", err7)
local bt = bodyText()
ok(hasNot(bt, LEAK_FULL), "上下文里的未读章节零命中")
ok(hasNot(bt, "未读原文POIUYT"), "历史里的短写法泄漏零命中")
ok(hasNot(bt, "未读原文QWERTY"), "历史里的全写泄漏零命中")
ok(has(bt, SEL), "选中内容保留")
ok(has(bt, "请解释这段"), "用户提问保留")
ok(has(bt, "第 3 / 8 章"), "进度声明正确")
eq(r7.spoiler_hit, true, "回答侧命中被替换")

section("RESULTS")
print(string.format("TOTAL: %d  PASSED: %d  FAILED: %d", TOTAL, PASSED, FAILED))
if FAILED > 0 then
    print("")
    print("失败明细：")
    for _, m in ipairs(failures) do print("  - " .. m) end
end
