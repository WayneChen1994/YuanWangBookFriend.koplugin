--[[--
QA 独立复核脚本：复核工程师对 P0/P1/P2 的修复，以及他对我 verify_spoiler.lua
里 7 条 GAP 断言的 1:1 替换有没有被放宽。

原则：**不复用工程师的夹具、不复用他的断言文本**。这里另造一本 12 章假书
（阿拉伯/中文序号混排）、另造泄漏串、另选页码位置，用同样的语义重新断言一遍。
如果他的实现是真的修好了，我这边的全新夹具也必须全绿；如果他只是在我原来的
夹具上"调参过拟合"，这里就会红。

跑法（KPW4）：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     YWBF_PLUGIN_DIR=/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin \
     YWBF_TEST_DIR=/mnt/us/ywbf_dev/testdata \
     ./luajit /mnt/us/ywbf_dev/tools/qa_audit_p1p2.lua
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
    if cond then
        PASSED = PASSED + 1
        print("  PASS  " .. name)
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
local function readFile(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local s = f:read("*all"); f:close(); return s
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

-- ---------------- 全新夹具：12 章《雪夜行》 ----------------
local CN = { "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二" }
local function tocB()
    local t = {}
    for i = 1, 12 do
        t[i] = { title = "第" .. CN[i] .. "章 雪夜其" .. CN[i], page = i * 10, depth = 0 }
    end
    return t
end
local function uiB(toc, page, total)
    return {
        document = {
            info = { has_pages = false, number_of_pages = total or 150 },
            getPageCount = function() return total or 150 end,
            getCurrentPage = function() return page end,
            getXPointer = function() return "/body/DocFragment[4]" end,
            getToc = function() return toc end,
        },
    }
end

-- 注意：目录标题带副标题（"第九章 雪夜其九"），匹配要求**整条标题**出现，
-- 所以泄漏串必须包含完整标题，否则测的是"字面不一致"，不是防剧透本身。
local LEAK = "第九章 雪夜其九 终局密语QWERTY"   -- 完整未读标题 + 泄漏原文
local LEAK_PARTIAL = "第九章 终局密语QWERTY"    -- 只有序号、缺副标题（用于测字面不一致）
local SEL = "她把信纸折了两折，塞进炉膛。"
local BEFORE = "窗外的雪下得比昨夜更密。"
local AFTER = "火苗窜了一下，又慢慢矮下去。"

local function pageText(leak_pos)
    -- leak_pos: "tail" 泄漏在最后；"head" 泄漏紧贴选中句之后
    if leak_pos == "head" then
        return table.concat({ BEFORE, SEL, LEAK .. "这里直接写明了真凶与结局。", AFTER }, "\n")
    end
    return table.concat({ BEFORE, SEL, AFTER, "\n" .. LEAK .. "这里直接写明了真凶与结局。" }, "\n")
end

local function runPipe(progress, question, opts)
    opts = opts or {}
    local pt = opts.page_text or pageText("tail")
    local win = Context.fromSelection(pt, SEL, 800)
    local w2, cut = Spoiler.truncateWindow(win, progress)
    local ctx = Prompts.contextFromWindow(w2)
    if Util.isEmpty(ctx) then ctx = "【选中内容】\n" .. SEL end
    local msgs = Prompts.build(opts.kind or "explain", {
        context = ctx, selected = SEL, question = question, history = opts.history,
        spoiler_note = Prompts.spoilerNote(progress),
        spoiler_hint = Prompts.spoilerHint(progress),
    })
    local res, err = DeepSeek:chat(msgs, { spoiler_progress = progress })
    return res, err, cut, w2
end

-- ---------------- 0 前置 ----------------
section("0. 环境与新夹具自检")
if Crypto:init() then DeepSeek:setApiKey("qa-audit-key") end
if not DeepSeek:hasApiKey() then DeepSeek.getApiKey = function() return "qa-audit-key" end end
Config:set("spoiler_guard", true)
Config:set("spoiler_granularity", "chapter")

local prog = Spoiler.readProgress(uiB(tocB(), 45, 150), Spoiler.currentConfig())
eq(prog.chapter_index, 4, "新夹具：读到第 4 章（page=45）")
eq(prog.chapter_total, 12, "新夹具：共 12 章")
eq(#prog.unread_titles, 8, "新夹具：未读 8 章（第 5–12 章）")
ok(has(pageText("tail"), LEAK), "前置：原文确实含泄漏串")

-- ---------------- 1 P0 复核 ----------------
section("1. P0 复核：入口是否都带 progress + 结构性兜底")
local main_src = readFile(PLUGIN_DIR .. "/main.lua") or ""
local miss = 0
if main_src ~= "" then
    main_src = main_src:gsub("\r\n", "\n")
    local lines = {}
    for l in ("\n" .. main_src):gmatch("\n([^\n]*)") do lines[#lines + 1] = l end
    for i, l in ipairs(lines) do
        -- 只看真正会发起提问的三个入口；showResult 只是弹窗展示，不需要 progress
        if l:find("Asker:", 1, true) and (l:find("askAndShow", 1, true)
            or l:find("submitAsync", 1, true) or l:find("askSync", 1, true)) then
            local block, j = "", i
            while j <= #lines do
                block = block .. lines[j] .. "\n"
                if lines[j]:find("^%s*%}%)") then break end
                j = j + 1
            end
            if not block:find("progress", 1, true) then
                miss = miss + 1
                print("        [仍缺 progress] main.lua:" .. i)
            end
        end
    end
end
eq(miss, 0, "P0：main.lua 每个 Asker 调用点都带 progress")
ok(has(main_src, "setProgressProvider"), "P0：main.lua 注册了进度兜底 provider")
local asker_src = readFile(PLUGIN_DIR .. "/ui/asker.lua") or ""
ok(has(asker_src, "fetchProgress"), "P0：asker 内会主动补取进度")
ok(has(asker_src, "progress missing at"), "P0：取不到时打 warn 而不是静默")

-- 真跑一遍「已传 progress」的解释流程：泄漏零命中、问题保留
reply = "这段用了白描，笔法克制。"
local res1, err1 = runPipe(prog, "这句话什么意思", { kind = "explain" })
ok(res1 ~= nil, "P0：带 progress 的解释流程跑通", err1)
ok(hasNot(bodyText(), LEAK), "P0：带 progress 后泄漏串零命中（原 P0 现象已消失）")
ok(has(bodyText(), SEL), "P0：选中内容仍保留")
ok(has(bodyText(), "这句话什么意思"), "P0：用户提问没有被误剪")

-- ---------------- 2 P1-1：书开头 ----------------
section("2. P1-1 复核：页码早于首个目录条目（书开头）")
local ph = Spoiler.readProgress(uiB(tocB(), 5, 150), Spoiler.currentConfig())
eq(ph.chapter_index, 0, "P1-1：书开头 chapter_index=0（表示还没进第 1 章）")
eq(#(ph.unread_titles or {}), 12, "P1-1：书开头 12 章全部算未读")
local th, ih = Spoiler.truncate(LEAK .. "后面全是未读。", ph)
eq(ih.truncated, true, "P1-1：书开头会截断未读章节")
eq(th, "", "P1-1：未读原文零残留")
local nh = Prompts.spoilerNote(ph)
ok(hasNot(nh, "第 0"), "P1-1：不要把「还没进第 1 章」渲染成「第 0 / 12 章」", nh)
ok(has(nh, "防剧透约束"), "P1-1：书开头仍有防剧透约束")
-- 副作用登记：章节号 0 会让 scanAnswer 把所有「第 N 章」都判为未读
local ah, hh = Spoiler.sanitizeAnswer("这段伏笔在第一回就埋下了。", ph)
eq(hh, true, "P1-1 副作用：书开头时任何章节号都会被替换（整体未读，语义自洽）")
local an, hn = Spoiler.sanitizeAnswer("这段伏笔在第一回就埋下了。", prog)
eq(hn, false, "P1-1 回归：正常阅读中「已读章节号」不误伤")
eq(Spoiler.evaluate({ enabled = true }, ph, "凶手是谁"), true, "P1-1：书开头问凶手被拦")

-- ---------------- 3 P1-2：无目录回落百分比 ----------------
section("3. P1-2 复核：无目录自动回落百分比（含强度反例）")
local pn = Spoiler.readProgress(uiB({}, 35, 150), Spoiler.currentConfig())
eq(pn.granularity, "percent", "P1-2：无目录时粒度回落到 percent")
eq(pn.granularity_auto, true, "P1-2：标记为自动回落（不被 cfg 覆盖回 chapter）")
local merged = Spoiler.withConfig(pn, { enabled = true, granularity = "chapter" })
eq(merged.granularity, "percent", "P1-2：自动回落的 percent 不会被 cfg 覆盖回 chapter")
-- 泄漏在尾部 + 低百分比 → 被剪掉（有效）
local r2, e2 = runPipe(pn, "这句话什么意思", { kind = "explain", page_text = pageText("tail") })
ok(r2 ~= nil, "P1-2：无目录场景仍能提问", e2)
ok(hasNot(bodyText(), LEAK), "P1-2：泄漏在文本尾部时被比例裁剪掉")
ok(has(bodyText(), "这句话什么意思"), "P1-2：比例裁剪不会切碎用户提问")
-- **强度反例**：泄漏紧贴选中句之后 + 读到 67% → 比例裁剪必须保留 2/3，泄漏漏网
local pn_hi = Spoiler.readProgress(uiB({}, 100, 150), Spoiler.currentConfig())
ok(pn_hi.percent > 60, "P1-2 反例前置：当前进度 >60%", pn_hi.percent)
local r3 = runPipe(pn_hi, "这句话什么意思",
    { kind = "explain", page_text = pageText("head") })
ok(r3 ~= nil, "P1-2 反例：高进度场景能提问")
ok(has(bodyText(), LEAK), "P1-2 强度反例：泄漏紧贴选中句时仍会进 payload（百分比是粗粒度，非真隔离）")

-- ---------------- 4 P2-1：行内章节标题 ----------------
section("4. P2-1 复核：行内「第X章」放宽 + 误伤回归")
local t1, i1 = Spoiler.truncate("他说到第九章 雪夜其九的时候就停住了，后面全是未读。", prog)
eq(i1.truncated, true, "P2-1：行内出现的未读章节标题被识别")
ok(hasNot(t1, "后面全是未读"), "P2-1：其后正文一并剪掉")
-- 真实世界弱点登记：目录标题带副标题时，正文只出现「第九章」这种短写法 → 匹配不上
-- 原 GAP-D'：目录标题含副标题（"第九章 雪夜其九"）时，正文里只写序号的短写法匹配不上
-- 工程师修复后：额外从目录标题抽出序号片段作为附加标记，简写/全写都能命中
local tp, ip = Spoiler.truncate("他说到第九章的时候就停住了，后面全是未读。", prog)
eq(ip.truncated, true, "GAP-D' 修复：正文里的短写法（只写序号、缺副标题）也能命中")
ok(hasNot(tp, "后面全是未读"), "GAP-D' 修复：该情况下未读原文零残留")
-- 全写版本仍要命中（不能因为加了短写法就丢掉整条标题匹配）
local tf, if_ = Spoiler.truncate("他说到第九章 雪夜其九的时候就停住了，后面全是未读。", prog)
eq(if_.truncated, true, "GAP-D' 回归：全写版本同样命中")
local t2, i2 = Spoiler.truncate("铺垫结束。第九章 雪夜其九\n未读正文。", prog)
eq(i2.truncated, true, "P2-1：句号后的标题仍被识别（旧行为未回退）")
-- 误伤回归：非序号类标题必须仍然要求边界
local prog_word = {
    enabled = true, granularity = "chapter", chapter_index = 4, chapter_total = 12,
    unread_titles = { "终局", "雪夜其九" },
}
local t3, i3 = Spoiler.truncate("这个故事的终局很精彩。", prog_word)
eq(i3.truncated, false, "P2-1 误伤回归：句中同名的非序号标题不截断")
eq(t3, "这个故事的终局很精彩。", "P2-1 误伤回归：原样返回")
local t4, i4 = Spoiler.truncate("这里埋下了终局的伏笔，后面全是未读。", prog_word)
eq(i4.truncated, false, "P2-1 误伤回归：非序号标题在句中仍不截断")
local t5, i5 = Spoiler.truncate("铺垫完了。终局那一段还没到。", prog_word)
eq(i5.truncated, true, "P2-1：非序号标题在句首/标点后仍会被截断")
-- 已读章节标题不该被当成未读
local t6, i6 = Spoiler.truncate("如第三章所述，人物已出场。", prog)
eq(i6.truncated, false, "P2-1：已读章节标题不误伤")

-- ---------------- 5 P2-2：提问引用未读内容 ----------------
section("5. P2-2 复核：提问里引用未读内容 → 整句回模糊话术")
local b1, n1, r1 = Spoiler.evaluate({ enabled = true }, prog, "请问「" .. LEAK .. "」是什么意思")
eq(b1, true, "P2-2：提问引用未读章节 → 拦截")
eq(r1, Spoiler.REFUSAL, "P2-2：返回标准模糊话术")
local b2 = Spoiler.evaluate({ enabled = true }, prog, "请问第三章里这个人是谁")
eq(b2, false, "P2-2 误伤回归：引用已读章节不拦截")
local b3 = Spoiler.evaluate({ enabled = true }, prog, nil)
eq(b3, false, "P2-2：无提问内容不拦截（释义/摘要不受影响）")
local b4 = Spoiler.evaluate({ enabled = true }, prog, "这句话的写法有什么讲究")
eq(b4, false, "P2-2：正常提问不拦截")
local b5 = Spoiler.evaluate({ enabled = false }, prog, "请问「" .. LEAK .. "」是什么意思")
eq(b5, false, "P2-2：开关关闭时不拦截")

-- ---------------- 6 端到端回归（新夹具，chat + 历史） ----------------
section("6. 端到端回归：新夹具 chat + 多轮历史")
local hist = { { role = "user", content = "上一轮贴的原文：第九章 雪夜其九 未读段落ZZZ。" } }
reply = "这个伏笔要到第十二章才揭晓。"
local r7, e7 = runPipe(prog, "请解释这段", { kind = "chat", history = hist })
ok(r7 ~= nil, "chat 流程跑通", e7)
ok(hasNot(bodyText(), LEAK), "历史与上下文里的未读章节都零命中")
ok(hasNot(bodyText(), "未读段落ZZZ"), "多轮历史里的未读原文零命中")
ok(has(bodyText(), SEL), "选中内容保留")
eq(r7.spoiler_hit, true, "回答侧命中后被替换")
eq(r7.content, Spoiler.WARNING, "替换为标准化模糊提示")

section("RESULTS")
print(string.format("TOTAL: %d  PASSED: %d  FAILED: %d", TOTAL, PASSED, FAILED))
if FAILED > 0 then
    print("")
    print("失败明细：")
    for _, m in ipairs(failures) do print("  - " .. m) end
end
