--[[--
M3 防剧透端到端独立验收脚本（QA 自造用例，不使用工程师的测试数据）。

目的：证明"未读章节内容真的没进 payload"，而不是证明函数存在。
手法：把 HttpClient.post 换成 stub 截获真实请求体（不发网络、不烧 token），
      对**最终 messages**做"包含/不包含"断言；每条"零命中"断言前都有
      对应的"前置：原文确实存在"断言，避免空断言。

在 KPW4 上跑：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     YWBF_PLUGIN_DIR=/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin \
     YWBF_TEST_DIR=/mnt/us/ywbf_dev/testdata \
     ./luajit /mnt/us/ywbf_dev/tools/verify_spoiler.lua
  YWBF_DEBUG=1 时打印每次请求体，便于人工核对。

LuaJIT = Lua 5.1 语义：无位运算符；文本截断一律走 Util.utf8sub。
--]]--

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR") or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"
local TEST_DIR = os.getenv("YWBF_TEST_DIR") or "/mnt/us/ywbf_dev/testdata"
local DEBUG = os.getenv("YWBF_DEBUG") == "1"

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
local Cache = require("ywbf/cache")
local Crypto = require("ywbf/crypto")
local logger = require("logger")

-- ---------------------------------------------------------------- 断言框架
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

local function section(title)
    print("")
    print("=== " .. title .. " ===")
end

-- nil 安全的包含判断
local function has(s, sub)
    return type(s) == "string" and type(sub) == "string" and s:find(sub, 1, true) ~= nil
end

local function hasNot(s, sub)
    return not has(s, sub)
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*all")
    f:close()
    return s
end

-- ---------------------------------------------------------------- HTTP stub
local captured = nil
local next_reply_content = ""

-- JSON 字符串转义（中文原样，JSON 只要求转义控制字符与引号）
local function jstr(s)
    if type(s) ~= "string" then return '""' end
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
        :gsub("\r", "\\r"):gsub("\t", "\\t")
    return '"' .. s .. '"'
end

HttpClient.post = function(url, headers, body, timeout)
    captured = { url = url, headers = headers, body = body, timeout = timeout }
    local resp = '{"id":"stub","choices":[{"index":0,"message":{"role":"assistant",'
        .. '"content":' .. jstr(next_reply_content) .. '}}],'
        .. '"usage":{"prompt_tokens":11,"completion_tokens":22,"total_tokens":33}}'
    return resp, 200, "OK", nil
end

--[[--
断言用的可读正文。
坑：设备上 KOReader 的 json 编码器会把 "/" 转义成 "\/"，直接对 body 做
    明文 find("第 3 / 10 章") 会得到假阴性 —— 先反转义再断言。
--]]
local function bodyText()
    if not captured or type(captured.body) ~= "string" then return "" end
    local s = captured.body
    s = s:gsub("\\/", "/"):gsub("\\n", "\n"):gsub("\\t", "\t")
        :gsub("\\r", "\r"):gsub('\\"', '"'):gsub("\\\\", "\\")
    return s
end

-- ---------------------------------------------------------------- 假书夹具
local CN = { "一", "二", "三", "四", "五", "六", "七", "八", "九", "十" }

-- 10 章假书：第 N 章 title="第N章"，page=N*10，全书 120 页，depth=0
local function fakeToc()
    local toc = {}
    for i = 1, 10 do
        toc[i] = { title = "第" .. CN[i] .. "章", page = i * 10, depth = 0 }
    end
    return toc
end

local function fakeUI(toc, current_page, total_pages)
    return {
        document = {
            info = { has_pages = false, number_of_pages = total_pages or 120 },
            getPageCount = function() return total_pages or 120 end,
            getCurrentPage = function() return current_page end,
            getXPointer = function() return "/body/DocFragment[3].fragment" end,
            getToc = function() return toc end,
        },
    }
end

local LEAK7 = "第七章密语XYZ"             -- 用户从后面章节粘贴进来的原文标记
local LEAK8 = "第八章未读原文ABCXYZ"       -- 塞在多轮历史里的未读原文标记
local KEEP_SELECTED = "他把手里的灯放下，回头看了一眼门口。"
local KEEP_BEFORE = "院子里那株老梅今年开得晚。"
local KEEP_AFTER = "风从回廊尽头吹过来，带着一点潮湿的土腥气。"

local page_text = table.concat({
    KEEP_BEFORE,
    KEEP_SELECTED,
    KEEP_AFTER,
    "\n" .. LEAK7 .. "这一段直接点明了真凶是老管家，并且交代了结局。",
}, "\n")

--[[--
按 ui/asker.lua:63-131 的调用顺序逐个调用**真实模块函数**（不复制任何判定逻辑）：
  Context.fromSelection -> Spoiler.truncateWindow -> Prompts.contextFromWindow
  -> Prompts.build(note/hint) -> DeepSeek:chat(guardMessages + sanitizeAnswer)
Asker:askSync 本身依赖 KOReader UI（Trapper/TextViewer），禁止在非 UI 环境 require。
--]]
local function runPipeline(progress, question, opts)
    opts = opts or {}
    local win = Context.fromSelection(page_text, KEEP_SELECTED, 800)
    local win2, cut = Spoiler.truncateWindow(win, progress)
    local ctx = Prompts.contextFromWindow(win2)
    if Util.isEmpty(ctx) then ctx = "【选中内容】\n" .. KEEP_SELECTED end
    local messages = Prompts.build(opts.kind or "explain", {
        context = ctx,
        selected = KEEP_SELECTED,
        question = question,
        history = opts.history,
        spoiler_note = Prompts.spoilerNote(progress),
        spoiler_hint = Prompts.spoilerHint(progress),
    })
    local res, err = DeepSeek:chat(messages, { spoiler_progress = progress })
    if DEBUG then
        print("---- REQUEST BODY ----")
        print(captured and captured.body or "(nil)")
        print("---- END ----")
    end
    return res, err, cut, win2, messages
end

--[[--
按真机语义设置开关：设置页写的是 Config.spoiler_guard，
currentConfig() 的结果会覆盖 prog，只改 prog 不算"用户在设置里关掉了开关"。
--]]
local function setGuard(enabled, granularity)
    Config:set("spoiler_guard", enabled)
    if granularity then Config:set("spoiler_granularity", granularity) end
end

-- ---------------------------------------------------------------- 0. 夹具自检
section("0. 环境与夹具自检")
ok(type(DeepSeek) == "table" and type(DeepSeek.chat) == "function",
    "ywbf/deepseek 可在设备 luajit 中加载（全程未触碰 KOReader UI）")
local cok = Crypto:init()
if cok then DeepSeek:setApiKey("verify-spoiler-test-key") end
if not DeepSeek:hasApiKey() then
    DeepSeek.getApiKey = function() return "verify-spoiler-test-key" end
end
local ak = DeepSeek:getApiKey()
ok(type(ak) == "string" and #ak > 0, "DeepSeek:getApiKey 可用（真实走配置 + 加密通道）")

setGuard(true, "chapter")
local prog = Spoiler.readProgress(fakeUI(fakeToc(), 35, 120), Spoiler.currentConfig())
eq(prog.chapter_index, 3, "夹具：当前定位到第 3 章")
eq(prog.chapter_total, 10, "夹具：共 10 章")
eq(#prog.unread_titles, 7, "夹具：未读章节标题 7 个（第 4–10 章）")
ok(has(Spoiler.progressLabel(prog), "第 3 / 10 章"), "夹具：进度描述正确", Spoiler.progressLabel(prog))
-- 前置断言：后续每条"零命中"以此为前提，防止空断言
ok(has(page_text, LEAK7), "前置：原始上下文确实含第 7 章泄漏串")
local raw_win = Context.fromSelection(page_text, KEEP_SELECTED, 800)
ok(has(raw_win.after, LEAK7), "前置：未加防护时后文窗口确实含第 7 章泄漏串")

-- ---------------------------------------------------------------- 1. 端到端
section("1. 端到端：第 7/8 章泄漏串零命中，第 1–3 章必须保留")
local history = {
    { role = "user", content = "上一轮我贴过一段原文：" .. LEAK8 .. "，这里写了真正的结局。" },
}
ok(has(history[1].content, LEAK8), "前置：历史里确实含第 8 章泄漏串")

next_reply_content = "这个伏笔要到第九章才揭晓，凶手其实是老管家。"
captured = nil
local res, err, cut, win2 = runPipeline(prog, "请解释这段写法的用意",
    { kind = "chat", history = history })
ok(res ~= nil, "管道跑通（stub 拦到请求，未发真实网络）", err)
ok(captured ~= nil and type(captured.body) == "string", "截获到最终请求体")
ok(bodyText() ~= "", "请求体非空")

local p1 = bodyText()
ok(hasNot(p1, LEAK7), "E2E-1 第 7 章泄漏串零命中")
ok(hasNot(p1, LEAK8), "E2E-2 第 8 章泄漏串（多轮历史）零命中")
ok(hasNot(p1, "交代了结局"), "E2E-3 泄漏串之后的正文也被剪掉")
ok(has(p1, KEEP_SELECTED), "E2E-4 选中内容保留（不是无脑全删）")
ok(has(p1, KEEP_BEFORE), "E2E-5 前文保留")
ok(has(p1, KEEP_AFTER), "E2E-6 已读章节的后文保留")
ok(has(p1, "上一轮我贴过一段原文"), "E2E-7 历史里已读部分保留")
ok(type(win2) == "table" and hasNot(win2.after or "", LEAK7), "E2E-8 上下文窗口层已物理剪掉未读段")
ok(cut.truncated == true, "E2E-9 窗口截断被标记为生效", cut.reason)
eq(tostring(cut.marker), "第七章", "E2E-10 截断点落在第七章标题")
ok(res.guard_truncated >= 1, "E2E-11 出口 guardMessages 命中并改写消息", res.guard_truncated)

-- 再跑一遍 explain 模板（长按菜单「AI 解释」「AI 摘要」走的就是它）
local res_ex, err_ex = runPipeline(prog, nil, { kind = "explain" })
ok(res_ex ~= nil, "explain 模板同样跑通", err_ex)
ok(hasNot(bodyText(), LEAK7), "E2E-12 explain 模板下第 7 章泄漏串同样零命中")
ok(has(bodyText(), KEEP_SELECTED), "E2E-13 explain 模板下选中内容保留")
ok(has(bodyText(), "200 字以内"), "E2E-14 explain 模板的长度约束未被破坏")

section("2. system + user 双保险 prompt 注入")
runPipeline(prog, nil, { kind = "explain" })
local p2 = bodyText()
ok(has(p2, "防剧透约束"), "system 侧含最高优先级防剧透约束")
ok(has(p2, "第 3 / 10 章"), "system/user 侧含当前进度声明（第 3 / 10 章）")
ok(has(p2, "不许引用"), "system 侧含禁止引用截断点后内容的约束")
ok(has(p2, "我只读到"), "user 侧含进度提醒")

section("3. 回答侧：命中未读章节号 / 标题 → 替换为标准化模糊提示")
eq(res.spoiler_hit, true, "回答命中剧透被标记")
eq(res.content, Spoiler.WARNING, "回答被替换为标准化模糊提示")
ok(hasNot(res.content, "第九章"), "替换后不含未读章节信息")
local _, clean_hit = Spoiler.sanitizeAnswer("这段用了白描，笔法克制。", prog)
eq(clean_hit, false, "正常回答不误伤")
local _, wrong_hit = Spoiler.sanitizeAnswer("如第三章所述，人物已经出场。", prog)
eq(wrong_hit, false, "提及已读章节不误伤")

section("4. 反向用例：设置里关掉开关后不再干预")
setGuard(false)
eq(Spoiler.currentConfig().enabled, false, "设置页开关落到 Config，currentConfig 读到关闭")
local prog_off = Spoiler.readProgress(fakeUI(fakeToc(), 35, 120), Spoiler.currentConfig())
eq(prog_off.enabled, false, "关闭态 prog 生效")
local res_off, err_off, cut_off = runPipeline(prog_off, "请解释这段写法的用意",
    { kind = "chat", history = history })
ok(res_off ~= nil, "关闭态管道跑通", err_off)
local p4 = bodyText()
ok(has(p4, LEAK7), "关闭时第 7 章原文原样进入 payload（反证上一条裁剪确实由开关触发）")
ok(has(p4, LEAK8), "关闭时第 8 章历史原样进入 payload")
ok(cut_off.truncated == false, "关闭时上下文窗口不截断")
ok(hasNot(p4, "防剧透约束"), "关闭时不注入防剧透 system 说明")
ok(hasNot(p4, "我只读到"), "关闭时不注入 user 侧进度提醒")
eq(res_off.spoiler_hit, false, "关闭时回答不被替换")
eq(res_off.content, next_reply_content, "关闭时回答原样返回")
setGuard(true, "chapter")

section("5. 降级用例：拿不到进度时不阻塞、不报错")
local prog_pdf = Spoiler.readProgress(fakeUI({}, 35, 120), Spoiler.currentConfig())
eq(prog_pdf.toc, nil, "PDF/无 TOC：toc 为 nil")
eq(prog_pdf.chapter_index, nil, "PDF/无 TOC：拿不到章节号")
ok(type(prog_pdf.percent) == "number" and prog_pdf.percent > 0, "PDF/无 TOC：百分比仍可用", prog_pdf.percent)
local res_pdf, err_pdf = runPipeline(prog_pdf, "这句话什么意思", { kind = "explain" })
ok(res_pdf ~= nil, "PDF/无 TOC 场景不报错、能正常提问", err_pdf)
ok(has(bodyText(), KEEP_SELECTED), "PDF/无 TOC 时上下文正常送达")
ok(has(bodyText(), "全书"), "PDF/无 TOC 时按百分比如实声明进度")
ok(hasNot(bodyText(), "读到第"), "PDF/无 TOC 时不虚称读到第几章")
-- 原 GAP-A：无目录时只有百分比、不裁剪（仅靠 prompt 约束）
-- P1 修复后：无目录自动回落百分比粒度，后文真的被剪短
ok(hasNot(bodyText(), LEAK7), "P1 修复：无目录自动回落百分比后，未读章节原文不再进入 payload")

local prog_none = Spoiler.withConfig(nil, Spoiler.currentConfig())
local res_none, err_none = runPipeline(prog_none, "这句话什么意思", { kind = "explain" })
ok(res_none ~= nil, "完全无进度时不报错、能正常提问", err_none)
ok(has(bodyText(), LEAK7), "GAP-B 无 progress 时第 7 章原文未被裁剪（main.lua 解释/摘要入口现状）")
ok(has(bodyText(), "防剧透约束"), "无进度时仍注入通用约束（靠 prompt 兜底）")
eq(res_none.spoiler_hit, false, "无进度时回答侧不拦截")
ok(has(res_none.content, "第九章"), "无进度时未读章节号原样出现在用户可见回答里")
eq(Spoiler.evaluate({ enabled = true }, prog_none, "凶手是谁"), false, "完全无进度时不本地硬拦（不阻塞）")

local prog_bad = Spoiler.readProgress({
    document = {
        getPageCount = function() error("boom") end,
        getCurrentPage = function() error("boom") end,
        getToc = function() error("boom") end,
    },
}, Spoiler.currentConfig())
eq(prog_bad.ok, false, "接口抛错被 pcall 兜住，不抛到上层")
eq(Spoiler.readProgress(nil).ok, false, "nil ui 安全")
eq(Spoiler.readProgress("x").ok, false, "非 table ui 安全")

section("6. 缓存命中路径仍过 sanitizeAnswer")
Cache:init()
Cache:clear()
local ckey = Cache:keyFor("verify_fp", KEEP_SELECTED .. "|问句", "explain", "deepseek-chat")
local cached_spoiler = "这段伏笔在第十章回收，凶手是老管家。"
Cache:set(ckey, cached_spoiler)
local cached = Cache:get(ckey)
eq(cached, cached_spoiler, "缓存写入并可读取")
local safe1, was1 = Spoiler.sanitizeAnswer(cached, prog)
eq(was1, true, "缓存里的剧透内容出库即被预警")
eq(safe1, Spoiler.WARNING, "缓存内容被替换为模糊提示")
local _, was2 = Spoiler.sanitizeAnswer(cached, prog_off)
eq(was2, false, "关闭时缓存内容原样出库")
Cache:clear()
local asker_src = readFile(PLUGIN_DIR .. "/ui/asker.lua")
ok(asker_src ~= nil and asker_src:find("sanitizeAnswer", 1, true) ~= nil,
    "ui/asker.lua 里存在缓存分支 sanitizeAnswer 调用")
ok(asker_src ~= nil and asker_src:find("truncateWindow", 1, true) ~= nil,
    "ui/asker.lua 里存在窗口截断调用")

section("7. 本地硬拦：问结局 / 凶手")
local bb, nn, rr = Spoiler.evaluate({ enabled = true }, prog, "凶手是谁")
eq(bb, true, "读到第 3 章时问凶手被本地拦下（省一次 API 调用）")
eq(rr, Spoiler.REFUSAL, "返回标准模糊话术")
ok(has(nn, "第 3 / 10 章"), "同时产出进度感知 prompt", nn)
eq(Spoiler.evaluate({ enabled = true }, prog, "这句话什么意思"), false, "正常提问不拦")
eq(Spoiler.evaluate({ enabled = false }, prog, "凶手是谁"), false, "关闭时不拦")
eq(Spoiler.evaluate({ enabled = true }, prog, nil), false, "无提问内容时不拦")

section("8. 边界：章节定位")
local toc10 = fakeToc()
eq((Spoiler.locateChapter(toc10, 30)), 3, "截断点恰好落在章节起点（第 3 章，page=30）")
eq((Spoiler.locateChapter(toc10, 29)), 2, "跨章前一页归上一章")
eq((Spoiler.locateChapter(toc10, 999)), 10, "超出最后一章归最后一章")
eq((Spoiler.locateChapter({}, 5)), nil, "空目录安全")
eq((Spoiler.locateChapter(toc10, "x")), nil, "非法页码安全")
eq((Spoiler.locateChapter(toc10, 5)), nil, "GAP-C 页码早于首个目录条目时返回 nil（现状）")
local prog_head = Spoiler.readProgress(fakeUI(toc10, 5, 120), Spoiler.currentConfig())
-- 原 GAP-C：书开头零防护（没有任何未读标题，全程不截断）
-- P1 修复后：chapter_index=0 表示"还没进第 1 章"，全部章节标题都算未读
eq(prog_head.chapter_index, 0, "P1 修复：书开头标记为「还没进第 1 章」（原为 nil）")
eq(#(prog_head.unread_titles or {}), 10, "P1 修复：书开头时全部 10 章标题都算未读（原为 0）")
local th, ih = Spoiler.truncate(LEAK7 .. "（第 7 章原文）", prog_head)
eq(ih.truncated, true, "P1 修复：书开头对未读章节同样截断（原为 false）")
eq(th, "", "P1 修复：未读章节原文零残留（原样通过的情况已修）")

section("9. 边界：单章书籍 / 最后一章 / 乱序页码")
local one = { { title = "序 开场白", page = 1, depth = 0 } }
local prog_one = Spoiler.readProgress(fakeUI(one, 5, 20), Spoiler.currentConfig())
eq(prog_one.chapter_index, 1, "单章书籍定位到第 1 章")
eq(#prog_one.unread_titles, 0, "单章书籍无未读标题")
local t_one, i_one = Spoiler.truncate(KEEP_AFTER .. "\n后续未读内容。", prog_one)
eq(i_one.truncated, false, "单章书籍不做截断（无未读章节可防）")

local prog_last = Spoiler.readProgress(fakeUI(toc10, 100, 120), Spoiler.currentConfig())
eq(prog_last.chapter_index, 10, "最后一章定位正确")
eq(#prog_last.unread_titles, 0, "最后一章无未读标题")
local t_last, i_last = Spoiler.truncate("任意后文内容。", prog_last)
eq(i_last.truncated, false, "读到最后一章时不再截断")
eq(Spoiler.evaluate({ enabled = true }, prog_last, "结局怎么样"), false, "读到最后一章不拦提问")

-- KOReader crengine 会给出非单调的目录页码，必须全表扫描取最大值
local messy = {
    { title = "甲 后置书签", page = 90, depth = 0 },
    { title = "乙 前压异常", page = 10, depth = 0 },
    { title = "丙 真正章节", page = 20, depth = 0 },
    { title = "丁 更后章节", page = 60, depth = 0 },
}
local m_idx, m_entry = Spoiler.locateChapter(messy, 25)
eq(m_idx, 3, "乱序页码：取「页码 ≤ 当前页」中页码最大者（第 3 条，page=20）")
eq(m_entry.title, "丙 真正章节", "乱序页码：定位到的标题正确")
local m_prog = Spoiler.readProgress(fakeUI(messy, 25, 120), Spoiler.currentConfig())
eq(m_prog.chapter, "丙 真正章节", "乱序页码：readProgress 取到正确章节名")
eq(m_prog.chapter_total, 4, "乱序页码：总章节数正确")
eq(#m_prog.unread_titles, 1, "乱序页码：未读标题只剩「丁 更后章节」")

section("10. 边界：截断位置与 UTF-8 安全")
local tb, ib = Spoiler.truncate("第八章未读段从这里开始。", prog)
eq(tb, "", "未读标记在开头 → 整段截空")
eq(ib.truncated, true, "开头命中也标记截断")
local te, ie = Spoiler.truncate(KEEP_AFTER .. "\n第九章后面的事。", prog)
eq(te, KEEP_AFTER .. "\n", "未读标记在结尾 → 保留前文")
eq(ie.truncated, true, "结尾命中也标记截断")
eq(Util.utf8len(tb), 0, "截空结果是空串（非半个汉字）")
eq(Util.utf8len(te), Util.utf8len(KEEP_AFTER) + 1, "结尾截断结果字符数正确", Util.utf8len(te))
-- 设计意图：句中间的同名词不当-preview截点（避免把「这个故事的结局很精彩」砍成半句）
local tw, iw = Spoiler.truncate("上一句的结局还没到终章，别急。", prog)
eq(iw.truncated, false, "连续正文里的同名词不算章节标记（不误伤）")
eq(tw, "上一句的结局还没到终章，别急。", "不误伤时原样返回")
-- 句号后紧跟未读章节标题 → 必须截断
local tz, iz = Spoiler.truncate("这里铺垫了一下。第七章 密语\n后面全是未读内容。", prog)
eq(iz.truncated, true, "句号后的未读章节标题被识别")
ok(hasNot(tz, "第七章"), "第七章字样不出现在截断结果里")
ok(hasNot(tz, "后面全是未读内容"), "其后正文一并被剪掉")
-- GAP-D：标题夹在句子中间（前一字是普通汉字）时不截断，未读原文残留
-- 原 GAP-D：标题夹在句中（前一字是普通汉字）时整句放行，未读原文残留
-- P2-1 修复后：「第X章」这类自带序号的标题放宽边界要求，句中也认
local td, id = Spoiler.truncate("此处过渡到第七章。后面全是未读内容。", prog)
eq(id.truncated, true, "P2-1 修复：行内出现「第X章」型标题不再整句放行（原为 false）")
ok(hasNot(td, "后面全是未读内容"), "P2-1 修复：未读原文及标题本体零残留（原实测泄漏）")

section("11. GAP-E：用户提问里引用未读章节标题时，问题文本会被一并剪掉")
local q_in_risk = { role = "user", content = "请问「" .. LEAK7 .. "」这段暗语是什么意思？" }
local gq, gi = Spoiler.guardMessages({ q_in_risk }, prog)
eq(gi.hits, 1, "含未读标题的用户提问被截断")
ok(hasNot(gq[1].content, LEAK7), "提问里的未读章节标题被剪掉（方向上是对的）")
ok(has(gq[1].content, "请问"), "但发出的 prompt 只剩半句话（可用性损失）")

section("12. 百分比粒度：不切碎用户问题与选中内容")
setGuard(true, "percent")
local prog_pct = Spoiler.readProgress(fakeUI(fakeToc(), 35, 120), Spoiler.currentConfig())
eq(prog_pct.granularity, "percent", "切到百分比粒度")
ok(type(prog_pct.percent) == "number", "百分比可用", prog_pct.percent)
local msgs_pct = {
    { role = "user", content = "我问两个层次的问题，请分别回答，不要合并。" },
    { role = "user", content = LEAK8 .. "这段是未读原文。" },
}
local gp, gi_pct = Spoiler.guardMessages(msgs_pct, prog_pct)
eq(gp[1].content, msgs_pct[1].content, "百分比粒度下用户问题不被比例切碎")
ok(hasNot(gp[2].content, LEAK8), "百分比粒度下仍精确剪掉未读章节")
eq(gi_pct.hits, 1, "命中 1 条")
local win_pct = { before = KEEP_BEFORE, selected = KEEP_SELECTED, after = string.rep("字", 200) }
local wp, wi = Spoiler.truncateWindow(win_pct, prog_pct)
eq(wp.before, KEEP_BEFORE, "百分比粒度下前文原样保留")
eq(wp.selected, KEEP_SELECTED, "百分比粒度下选中内容原样保留")
ok(wi.truncated == true, "百分比粒度下后文被按比例截断", wi.reason)
ok(Util.utf8len(wp.after) < 200, "后文确实变短", Util.utf8len(wp.after))
setGuard(true, "chapter")

section("13. GAP-F：withConfig 里 cfg 无条件覆盖 prog")
local merged = Spoiler.withConfig({ enabled = false, granularity = "percent" },
    { enabled = true, granularity = "chapter" })
eq(merged.enabled, true, "prog.enabled=false 被 cfg 覆盖成 true（现状）")
eq(merged.granularity, "chapter", "prog.granularity=percent 被 cfg 覆盖（现状）")

section("14. 分层与无旁路静态审查")
local ywbf_files = { "cache", "config", "context", "crypto", "deepseek", "httpclient",
                     "prompts", "queue", "spoiler", "store", "tokens", "util" }
local ui_leak, y_checked = 0, 0
for _, name in ipairs(ywbf_files) do
    local src = readFile(PLUGIN_DIR .. "/ywbf/" .. name .. ".lua")
    if src then
        y_checked = y_checked + 1
        if src:find('require("ui/', 1, true) or src:find("require('ui/", 1, true) then
            ui_leak = ui_leak + 1
            print("        [分层破坏] ywbf/" .. name .. ".lua")
        end
    end
end
eq(y_checked, #ywbf_files, "静态审查：ywbf/ 12 个文件全部被真实读取（避免空断言）")
eq(ui_leak, 0, "ywbf/ 层无任何 KOReader UI 依赖")

local ui_files = { "asker", "chatdialog", "settings", "toastcard" }
local direct_post, u_checked = 0, 0
for _, name in ipairs(ui_files) do
    local src = readFile(PLUGIN_DIR .. "/ui/" .. name .. ".lua")
    if src then
        u_checked = u_checked + 1
        if src:find("HttpClient", 1, true) then
            direct_post = direct_post + 1
            print("        [旁路] ui/" .. name .. ".lua")
        end
    end
end
eq(u_checked, #ui_files, "静态审查：ui/ 4 个文件全部被真实读取")
eq(direct_post, 0, "ui/ 层无 HttpClient 直连（不存在旁路）")

local ds_src = readFile(PLUGIN_DIR .. "/ywbf/deepseek.lua")
ok(ds_src ~= nil and ds_src:find("HttpClient.post", 1, true) ~= nil, "DeepSeek:chat 是唯一请求出口")
ok(ds_src ~= nil and ds_src:find("guardMessages", 1, true) ~= nil, "出口处有发出前截断")
ok(ds_src ~= nil and ds_src:find("sanitizeAnswer", 1, true) ~= nil, "出口处有回来后预警")
local http_src = readFile(PLUGIN_DIR .. "/ywbf/httpclient.lua")
ok(http_src ~= nil and http_src:find("isHostAllowed", 1, true) ~= nil, "HttpClient 保留域名白名单")

section("15. 所有提问入口是否都带上了阅读进度")
-- Asker:askSync 的防剧透输入完全来自 opts.progress；某入口漏传 →
-- 该入口的窗口截断 / 双保险 prompt / 本地硬拦 / 回答预警 全部空转。
local call_files = { "main.lua", "ui/toastcard.lua", "ui/chatdialog.lua", "ui/settings.lua" }
local missing = {}
for _, rel in ipairs(call_files) do
    local src = readFile(PLUGIN_DIR .. "/" .. rel)
    if src then
        src = src:gsub("\r\n", "\n")
        local lines = {}
        for line in ("\n" .. src):gmatch("\n([^\n]*)") do lines[#lines + 1] = line end
        for i, line in ipairs(lines) do
            if line:find("Asker:", 1, true) and (line:find("askAndShow", 1, true)
                or line:find("submitAsync", 1, true) or line:find("askSync", 1, true)) then
                local block, j = "", i
                while j <= #lines do
                    block = block .. lines[j] .. "\n"
                    if lines[j]:find("^%s*%}%)") then break end
                    j = j + 1
                end
                if not block:find("progress", 1, true) then
                    missing[#missing + 1] = string.format("%s:%d  %s",
                        rel, i, (lines[i]:gsub("^%s+", "")))
                end
            end
        end
    end
end
for _, m in ipairs(missing) do print("        [缺 progress] " .. m) end
eq(#missing, 0, "每个 Asker 调用点都传入了 progress（漏传 = 该入口防剧透整体失效）")

section("RESULTS")
print(string.format("TOTAL: %d  PASSED: %d  FAILED: %d", TOTAL, PASSED, FAILED))
if FAILED > 0 then
    print("")
    print("失败明细：")
    for _, m in ipairs(failures) do print("  - " .. m) end
end
logger.info(string.format("YWBF verify_spoiler: %d passed, %d failed", PASSED, FAILED))
