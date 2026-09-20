--[[--
设备端单元测试：用 KOReader 自带的 luajit 直接跑（与真机运行时完全一致）。

在 KPW4 上执行：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     ./luajit /mnt/us/koreader/plugins/YuanWangBookFriend.koplugin/../tests/run_tests.lua
（实际路径以插件目录为准，测试目录会被单独推送到 /mnt/us/ywbf_dev/tests）

覆盖：config / crypto / queue / tokens / httpclient 白名单
--]]--

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR") or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"

-- 行缓冲：否则失败时末尾的 os.exit(1) 会把还没刷新的 FAIL 行和 RESULTS 行一起吞掉，
-- 表现为"只看到一堆 PASS 然后 rc=1"，排查时非常误导。
io.stdout:setvbuf("line")

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

local Config = require("ywbf/config")
local Crypto = require("ywbf/crypto")
local Queue = require("ywbf/queue")
local Tokens = require("ywbf/tokens")
local HttpClient = require("ywbf/httpclient")
local Util = require("ywbf/util")
local Context = require("ywbf/context")
local Prompts = require("ywbf/prompts")
local Cache = require("ywbf/cache")
local Store = require("ywbf/store")
local Spoiler = require("ywbf/spoiler")

local passed, failed = 0, 0

local function ok(cond, name, extra)
    if cond then
        passed = passed + 1
        print("  PASS  " .. name)
    else
        failed = failed + 1
        print("  FAIL  " .. name .. (extra and ("  -> " .. tostring(extra)) or ""))
    end
end

local function eq(a, b, name)
    ok(a == b, name, string.format("got=%s want=%s", tostring(a), tostring(b)))
end

local TEST_DIR = os.getenv("YWBF_TEST_DIR") or "/mnt/us/ywbf_dev/testdata"

print("=== config ===")
Config:init(TEST_DIR)
ok(Config.paths.data == TEST_DIR .. "/data", "data 目录落在插件目录内", Config.paths.data)
eq(Config:get("model"), "deepseek-chat", "默认模型")
eq(Config:get("spoiler_guard"), true, "防剧透默认开启")
Config:set("model", "deepseek-reasoner")
eq(Config:get("model"), "deepseek-reasoner", "设置写入并持久化")
-- 重新加载验证落盘
Config.settings = nil
Config.settings = Config:load()
eq(Config:get("model"), "deepseek-reasoner", "重启后设置仍在")
Config:set("model", "deepseek-chat")
-- 先归零再统计：TEST_DIR 是持久目录，不归零的话重跑一次就会累加成 20
Config:set("usage", { requests = 0, prompt_tokens = 0, completion_tokens = 0 })
Config:addUsage(10, 20)
Config.settings = nil
Config.settings = Config:load()
eq(Config:get("usage").prompt_tokens, 10, "用量统计持久化")

print("=== crypto ===")
local cok, algo = Crypto:init()
ok(cok, "crypto 初始化", algo)
print("  (算法: " .. tostring(algo) .. ")")
local plain = "sk-REPLACE_WITH_YOUR_DEEPSEEK_KEY"
local blob = Crypto:encrypt(plain)
ok(type(blob) == "string" and #blob > 0, "加密产出非空")
ok(blob and not blob:find(plain, 1, true), "密文中不含明文 Key")
local back, derr = Crypto:decrypt(blob)
eq(back, plain, "加解密往返一致", derr)
local long = string.rep("A", 100)
eq(Crypto:decrypt(Crypto:encrypt(long)), long, "长文本（跨块）往返一致")
local bad, berr = Crypto:decrypt("not-a-blob")
ok(bad == nil, "非法密文返回 nil", berr)

print("=== tokens ===")
ok(Tokens.estimate("你好世界") > 0, "token 估算 > 0")
ok(Tokens.estimate("") == 0, "空串估算为 0")
ok(Tokens.estimate(string.rep("字", 100)) > Tokens.estimate("字"), "估算随长度递增")
ok(Tokens.estimateMessages({ { role = "user", content = "你好" } }) > 0, "消息估算 > 0")
ok(type(Tokens.formatUsage()) == "string", "用量格式化输出")

print("=== httpclient 白名单 ===")
ok(HttpClient.isHostAllowed("https://api.deepseek.com/chat/completions"), "放行 api.deepseek.com")
ok(not HttpClient.isHostAllowed("https://evil.example.com/x"), "拦截其它域名")
ok(not HttpClient.isHostAllowed("http://api.deepseek.com.evil.com/"), "拦截伪装域名")

print("=== queue ===")
local q = Queue:init({})
local order = {}
q:submit({ name = "a", fn = function() table.insert(order, "a") ; return "ok" end })
q:submit({ name = "b", fn = function() table.insert(order, "b") ; return "ok" end })
q:process()
eq(table.concat(order, ","), "a,b", "串行顺序执行")

local q2 = Queue:init({})
local attempts = 0
local err_msg = nil
q2:submit({
    name = "flaky",
    retries = 1,
    fn = function()
        attempts = attempts + 1
        if attempts < 2 then return nil, "boom" end
        return "recovered"
    end,
    on_error = function(e) err_msg = e end,
})
q2:process()
eq(attempts, 2, "失败后重试一次")
ok(err_msg == nil, "重试成功后不触发 on_error", err_msg)

local q3 = Queue:init({})
local got_err = nil
q3:submit({
    name = "always_fail",
    retries = 1,
    fn = function() return nil, "always" end,
    on_error = function(e) got_err = e end,
})
q3:process()
eq(got_err, "always", "重试耗尽后回调错误")

print("=== util ===")
eq(Util.md5("abc"), Util.md5("abc"), "md5 稳定")
ok(Util.md5("abc") ~= Util.md5("abd"), "md5 区分不同输入")
eq(#Util.bookFingerprint("/a/b.epub", 123, 456), 16, "书籍指纹长度 16")
ok(Util.bookFingerprint("/a/b.epub", 1, 1) ~= Util.bookFingerprint("/a/b.epub", 2, 1), "指纹随文件大小变化")
eq(Util.trim("  hi  "), "hi", "trim")
eq(Util.clamp(5, 1, 3), 3, "clamp 上限")
eq(Util.clamp(-5, 1, 3), 1, "clamp 下限")
eq(Util.collapseWhitespace("a\n  b\t c"), "a b c", "折叠空白")
ok(Util.isEmpty("  "), "空白视为空")

print("=== util UTF-8 ===")
-- 中文 3 字节：按字节 sub 会切出半个汉字（墨水屏上就是乱码方块）
local cn = "我们要有一小块地种苜蓿"
eq(Util.utf8len(cn), 11, "中文字符数按字算而非字节")
eq(#cn, 33, "同一串的字节数是 33")
eq(Util.utf8sub(cn, 5), "我们要有一", "按字符边界截取 5 个字")
eq(Util.utf8len(Util.utf8sub(cn, 5)), 5, "截取结果仍是 5 个合法字符")
ok(Util.utf8sub(cn, 5) ~= cn:sub(1, 5), "字节截断与字符截断结果不同（正是乱码来源）")
-- 中英混排
local mixed = "abc我们要def"
eq(Util.utf8sub(mixed, 6), "abc我们要", "中英混排按字符截取")
eq(Util.utf8len(Util.utf8sub(mixed, 6)), 6, "混排截取长度正确")
-- 截断位置落在多字节中间时，必须丢弃不完整的尾字节
eq(Util.utf8len(Util.utf8sub("一二三四五", 3)), 3, "截断不产生半个字符")
-- 4 字节字符（emoji）
local emoji = "😀😁一二三"
eq(Util.utf8len(emoji), 5, "emoji 计为单个字符")
eq(Util.utf8sub(emoji, 2), "😀😁", "emoji 按字符截取")
-- 净化不可见字符
ok(Util.sanitizeForDisplay("a\194\173b") == "ab", "去掉软连字符 U+00AD")
ok(Util.sanitizeForDisplay("a\226\128\139b") == "ab", "去掉零宽空格 U+200B")
ok(Util.sanitizeForDisplay("a\194\160b") == "a b", "不换行空格转普通空格")
-- preview：截断 + 字数统计都按字符
local p_txt, p_total, p_cut = Util.preview(string.rep("字", 150), 100)
eq(p_total, 150, "preview 字数按字符统计")
ok(p_cut == true, "preview 标记已截断")
eq(Util.utf8len(p_txt), 100, "preview 截断到 100 个字符")

print("=== context ===")
local book = "第一章 开头。\n" .. string.rep("前文内容。", 100) .. "\n选中这句话。\n" .. string.rep("后文内容。", 100)
local sel_s = book:find("选中这句话。", 1, true)
local sel_e = sel_s + #("选中这句话。") - 1
local win = Context.window(book, sel_s, sel_e, 800)
eq(win.selected, "选中这句话。", "窗口保留选中内容")
ok(#win.before > 0 and #win.before <= 800 + 200, "前文长度受控", #win.before)
ok(#win.after > 0 and #win.after <= 800 + 200, "后文长度受控", #win.after)
eq(Context.window("", 1, 1).selected, "", "空文本安全")
eq(Context.window(book, 1, 1, 800).before, "", "开头无前文")
local small = Context.window(book, sel_s, sel_e, 10)  -- 会被夹到 MIN_RADIUS=400
ok(#small.before <= 400 + 200, "radius 下限收敛", #small.before)
local long = string.rep("字", 5000)
-- truncate 按字符截断（1000 个汉字 = 3000 字节），断言必须按字符数
ok(Util.utf8len(Context.truncate(long, 1000)) <= 1000, "超长文本被截断到 1000 字符")
ok(Util.utf8len(Context.truncate(long, 1000)) == 1000, "截断后正好是 1000 个合法字符")
ok(Context.truncate("短句", 100) == "短句", "短文本不截断")
ok(Context.buildPayload("前", "中", "后"):find("【选中内容】", 1, true) ~= nil, "payload 含选中标记")

print("=== context.fromSelection ===")
local page = "这是第一段。\n" .. string.rep("前文句子。", 60) .. "\n关键的一句。\n" .. string.rep("后文句子。", 60)
local w1 = Context.fromSelection(page, "关键的一句。", 800)
eq(w1.selected, "关键的一句。", "精确匹配保留选中")
ok(#w1.before > 0, "精确匹配取到前文", #w1.before)
ok(#w1.after > 0, "精确匹配取到后文", #w1.after)
-- 空白差异场景（EPUB 常见）：选中文本带换行
local w2 = Context.fromSelection("前前前。\n关键 的 一句。\n后后后。", "关键\n的\n一句。", 800)
eq(w2.selected, "关键 的 一句。", "折叠空白后仍能匹配")
local w3 = Context.fromSelection(page, "书中根本不存在的话", 800)
eq(w3.before, "", "匹配不到时前文为空")
eq(w3.selected, "书中根本不存在的话", "匹配不到时保留选中内容")
eq(Context.fromSelection(nil, "x", 800).selected, "x", "无页文本时安全")

print("=== prompts ===")
local msgs = Prompts.build("explain", { context = "【选中内容】\n贾宝玉" })
ok(#msgs >= 2, "消息至少 system + user")
eq(msgs[1].role, "system", "首条为 system")
ok(msgs[#msgs].content:find("贾宝玉", 1, true) ~= nil, "user 消息含上下文")
ok(msgs[#msgs].content:find("200", 1, true) ~= nil, "释义带 200 字约束")
local chat = Prompts.build("chat", { question = "他后来怎样？", history = { { role = "user", content = "上一轮" } } })
eq(#chat, 3, "多轮对话含历史")
eq(chat[2].content, "上一轮", "历史消息保留")
ok(Prompts.build("summary", { context = "x" })[1].content:find("远望书友", 1, true) ~= nil, "system 含角色设定")

print("=== cache ===")
Cache:init()
local k1 = Cache:keyFor("fp123", "黛玉葬花", "explain", "deepseek-chat")
eq(k1, Cache:keyFor("fp123", "黛玉葬花", "explain", "deepseek-chat"), "缓存键稳定")
ok(k1 ~= Cache:keyFor("fp123", "黛玉葬花", "summary", "deepseek-chat"), "不同功能键不同")
ok(k1 ~= Cache:keyFor("fp999", "黛玉葬花", "explain", "deepseek-chat"), "不同书籍键不同")
ok(Cache:get(k1) == nil, "未命中返回 nil")
Cache:set(k1, "解释内容")
eq(Cache:get(k1), "解释内容", "写入后可读取")
Cache:set(k1, "解释内容2")
eq(Cache:get(k1), "解释内容2", "覆盖写入")
-- 容量淘汰
local old_max = Config:get("cache_max_bytes")
Config:set("cache_max_bytes", 200)
for i = 1, 30 do Cache:set("k" .. i, string.rep("x", 50)) end
ok(Cache:totalBytes() <= 200 + 100, "超出容量后触发淘汰", Cache:totalBytes())
ok(Cache:count() < 35, "淘汰后条目减少", Cache:count())
Config:set("cache_max_bytes", old_max)
Cache:clear()
eq(Cache:count(), 0, "清空缓存")

print("=== store ===")
local fp = "testbook0001"
Store:clear(fp)
Store:append(fp, { role = "user", content = "宝玉是谁", kind = "chat", selection = "宝玉" })
Store:append(fp, { role = "assistant", content = "贾宝玉是主角", kind = "chat" })
local list = Store:list(fp)
eq(#list, 2, "历史追加两条")
eq(list[1].content, "宝玉是谁", "顺序保留")
local hits = Store:search("贾宝玉")
ok(#hits >= 1, "可搜索到内容", #hits)
ok(#Store:search("绝无此内容xyz") == 0, "无匹配返回空")
Store:delete(fp, { 1 })
eq(#Store:list(fp), 1, "删除一条后剩一条")
eq(Store:list(fp)[1].content, "贾宝玉是主角", "删除的是第一条")
Store:clear(fp)
eq(#Store:list(fp), 0, "清空历史")

-- ================= 防剧透（M3，PRD F4.1–F4.5） =================

local TOC = {
    { title = "第一章 开场", page = 1,  depth = 1 },
    { title = "第二章 相遇", page = 10, depth = 1 },
    { title = "相遇（二）",  page = 12, depth = 2 },
    { title = "第三章 转折", page = 20, depth = 1 },
    { title = "第四章 结局", page = 30, depth = 1 },
}
-- 进度适配层用：页码跨度与「共 200 页」配套，才能同时验到百分比和章节号
local TOC2 = {
    { title = "第一章 开场", page = 1,   depth = 1 },
    { title = "第二章 相遇", page = 50,  depth = 1 },
    { title = "相遇（二）",  page = 60,  depth = 2 },
    { title = "第三章 转折", page = 120, depth = 1 },
    { title = "第四章 结局", page = 180, depth = 1 },
}

print("=== spoiler: 进度换算 ===")
eq(Spoiler.percent(50, 200), 25, "百分比换算")
eq(Spoiler.percent(0, 200), 0, "起点为 0%")
eq(Spoiler.percent(300, 200), 100, "超出收敛到 100%")
ok(Spoiler.percent(nil, 200) == nil, "缺页码返回 nil")
ok(Spoiler.percent(50, 0) == nil, "总页为 0 返回 nil")
ok(Spoiler.percent(50, nil) == nil, "类型不对返回 nil")
ok(Spoiler.isReadByPercent(50, 52) == true, "容差内算已读")
ok(Spoiler.isReadByPercent(50, 80) == false, "明显靠后算未读")
ok(Spoiler.isReadByPercent(nil, 80) == true, "进度未知时放行（不阻塞）")

print("=== spoiler: 目录定位 ===")
local li1, le1 = Spoiler.locateChapter(TOC, 10)
eq(li1, 2, "截断点恰好落在章节起点")
eq(le1.title, "第二章 相遇", "定位到第二章")
eq((Spoiler.locateChapter(TOC, 9)), 1, "跨章前一章")
eq((Spoiler.locateChapter(TOC, 12)), 3, "小节归到自己那一节")
eq((Spoiler.locateChapter(TOC, 12, true)), 2, "whole_chapter 归到一级章节")
eq((Spoiler.locateChapter(TOC, 0)), nil, "开头之前无章节")
eq((Spoiler.locateChapter(TOC, 999)), 5, "结尾定位到最后一章")
eq((Spoiler.locateChapter({}, 5)), nil, "空目录安全")
eq((Spoiler.locateChapter(TOC, "x")), nil, "非法页码安全")

local ci1 = Spoiler.chapterInfo(TOC, 12)
eq(ci1.index, 2, "第 2 章（小节归一级）")
eq(ci1.total, 4, "共 4 章")
eq(ci1.title, "第二章 相遇", "章节名")
local ci2 = Spoiler.chapterInfo(TOC, 25)
eq(ci2.index, 3, "第 3 章")
local ci3 = Spoiler.chapterInfo(TOC, 1)
eq(ci3.index, 1, "开头是第 1 章")
-- 修复 P1-1：页码早于首个目录条目时，low-level locateChapter 仍返回 nil，
-- 但 readProgress 要把"所有章节都还没读到"这件事表达出来（见下一段断言）
eq(Spoiler.chapterInfo(TOC, 0).index, nil, "页码早于首条目时 low-level 返回 nil")
local ci4 = Spoiler.chapterInfo(TOC, 999)
eq(ci4.index, 4, "结尾是最后一章")
eq(Spoiler.chapterInfo(nil, 5).index, nil, "无目录安全")

local ut2 = Spoiler.unreadTitles(TOC, 2)
eq(#ut2, 2, "第 2 章之后还有 2 个未读标题")
eq(ut2[1], "第三章 转折", "未读标题 1")
eq(ut2[2], "第四章 结局", "未读标题 2")
eq(#Spoiler.unreadTitles(TOC, 4), 0, "最后一章无未读标题")
ok(Spoiler.isUsableTitle("一") == false, "单字标题被筛掉")
ok(Spoiler.isUsableTitle("12") == false, "纯数字标题被筛掉")
ok(Spoiler.isUsableTitle("雪夜奔袭") == true, "正常标题保留")

print("=== spoiler: 进度读取适配层 ===")
local function fakeRollingUI()
    return {
        document = {
            info = { has_pages = false, number_of_pages = 200 },
            getPageCount   = function() return 200 end,
            getCurrentPage = function() return 60 end,
            getXPointer    = function() return "/body/DocFragment[6]/body/p[3]" end,
            getToc         = function() return TOC2 end,
        },
    }
end
local pr1 = Spoiler.readProgress(fakeRollingUI(), { enabled = true, granularity = "chapter" })
eq(pr1.percent, 30, "EPUB：60/200 = 30%")
eq(pr1.page, 60, "EPUB 当前页")
eq(pr1.total, 200, "EPUB 总页")
eq(pr1.source, "rolling", "EPUB 走 rolling 通道")
eq(pr1.chapter_index, 2, "EPUB 定位到第 2 章")
eq(pr1.chapter_total, 4, "EPUB 共 4 章")
eq(pr1.chapter, "第二章 相遇", "EPUB 章节名")
eq(#pr1.unread_titles, 2, "EPUB 未读标题数")
ok(pr1.xpointer ~= nil, "EPUB 拿到 xpointer")
ok(pr1.ok == true, "EPUB 进度可用")
ok(pr1.has_pages == false, "EPUB 非分页文档")

local pr2 = Spoiler.readProgress({
    paging = { current_page = 5 },
    document = {
        info = { has_pages = true },
        getPageCount = function() return 10 end,
        getToc = function() return TOC end,
    },
}, { enabled = true })
eq(pr2.percent, 50, "PDF：5/10 = 50%")
eq(pr2.source, "paging", "PDF 走 paging 通道")
eq(pr2.chapter_index, 1, "PDF 定位到第 1 章")
ok(pr2.has_pages == true, "PDF 是分页文档")

local pr3 = Spoiler.readProgress({ document = {} })
ok(pr3.percent == nil, "空文档拿不到百分比")
ok(pr3.chapter_index == nil, "空文档拿不到章节")
ok(pr3.ok == false, "空文档进度不可用（退化，不阻塞）")
local pr4 = Spoiler.readProgress({
    document = {
        getPageCount   = function() error("boom") end,
        getCurrentPage = function() error("boom") end,
        getToc         = function() error("boom") end,
    },
})
ok(pr4.ok == false, "接口抛错被 pcall 兜住")
ok(pr4.percent == nil, "抛错后百分比为 nil")
ok(Spoiler.readProgress(nil).ok == false, "nil ui 安全")
ok(Spoiler.readProgress("x").ok == false, "非 table ui 安全")
eq(Spoiler.readProgress(fakeRollingUI(), { enabled = false }).enabled, false, "cfg 可关闭")
eq(Spoiler.readProgress(fakeRollingUI(), { granularity = "percent" }).granularity, "percent", "cfg 可切粒度")
ok(Spoiler.progressLabel(pr1):find("第 2 / 4 章", 1, true) ~= nil, "进度描述含章节")
ok(Spoiler.progressLabel(pr3):find("未识别", 1, true) ~= nil, "无进度时的描述")

-- 注意：以下各段用 do...end 包起来。Lua 单函数局部变量上限 200，
-- 断言一多就必须靠作用域回收槽位，否则 luajit 直接拒绝加载整个测试文件。
do
-- ---- P1-1：书开头（页码早于首个目录条目）不能再是零防护 ----
local HEAD_TOC = {   -- 首章在第 30 页，当前停在第 5 页（封面/序）
    { title = "第一章 开场", page = 30,  depth = 1 },
    { title = "第二章 相遇", page = 60,  depth = 1 },
    { title = "第三章 转折", page = 90,  depth = 1 },
    { title = "第四章 结局", page = 120, depth = 1 },
}
local pr_head = Spoiler.readProgress({
    document = {
        info = { has_pages = false, number_of_pages = 120 },
        getPageCount   = function() return 120 end,
        getCurrentPage = function() return 5 end,
        getToc         = function() return HEAD_TOC end,
    },
}, { enabled = true })
eq(pr_head.chapter_index, 0, "书开头：chapter_index=0（还没进第 1 章）")
eq(pr_head.chapter_total, 4, "书开头：总章节数仍识别出来")
eq(#(pr_head.unread_titles or {}), 4, "书开头：全部 4 章标题都算未读")
ok(Spoiler.progressLabel(pr_head):find("第 0", 1, true) == nil, "书开头不显示「第 0 / 4 章」")
ok(Spoiler.progressLabel(pr_head):find("4%", 1, true) ~= nil, "书开头改报百分比", Spoiler.progressLabel(pr_head))
local th1, ih1 = Spoiler.truncate("封面和序言。\n第三章 转折\n未读原文一大段。", pr_head)
eq(ih1.truncated, true, "书开头：后文出现未读章节标题时被截断")
ok(th1:find("未读原文", 1, true) == nil, "书开头：未读正文零残留")
eq(th1, "封面和序言。\n", "书开头：截断点落在章节标题前")
local th2, ih2 = Spoiler.truncate("只在前言里的一段话。", pr_head)
eq(ih2.truncated, false, "书开头：章内文本仍不误伤")
eq(Spoiler.evaluate({ enabled = true }, pr_head, "凶手是谁"), true, "书开头问凶手被拦下")
eq(Spoiler.buildNote({ enabled = true, chapter_index = 0, chapter_total = 4, percent = 4 })
    :find("第 0 / 4 章", 1, true), nil, "buildNote 不输出「第 0 章」")
ok(Spoiler.buildNote({ enabled = true, chapter_index = 0, chapter_total = 4, percent = 4 })
    :find("4%", 1, true) ~= nil, "buildNote 在第 0 章时回落为百分比声明")

-- ---- P1-2：无目录（PDF 常见）自动回落到百分比粒度 ----
local pr_notoc = Spoiler.readProgress({
    paging = { current_page = 35 },
    document = {
        info = { has_pages = true },
        getPageCount = function() return 120 end,
        getToc = function() return {} end,
    },
}, { enabled = true, granularity = "chapter" })
eq(pr_notoc.toc, nil, "无目录：toc 为 nil")
eq(pr_notoc.percent, 35 / 120 * 100, "无目录：百分比可用")
eq(pr_notoc.granularity, "percent", "无目录：chapter 自动回落到 percent")
eq(pr_notoc.granularity_auto, true, "无目录：回落后打上 granularity_auto 标记")
local wn = { before = "前", selected = "中", after = string.rep("字", 200) }
local wn2, iwn = Spoiler.truncateWindow(wn, pr_notoc)
eq(iwn.truncated, true, "无目录：后文真的被剪短（不是只靠 prompt）")
ok(Util.utf8len(wn2.after) < 200, "无目录：后文长度确实变小", Util.utf8len(wn2.after))
eq(wn2.before, "前", "无目录回落：前文仍保留")
eq(wn2.selected, "中", "无目录回落：选中内容仍保留")
local mg = Spoiler.withConfig(pr_notoc, Spoiler.currentConfig())
eq(mg.granularity, "percent", "withConfig 不会把自动回落覆盖回 chapter")
-- P1-2 收紧：无目录时后文有绝对上限（百分比只是估算，不是隔离）
eq(Spoiler.AUTO_FALLBACK_MAX_CHARS, 120, "无目录时后文硬上限是 120 字")
local long_after = string.rep("字", 900)
local wl, iwl = Spoiler.truncateWindow(
    { before = "前", selected = "中", after = long_after }, pr_notoc)
eq(iwl.truncated, true, "无目录：超长后文被剪短")
ok(Util.utf8len(wl.after) <= Spoiler.AUTO_FALLBACK_MAX_CHARS,
    "无目录：后文长度被压到硬上限内", Util.utf8len(wl.after))
-- 有目录（正常粒度）时不受这条上限影响
local normal_prog = { enabled = true, granularity = "percent", percent = 100 }
local wn3, iwn3 = Spoiler.truncateWindow({ before = "", selected = "", after = long_after }, normal_prog)
eq(iwn3.truncated, false, "有目录/非回落时不受该上限影响（100% 不截断）")
-- 诚实登记：无目录时紧贴选中句之后的原文仍可能进 payload（粗粒度，非隔离）
local pr_hi = Spoiler.readProgress({
    paging = { current_page = 140 },
    document = { info = { has_pages = true }, getPageCount = function() return 150 end },
}, { enabled = true, granularity = "chapter" })
ok(pr_hi.percent > 90, "反例前置：当前进度 >90%", pr_hi.percent)
local short_after = "\n未读原文紧贴选中句ABCDEFG。"
local wh, iwh = Spoiler.truncateWindow({ before = "", selected = "选中", after = short_after }, pr_hi)
ok(type(wh.after) == "string" and wh.after:find("未读原文紧贴选中句", 1, true) ~= nil,
    "已知限制：无目录时紧贴选中句的未读原文仍会进 payload（粗粒度，非隔离）", wh.after)
local long_hi, ilong_hi = Spoiler.truncateWindow(
    { before = "", selected = "选中", after = short_after .. string.rep("字", 500) }, pr_hi)
eq(ilong_hi.truncated, true, "但长后文仍被压到上限内")
ok(Util.utf8len(long_hi.after) <= Spoiler.AUTO_FALLBACK_MAX_CHARS,
    "长后文压到硬上限", Util.utf8len(long_hi.after))

local pr_toc_ok = Spoiler.readProgress(fakeRollingUI(), { enabled = true, granularity = "chapter" })
eq(pr_toc_ok.granularity, "chapter", "有目录时不回落")
eq(pr_toc_ok.granularity_auto, nil, "有目录时不打自动回落标记")
end  -- P1 do-block

print("=== spoiler: 截断引擎（章节粒度） ===")
local prog_ch = {
    enabled = true, granularity = "chapter",
    chapter_index = 2, chapter_total = 4,
    unread_titles = { "第三章 转折", "第四章 结局" },
}
local t1, i1 = Spoiler.truncate("前文一句。\n第三章 转折\n他推开门。", prog_ch)
eq(i1.truncated, true, "命中章节标记即截断")
eq(i1.reason, "chapter", "截断原因是章节边界")
eq(t1, "前文一句。\n", "截断点恰好在章节边界")
ok(t1:find("第三章", 1, true) == nil, "未读章节标题不进 payload")
ok(t1:find("他推开门", 1, true) == nil, "标记后的正文也被剪掉")
local t2, i2 = Spoiler.truncate("只在当前章节里的一段话。", prog_ch)
eq(i2.truncated, false, "章内文本不截断")
eq(t2, "只在当前章节里的一段话。", "章内文本原样保留")
eq(i2.reason, "no_marker", "没有标记")
local t3, i3 = Spoiler.truncate("第三章 转折\n后面都没读。", prog_ch)
eq(t3, "", "标记在开头则整体截空")
eq(i3.truncated, true, "开头命中也标记截断")
local t4 = Spoiler.truncate("已读内容。\n第四章 结局", prog_ch)
eq(t4, "已读内容。\n", "标记在结尾则保留前文")
-- 误伤防护："结局" 前是「的」，不是边界，不能当标题
local t5, i5 = Spoiler.truncate("这个故事的结局很精彩。", { enabled = true, granularity = "chapter", unread_titles = { "结局" } })
eq(i5.truncated, false, "句中同名词不算章节标记（不误伤）")
eq(t5, "这个故事的结局很精彩。", "不误伤时原样返回")
local t6, i6 = Spoiler.truncate("任意文本", { enabled = false, unread_titles = { "第三章 转折" } })
eq(i6.truncated, false, "开关关闭时不截断")
eq(t6, "任意文本", "关闭时原样返回")
eq(i6.reason, "disabled", "关闭的原因标记")
local t7, i7 = Spoiler.truncate("", prog_ch)
eq(i7.reason, "empty", "空文本安全")
local t8 = Spoiler.truncate("第三章 转折", { enabled = true, granularity = "chapter" })
eq(t8, "第三章 转折", "没有目录时不截断（退化）")
local t9, i9 = Spoiler.truncate("第 3 章的内容\n第三章 转折", { enabled = true, granularity = "percent", percent = 30, unread_titles = { "第三章 转折" } }, { markers_only = true })
eq(i9.reason, "chapter", "markers_only 强制走章节标记（percent 粒度下也精确）")
eq(t9, "第 3 章的内容\n", "markers_only 截断结果")

print("=== spoiler: 截断引擎（百分比粒度） ===")
local pp50 = { enabled = true, granularity = "percent", percent = 50 }
local p1, pi1 = Spoiler.truncate(string.rep("字", 100), pp50)
eq(Util.utf8len(p1), 50, "50% 进度保留一半字符")
eq(pi1.truncated, true, "百分比截断生效")
eq(pi1.reason, "percent", "截断原因是百分比")
local p2, pi2 = Spoiler.truncate(string.rep("字", 100), { enabled = true, granularity = "percent", percent = 100 })
eq(pi2.truncated, false, "读到 100% 不再截断")
eq(Util.utf8len(p2), 100, "100% 时全文保留")
local p3, pi3 = Spoiler.truncate(string.rep("字", 10), { enabled = true, granularity = "percent", percent = 0 })
eq(p3, "", "0% 时截空")
eq(pi3.truncated, true, "0% 标记为已截断")
local p4, pi4 = Spoiler.truncate(string.rep("字", 10), { enabled = true, granularity = "percent" })
eq(pi4.truncated, false, "没有百分比数据时不截断")
eq(pi4.reason, "no_percent", "缺少百分比的原因")
-- 优先落在句子边界
local p5 = Spoiler.truncate(string.rep("甲", 20) .. "。" .. string.rep("乙", 20), pp50)
ok(Util.utf8len(p5) <= 50, "截断不超过预算")
ok(p5:sub(-3) == "。", "优先在句号处断开")
ok(Util.utf8len(p5) == 21, "落在句号而不是硬切")

print("=== spoiler: 上下文窗口截断 ===")
local win_in = { before = "前面已读。", selected = "选中句。", after = "后文一句。\n第三章 转折\n未读内容。" }
local w1, wi1 = Spoiler.truncateWindow(win_in, prog_ch)
eq(w1.before, "前面已读。", "前文原样保留（必然已读）")
eq(w1.selected, "选中句。", "选中内容原样保留")
ok(w1.after:find("第三章", 1, true) == nil, "后文跨章部分被剪掉")
ok(w1.after:find("后文一句", 1, true) ~= nil, "章内后文保留")
eq(wi1.truncated, true, "窗口截断生效")
local w2, wi2 = Spoiler.truncateWindow(win_in, { enabled = false })
eq(w2.after, win_in.after, "关闭时窗口原样")
eq(wi2.truncated, false, "关闭时窗口不截断")
local w3, wi3 = Spoiler.truncateWindow({ before = "前", selected = "中", after = "" }, prog_ch)
eq(wi3.reason, "empty", "空后文安全")
eq(w3.after, "", "空后文原样")
eq((Spoiler.truncateWindow(nil, prog_ch)), nil, "nil 窗口安全")

print("=== spoiler: guardMessages（多轮历史 / 用户粘贴） ===")
local msgs_in = {
    { role = "system", content = "系统提示" },
    { role = "user",   content = "上一轮我贴了：\n第三章 转折\n这什么意思" },
    { role = "user",   content = "正常问题" },
}
local g1, gi1 = Spoiler.guardMessages(msgs_in, prog_ch)
eq(#g1, 3, "消息条数不变")
eq(gi1.hits, 1, "命中 1 条")
eq(gi1.changed, true, "标记为已修改")
ok(g1[2].content:find("第三章", 1, true) == nil, "历史里的未读章节被剪掉")
ok(g1[2].content:find("上一轮我贴了", 1, true) ~= nil, "历史里已读部分保留")
eq(g1[3].content, "正常问题", "未命中的消息原样")
eq(g1[1].content, "系统提示", "system 消息原样")
-- percent 粒度下 guardMessages 只做精确标记，绝不按比例切碎用户问题
local g2, gi2 = Spoiler.guardMessages(msgs_in, {
    enabled = true, granularity = "percent", percent = 30,
    unread_titles = { "第三章 转折" },
})
eq(g2[3].content, "正常问题", "percent 粒度不切碎用户问题")
eq(gi2.hits, 1, "percent 粒度仍精确剪掉未读章节")
local g3, gi3 = Spoiler.guardMessages(msgs_in, { enabled = false, unread_titles = { "第三章 转折" } })
eq(gi3.hits, 0, "关闭时 guardMessages 直通")
eq(g3[2].content, msgs_in[2].content, "关闭时历史原样")

print("=== spoiler: 章节号解析 ===")
eq(Spoiler.parseChapterNumber("10"), 10, "阿拉伯数字")
eq(Spoiler.parseChapterNumber("一"), 1, "中文 一")
eq(Spoiler.parseChapterNumber("十"), 10, "中文 十")
eq(Spoiler.parseChapterNumber("十三"), 13, "中文 十三")
eq(Spoiler.parseChapterNumber("二十"), 20, "中文 二十")
eq(Spoiler.parseChapterNumber("二十三"), 23, "中文 二十三")
eq(Spoiler.parseChapterNumber("一百二十三"), 123, "中文 一百二十三")
ok(Spoiler.parseChapterNumber("上") == nil, "非数字返回 nil")
ok(Spoiler.parseChapterNumber("") == nil, "空串返回 nil")
ok(Spoiler.parseChapterNumber(nil) == nil, "nil 返回 nil")
local nums = Spoiler.extractChapterNumbers("详见第 12 章与第十三回，还有第3节")
eq(#nums, 3, "抽出 3 个章节号")
eq(nums[1], 12, "第 12 章")
eq(nums[2], 13, "第十三回")
eq(nums[3], 3, "第3节")
eq(#Spoiler.extractChapterNumbers("没有章节号的一句话"), 0, "无章节号时为空")

print("=== spoiler: 回答剧透预警 ===")
local a1, h1, r1 = Spoiler.scanAnswer("这个伏笔在第 10 章揭晓。", prog_ch)
eq(h1, true, "命中未读章节号")
eq(a1, Spoiler.WARNING, "替换为标准化模糊提示")
ok(tostring(r1):find("chapno", 1, true) ~= nil, "原因是章节号")
local a2, h2, r2 = Spoiler.scanAnswer("后面会写到 第四章 结局 那段。", prog_ch)
eq(h2, true, "命中未读章节标题")
eq(a2, Spoiler.WARNING, "标题命中同样替换")
ok(tostring(r2):find("title", 1, true) ~= nil, "原因是标题")
local a3, h3 = Spoiler.scanAnswer("这件事要到第十二章才说清楚。", prog_ch)
eq(h3, true, "中文数字章节号命中")
local a4, h4 = Spoiler.scanAnswer("如第 1 章所述，人物出场。", prog_ch)
eq(h4, false, "已读章节号不误伤")
eq(a4, "如第 1 章所述，人物出场。", "不误伤时原样返回")
local a5, h5 = Spoiler.scanAnswer("这句话写得很克制，用白描。", prog_ch)
eq(h5, false, "普通回答不误伤")
eq(a5, "这句话写得很克制，用白描。", "普通回答原样")
local a6, h6 = Spoiler.scanAnswer("第 10 章", { enabled = false, chapter_index = 2, chapter_total = 4 })
eq(h6, false, "关闭时不替换")
local a7, h7 = Spoiler.scanAnswer("第 10 章", { enabled = true })
eq(h7, false, "进度未知时不替换（不阻塞）")
local a8, h8 = Spoiler.scanAnswer("", prog_ch)
eq(h8, false, "空回答安全")
local a9, h9 = Spoiler.scanAnswer("第 4 章", prog_ch)
eq(h9, true, "第 4 章 > 当前第 2 章 → 预警")
local a10, h10 = Spoiler.scanAnswer("第 2 章", prog_ch)
eq(h10, false, "当前章节不预警")

print("=== spoiler: evaluate 统一入口 ===")
local b1, n1, f1 = Spoiler.evaluate({ enabled = true }, { chapter_index = 2, chapter_total = 4 }, "凶手是谁")
eq(b1, true, "未读区的剧透提问被拦下")
eq(f1, Spoiler.REFUSAL, "返回模糊话术")
ok(n1:find("第 2 / 4 章", 1, true) ~= nil, "注入当前章节")
ok(n1:find("截断", 1, true) ~= nil, "注入截断点声明")
local b2 = Spoiler.evaluate({ enabled = true }, {}, "凶手是谁")
eq(b2, false, "进度未知时不阻塞提问")
local b3 = Spoiler.evaluate({ enabled = true }, { chapter_index = 4, chapter_total = 4 }, "结局怎么样")
eq(b3, false, "已读到最后一章不阻塞")
local b4, n4 = Spoiler.evaluate({ enabled = false }, { chapter_index = 2, chapter_total = 4 }, "凶手是谁")
eq(b4, false, "关闭时不阻塞")
eq(n4, "", "关闭时不注入 prompt")
local b5 = Spoiler.evaluate({ enabled = true }, { chapter_index = 2, chapter_total = 4 }, "这句话什么意思")
eq(b5, false, "正常提问不拦")
local b6 = Spoiler.evaluate({ enabled = true }, { percent = 30 }, "后面剧情是什么")
eq(b6, true, "百分比进度下同样拦截")
local b7 = Spoiler.evaluate({ enabled = true }, { percent = 95 }, "后面剧情是什么")
eq(b7, false, "读到 95% 不拦")

print("=== spoiler: P2-1 自带序号的章节标题放宽命中边界 ===")
do
local prog_hdr = {
    enabled = true, granularity = "chapter",
    chapter_index = 3, chapter_total = 10,
    unread_titles = { "第七章", "第十章" },
}
local q1, iq1 = Spoiler.truncate("此处过渡到第七章。后面全是未读内容。", prog_hdr)
eq(iq1.truncated, true, "行内出现「第七章」时不再整句放行")
ok(q1:find("后面全是未读内容", 1, true) == nil, "未读正文零残留")
eq(q1, "此处过渡到", "截断点落在「第七章」之前")
-- 放宽只对「第 X 章」型标题生效，普通名词仍要求边界
local prog_word = { enabled = true, granularity = "chapter", unread_titles = { "结局" } }
local q2, iq2 = Spoiler.truncate("这个故事的结局很精彩。", prog_word)
eq(iq2.truncated, false, "普通名词标题仍要求边界（不误伤）")
local prog_hdr2 = { enabled = true, granularity = "chapter", unread_titles = { "第 12 回" } }
local q3, iq3 = Spoiler.truncate("铺垫到第 12 回才揭晓。后面全未读。", prog_hdr2)
eq(iq3.truncated, true, "阿拉伯数字章节标题同样放宽")

-- ---- QA 报的 GAP-D'：目录标题带副标题，正文里只写序号 ----
do
local CN12 = { "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二" }
local TOC_SUB = {}
for i = 1, 12 do
    TOC_SUB[i] = { title = "第" .. CN12[i] .. "章 雪夜其" .. CN12[i], page = i * 10, depth = 0 }
end
local prog_sub = Spoiler.readProgress({
    document = {
        info = { has_pages = false, number_of_pages = 150 },
        getPageCount   = function() return 150 end,
        getCurrentPage = function() return 45 end,
        getToc         = function() return TOC_SUB end,
    },
}, { enabled = true, granularity = "chapter" })
eq(prog_sub.chapter_index, 4, "GAP-D' 夹具：读到第 4 章")
eq(#prog_sub.unread_titles, 8, "GAP-D'：未读标题仍是 8 条（计数语义没被污染）")
eq(#(prog_sub.unread_tokens or {}), 8, "GAP-D'：抽出 8 个序号短写法")
eq(prog_sub.unread_tokens[1], "第五章", "GAP-D'：第一个短写法是「第五章」")
local d1, di1 = Spoiler.truncate("他说到第九章的时候就停住了，后面全是未读。", prog_sub)
eq(di1.truncated, true, "GAP-D' 修复：正文只写序号也能命中")
ok(d1:find("后面全是未读", 1, true) == nil, "GAP-D' 修复：未读原文零残留")
eq(d1, "他说到", "GAP-D' 修复：截断点落在序号之前")
-- 全写版本仍要命中（不能因为加了短写法就丢掉整条标题）
local d2, di2 = Spoiler.truncate("他说到第九章 雪夜其九的时候就停住了，后面全是未读。", prog_sub)
eq(di2.truncated, true, "GAP-D'：全写版本同样命中")
-- 已读章节的序号不能误伤
local d3, di3 = Spoiler.truncate("如第三章所述，人物已出场。", prog_sub)
eq(di3.truncated, false, "GAP-D'：已读章节序号不误伤")
-- 回答侧也要覆盖短写法
local da, dha = Spoiler.scanAnswer("这个伏笔要到第九章才揭晓。", prog_sub)
eq(dha, true, "GAP-D'：回答里的短写法序号同样被替换")
local db, dhb = Spoiler.scanAnswer("这段伏笔在第三章就埋下了。", prog_sub)
eq(dhb, false, "GAP-D'：已读章节号回答不误伤")
local dc, dhc = Spoiler.scanAnswer("这段用了白描，笔法克制。", prog_sub)
eq(dhc, false, "GAP-D'：普通回答不误伤")
local de = Spoiler.evaluate({ enabled = true }, prog_sub, "请问「第九章 终局密语」是什么意思")
eq(de, true, "GAP-D'：提问里用简写引用未读章节也被拦")
eq(Spoiler.extractChapterTokens("第 12 章与第十三回")[1], "第 12 章", "extractChapterTokens 保留原文写法")
eq(#Spoiler.extractChapterTokens("这一段没有章节号"), 0, "extractChapterTokens 无命中返回空")
end  -- GAP-D' do-block
end  -- P2-1 do-block

print("=== spoiler: P2-2 提问引用未读章节 → 整句回模糊话术 ===")
do
local pprog = {
    enabled = true, granularity = "chapter",
    chapter_index = 3, chapter_total = 10,
    unread_titles = { "第七章密语XYZ" },
}
local eb1, en1, ef1 = Spoiler.evaluate({ enabled = true }, pprog,
    "请问「第七章密语XYZ」这段暗语是什么意思？")
eq(eb1, true, "提问里引用未读章节原文 → 入口就拦下")
eq(ef1, Spoiler.REFUSAL, "返回完整模糊话术，不是半句 prompt")
local eb2 = Spoiler.evaluate({ enabled = true }, pprog, "这段用了什么写法？")
eq(eb2, false, "正常提问不拦")
local eb3 = Spoiler.evaluate({ enabled = false }, pprog, "请问「第七章密语XYZ」是什么意思？")
eq(eb3, false, "关闭时不拦")
-- 关键：不能以"把 user 消息切半句"的方式处理——出口仍会对历史做精确裁剪
local gm, gi = Spoiler.guardMessages({ { role = "user", content = "请问「第七章密语XYZ」是什么意思？" } }, pprog)
eq(gi.hits, 1, "guardMessages 仍兜住直接调用（历史/粘贴路径）")
-- 进度未知时不因为这条规则误伤正常提问
eq(Spoiler.evaluate({ enabled = true }, { enabled = true }, "第七章 ocurred"), false, "无标题表时不拦")
end  -- P2-2 do-block

print("=== spoiler: prompt 双保险注入 ===")
local note1 = Spoiler.buildNote({ enabled = true, granularity = "chapter", chapter_index = 3, chapter_total = 10, chapter = "雪夜" })
ok(note1:find("第 3 / 10 章", 1, true) ~= nil, "章节进度声明")
ok(note1:find("雪夜", 1, true) ~= nil, "章节名")
ok(note1:find("不许引用", 1, true) ~= nil, "禁止引用约束")
ok(note1:find("截断", 1, true) ~= nil, "截断点声明")
local note2 = Spoiler.buildNote({ enabled = true, granularity = "percent", percent = 42 })
ok(note2:find("42%", 1, true) ~= nil, "百分比进度声明")
eq(Spoiler.buildNote({ enabled = false }), "", "关闭时不注入")
local ms1 = Prompts.build("explain", { context = "【选中内容】\n宝玉", spoiler_note = note1 })
ok(ms1[1].content:find("防剧透约束", 1, true) ~= nil, "system 侧注入防剧透")
local ms2 = Prompts.build("explain", { context = "x" })
ok(ms2[1].content:find("防剧透", 1, true) == nil, "未传 note 时 system 不含防剧透（M2 行为不变）")
local hint1 = Prompts.spoilerHint({ enabled = true, granularity = "chapter", chapter_index = 3, chapter_total = 10 })
ok(hint1:find("第 3 / 10 章", 1, true) ~= nil, "user 侧提醒含进度")
local ms3 = Prompts.build("chat", { question = "他后来怎样", spoiler_note = note1, spoiler_hint = hint1 })
ok(ms3[1].content:find("防剧透", 1, true) ~= nil, "system 侧（第 1 道保险）")
ok(ms3[#ms3].content:find("我只读到", 1, true) ~= nil, "user 侧（第 2 道保险）")
eq(Prompts.spoilerHint({ enabled = false }), "", "关闭时无 user 侧提醒")
eq(Prompts.spoilerHint(nil), "", "无进度时无 user 侧提醒")
eq(Prompts.spoilerNote({ enabled = false }), "", "spoilerNote 关闭时为空")
ok(Prompts.spoilerNote({ enabled = true, chapter_index = 1, chapter_total = 3 }):find("第 1 / 3 章", 1, true) ~= nil,
    "spoilerNote 装配正确")

print("=== spoiler: 防剧透配置持久化 ===")
eq(Config:get("spoiler_guard"), true, "防剧透默认开启")
eq(Config:get("spoiler_granularity"), "chapter", "默认按章节")
Config:set("spoiler_granularity", "percent")
eq(Config:get("spoiler_granularity"), "percent", "粒度可切换并即时生效")
Config.settings = nil
Config.settings = Config:load()
eq(Config:get("spoiler_granularity"), "percent", "粒度落盘")
Config:set("spoiler_granularity", "chapter")
eq(Spoiler.currentConfig().granularity, "chapter", "currentConfig 读回 chapter")
Config:set("spoiler_guard", false)
eq(Spoiler.currentConfig().enabled, false, "currentConfig 读回关闭状态")
Config:set("spoiler_guard", true)
eq(Spoiler.currentConfig().enabled, true, "恢复默认开启")
local merged = Spoiler.withConfig({ percent = 30 }, { enabled = false })
eq(merged.enabled, false, "withConfig 可覆盖开关")
eq(merged.percent, 30, "withConfig 保留原有字段")
eq(Spoiler.withConfig(nil, nil).granularity, "chapter", "withConfig 默认 chapter")

--[[--
合集（collection 粒度）：一本 epub 含多部独立作品时，用户是**跳读**的。
按"读到第几章"判断会把排在前面的部误判成已读 → 剧透。
合集粒度下"未读"= 当前部之外的**所有其余各部**（前后都算）+ 当前部内当前位置之后的章节。
--]]
print("=== spoiler: 合集隔离（collection 粒度） ===")
do
-- 真合集夹具：3 部独立小说，每部下面有自己的章节（page 50 落在第 2 部《无人生还》的第 1 章）
local COL_TOC = {
    { title = "罗杰疑案",       page = 1,   depth = 0 },
    { title = "第一章 波洛",     page = 2,   depth = 1 },
    { title = "第二章 尸体",     page = 20,  depth = 1 },
    { title = "无人生还",       page = 40,  depth = 0 },
    { title = "第一章 十个小士兵", page = 41,  depth = 1 },
    { title = "第二章 孤岛之夜",  page = 60,  depth = 1 },
    { title = "第三章 最后一个",  page = 80,  depth = 1 },
    { title = "东方快车谋杀案",   page = 100, depth = 0 },
    { title = "第一章 雪夜列车",  page = 101, depth = 1 },
    { title = "第二章 十二个人",  page = 120, depth = 1 },
}
-- 普通单本小说：章节平铺、没有子层级
local FLAT_NOVEL = {
    { title = "雪夜奔袭", page = 1,  depth = 0 },
    { title = "渡口茶馆", page = 20, depth = 0 },
    { title = "旧信",     page = 40, depth = 0 },
    { title = "雪落无声", page = 60, depth = 0 },
    { title = "归途",     page = 80, depth = 0 },
}
-- 单本书的卷/篇结构：一级是「第 X 篇」，下面才是章（容易被误判成合集）
local VOLUME_NOVEL = {
    { title = "第一篇 童年", page = 1,  depth = 0 },
    { title = "第一章 雪",   page = 2,  depth = 1 },
    { title = "第二章 河",   page = 20, depth = 1 },
    { title = "第二篇 青年", page = 40, depth = 0 },
    { title = "第三章 城",   page = 41, depth = 1 },
    { title = "第三篇 壮年", page = 60, depth = 0 },
    { title = "第四章 海",   page = 61, depth = 1 },
}
local function has(list, s)
    if type(list) ~= "table" then return false end
    for _, v in ipairs(list) do if v == s then return true end end
    return false
end
local function fakeDocUI(toc, page, total)
    return {
        document = {
            info = { has_pages = false, number_of_pages = total or 150 },
            getPageCount   = function() return total or 150 end,
            getCurrentPage = function() return page end,
            getToc         = function() return toc end,
        },
    }
end

print("  -- 合集检测 --")
eq(Spoiler.isCollection(COL_TOC), true, "真合集：3 部且部内有章节 → 识别为合集")
eq(Spoiler.isCollection(TOC), false, "普通单本小说不误判（4 章 + 1 小节）")
eq(Spoiler.isCollection(TOC2), false, "fakeRollingUI 用的单本目录不误判")
eq(Spoiler.isCollection(FLAT_NOVEL), false, "平铺目录（无子层级）不误判")
eq(Spoiler.isCollection(VOLUME_NOVEL), false, "卷/篇式单本结构不误判")
eq(Spoiler.isCollection(nil), false, "目录缺失不误判")
eq(Spoiler.isCollection({}), false, "空目录不误判")
eq(Spoiler.isCollection({ { title = "唯一一部", page = 1, depth = 0 } }), false, "只有 1 个一级条目不误判")
eq(Spoiler.isCollection({
    { title = "上册", page = 1, depth = 0 },
    { title = "第一章", page = 2, depth = 1 },
    { title = "下册", page = 20, depth = 0 },
    { title = "第二章", page = 21, depth = 1 },
}), false, "上下册（2 部）低于阈值，不判合集")
eq(Spoiler.isCollection({ { title = "罗杰疑案", page = 1 },
                          { title = "无人生还", page = 40 },
                          { title = "东方快车", page = 100 } }),
    false, "目录没有 depth 信息时不误判（降级）")
eq(Spoiler.COLLECTION_MIN_WORKS, 3, "自动检测阈值：一级条目 >= 3")
eq(#Spoiler.workEntries(COL_TOC), 3, "一部作品 = 层级最浅的条目（共 3 部）")
eq(Spoiler.workEntries(COL_TOC)[1].title, "罗杰疑案", "第 1 部标题")
eq(Spoiler.hasNestedEntries(FLAT_NOVEL), false, "平铺目录没有更深层条目")
eq(Spoiler.hasNestedEntries(COL_TOC), true, "合集目录有更深层条目")

print("  -- 当前部定位 --")
local cw_o, cw_i = Spoiler.currentWork(COL_TOC, 50)
eq(cw_o, 2, "page 50 属于第 2 部")
eq(cw_i, 4, "第 2 部在 toc 里的下标")
local first_o = Spoiler.currentWork(COL_TOC, 110)
eq(first_o, 3, "page 110 属于第 3 部")
eq(Spoiler.currentWork(COL_TOC, 0), nil, "封面/序之前没有所属部")
local ci_col = Spoiler.collectionInfo(COL_TOC, 50)
eq(ci_col.index, 2, "collectionInfo：第 2 部")
eq(ci_col.total, 3, "collectionInfo：共 3 部")
eq(ci_col.title, "无人生还", "collectionInfo：部标题")
eq(Spoiler.collectionInfo(nil, 50).index, nil, "collectionInfo 无目录安全")

print("  -- 未读集合：前后各部都算未读 --")
local cu = Spoiler.collectionUnreadTitles(COL_TOC, 50)
eq(#cu, 4, "未读 = 其余 2 部 + 当前部内之后 2 章")
ok(has(cu, "罗杰疑案"), "前面的第 1 部也算未读（核心：跳读不能当成已读）")
ok(has(cu, "东方快车谋杀案"), "后面的第 3 部算未读")
ok(has(cu, "第二章 孤岛之夜"), "当前部内、当前位置之后的章节算未读")
ok(has(cu, "第三章 最后一个"), "当前部内更靠后的章节也算未读")
ok(not has(cu, "第一章 十个小士兵"), "当前部内、当前位置之前的章节算已读")
ok(not has(cu, "无人生还"), "当前在读的那一部本身不算未读")
ok(not has(cu, "第一章 波洛"), "其它部的子章节不进标记（否则「第一章」到处误命中）")
local cut = Spoiler.collectionUnreadTokens(COL_TOC, 50)
eq(#cut, 2, "未读序号短写法 2 条")
ok(has(cut, "第二章"), "短写法含「第二章」")
ok(not has(cut, "第一章"), "已读章节的短写法不进标记")

print("  -- readProgress 端到端 --")
local cprog = Spoiler.readProgress(fakeDocUI(COL_TOC, 50), { enabled = true, granularity = "collection" })
eq(cprog.collection_detected, true, "端到端：识别为合集")
eq(cprog.collection_active, true, "端到端：合集隔离生效")
eq(cprog.work_index, 2, "端到端：当前第 2 部")
eq(cprog.work_total, 3, "端到端：共 3 部")
eq(cprog.work_title, "无人生还", "端到端：部标题")
local cmarkers = Spoiler.markerList(cprog)
ok(has(cmarkers, "罗杰疑案"), "标记经 markerList 出口：含前面的部")
ok(has(cmarkers, "东方快车谋杀案"), "标记经 markerList 出口：含后面的部")
-- 四条消费路径必须全都吃到这些标记（不许新开只覆盖截断的旁路）
local ct, cti = Spoiler.truncate("这是已读内容。\n罗杰疑案\n前面那部的凶手其实是管家。", cprog)
eq(cti.truncated, true, "路径1 截断：命中前面那部的标题")
ok(ct:find("凶手其实是管家", 1, true) == nil, "路径1 截断：未读正文零残留")
-- 标题要落在边界上才命中（与章节标题同一套规则，「讲讲东方快车谋杀案」这种
-- 连写不算命中：这是既有的防误伤约束，作品标题同样遵守）
local cg, cgi = Spoiler.guardMessages({ { role = "user", content = "讲讲《东方快车谋杀案》" } }, cprog)
eq(cgi.hits, 1, "路径2 guardMessages：命中后面那部的标题")
local ca, cha = Spoiler.scanAnswer("这个手法在《东方快车谋杀案》里也用过。", cprog)
eq(cha, true, "路径3 回答预警：命中后面那部的标题")
eq(ca, Spoiler.WARNING, "路径3 回答预警：替换为标准提示")
local cb, cn, cf = Spoiler.evaluate({ enabled = true }, cprog, "请解释「东方快车谋杀案」这个标题")
eq(cb, true, "路径4 提问拦截：命中未读部的标题")
eq(cf, Spoiler.REFUSAL, "路径4 提问拦截：返回模糊话术")
ok(cn:find("第 2 / 3 部", 1, true) ~= nil, "prompt 声明当前是第 2 / 3 部")
ok(cn:find("不论排在它前面还是后面", 1, true) ~= nil, "prompt 声明其余各部前后都算未读")
ok(Spoiler.progressLabel(cprog):find("第 2 / 3 部", 1, true) ~= nil, "进度描述含部序号")

print("  -- 部标题放宽边界（>= 4 字句中即命中） --")
eq(Spoiler.WORK_TITLE_MIN_LEN, 4, "部标题免边界门槛是 4 个字符")
local crel = Spoiler.relaxedMarkers(cprog)
eq(crel["东方快车谋杀案"], true, "7 字部标题列入免边界集合")
eq(crel["罗杰疑案"], true, "4 字部标题列入免边界集合")
eq(crel["第二章 孤岛之夜"], nil, "章节标题**不**在免边界集合里（关键护栏）")
-- 句中连写也要命中（以前只在边界上命中，"讲讲东方快车谋杀案"是漏放）
ok(Spoiler.findMarker("讲讲东方快车谋杀案", cmarkers, crel) ~= nil, "长部标题：句中连写即命中")
local rt1, rti1 = Spoiler.truncate("这是已读内容。讲讲东方快车谋杀案的剧情如何展开。", cprog)
eq(rti1.truncated, true, "路径1 截断：长部标题句中命中")
ok(rt1:find("东方快车谋杀案", 1, true) == nil, "路径1 截断：部标题本身零残留")
ok(rt1:find("剧情如何展开", 1, true) == nil, "路径1 截断：部标题之后的内容零残留")
eq(rt1, "这是已读内容。讲讲", "路径1 截断：截断点落在部标题之前")
local rg1, rgi1 = Spoiler.guardMessages({ { role = "user", content = "讲讲东方快车谋杀案" } }, cprog)
eq(rgi1.hits, 1, "路径2 guardMessages：长部标题句中命中")
local ra1, rha1 = Spoiler.scanAnswer("这个手法在东方快车谋杀案里也用过。", cprog)
eq(rha1, true, "路径3 回答预警：长部标题句中命中")
eq(ra1, Spoiler.WARNING, "路径3 回答预警：替换为标准提示")
local rb1 = Spoiler.evaluate({ enabled = true }, cprog, "东方快车谋杀案讲的是什么")
eq(rb1, true, "路径4 提问拦截：长部标题句中命中")
-- 短部标题（< 4 字）仍要求边界，否则「茶馆」「雷雨」这种词会满篇误伤
local SHORT_TOC = {
    { title = "茶馆",   page = 1,  depth = 0 },
    { title = "第一章", page = 2,  depth = 1 },
    { title = "龙须沟", page = 20, depth = 0 },
    { title = "第一章", page = 21, depth = 1 },
    { title = "雷雨",   page = 40, depth = 0 },
    { title = "第一章", page = 41, depth = 1 },
}
eq(Spoiler.isCollection(SHORT_TOC), true, "短部标题夹具：仍被识别为合集")
local sprog = Spoiler.readProgress(fakeDocUI(SHORT_TOC, 25), { granularity = "collection" })
eq(sprog.collection_active, true, "短部标题夹具：隔离生效")
eq(sprog.work_title, "龙须沟", "短部标题夹具：当前第 2 部")
local smarkers = Spoiler.markerList(sprog)
ok(has(smarkers, "茶馆") and has(smarkers, "雷雨"), "短部标题仍进标记表")
local srel = Spoiler.relaxedMarkers(sprog)
eq(srel["茶馆"], nil, "2 字部标题不放宽")
eq(srel["龙须沟"], nil, "3 字部标题不放宽（< 4）")
eq(srel["雷雨"], nil, "2 字部标题不放宽")
ok(Spoiler.findMarker("这里提到了茶馆二字", smarkers, srel) == nil, "短部标题：句中连写不命中（防误伤）")
ok(Spoiler.findMarker("这里提到了《茶馆》", smarkers, srel) ~= nil, "短部标题：落在边界上仍命中")
local st1 = Spoiler.truncate("他走进茶馆时天还没黑，后面是未读内容。", sprog)
eq(st1, "他走进茶馆时天还没黑，后面是未读内容。", "短部标题：句中不误伤正常上下文")
-- 章节标题行为完全不变（回归护栏：放宽只认部标题）
-- 注：「第 X 章」型标题本来就有自己的免边界规则（P2-1），这里用不带序号的章节标题验证
ok(Spoiler.findMarker("他说到雪夜奔袭时才停住", { "雪夜奔袭" }, crel) == nil,
    "非部标题（4 字章节标题）仍要求边界：放宽只认部标题")
ok(Spoiler.findMarker("他说到《雪夜奔袭》时才停住", { "雪夜奔袭" }, crel) ~= nil,
    "同一章节标题落在边界上仍命中")
local t_unchanged, ti_unchanged = Spoiler.truncate("这个故事的结局很精彩。",
    { enabled = true, granularity = "chapter", unread_titles = { "结局" } })
eq(ti_unchanged.truncated, false, "章节标题防误伤规则不变（「结局」句中不命中）")
eq(t_unchanged, "这个故事的结局很精彩。", "章节标题：不误伤时原样返回")
ok(Spoiler.findMarker("任意文本", cmarkers) == nil, "不传 relaxed_set 时行为与原来一致")

print("  -- 开关：自动 / 开 / 关 --")
eq(Spoiler.resolveCollectionMode("auto", COL_TOC), true, "auto：真合集 → 隔离")
eq(Spoiler.resolveCollectionMode("off", COL_TOC), false, "off：强制不隔离")
eq(Spoiler.resolveCollectionMode("on", FLAT_NOVEL), true, "on：未识别出也强制隔离")
eq(Spoiler.resolveCollectionMode(nil, COL_TOC), true, "未设置按 auto 处理")
local off_prog = Spoiler.readProgress(fakeDocUI(COL_TOC, 50), { granularity = "collection", collection = "off" })
eq(off_prog.collection_active, false, "开关关：不按合集隔离")
ok(has(off_prog.unread_titles, "东方快车谋杀案"), "开关关：后面那部仍然未读（退回 chapter 语义）")
ok(not has(off_prog.unread_titles, "罗杰疑案"), "开关关：前面那部不再算未读")
local forced = Spoiler.readProgress(fakeRollingUI(), { granularity = "chapter", collection = "on" })
eq(forced.collection_active, true, "手动开：单本目录也强制按部隔离")
ok(has(forced.unread_titles, "第一章 开场"), "手动开：排在前面的部也算未读")
local auto_ch = Spoiler.readProgress(fakeDocUI(COL_TOC, 50), { enabled = true, granularity = "chapter" })
eq(auto_ch.collection_active, true, "默认 chapter 粒度 + auto：合集书照样隔离")
ok(has(auto_ch.unread_titles, "罗杰疑案"), "默认粒度下前面的部也算未读")
local pct_prog = Spoiler.readProgress(fakeDocUI(COL_TOC, 50), { granularity = "percent" })
eq(pct_prog.collection_active, false, "percent 粒度不做合集隔离（用户主动选了粗粒度）")
eq(Spoiler.currentConfig().collection, "auto", "默认开关是自动")
Config:set("spoiler_collection", "on")
eq(Spoiler.currentConfig().collection, "on", "开关可切换并读回")
Config:set("spoiler_collection", "auto")
eq(Spoiler.currentConfig().collection, "auto", "开关恢复默认")
eq(Spoiler.withConfig(cprog, { collection = "off" }).collection_setting, "off", "withConfig 透传合集开关")

print("  -- 降级 --")
local d_no_toc = Spoiler.readProgress({
    paging = { current_page = 30 },
    document = { info = { has_pages = true }, getPageCount = function() return 120 end },
}, { enabled = true, granularity = "collection" })
eq(d_no_toc.granularity, "percent", "无目录：collection 回落到 percent")
eq(d_no_toc.granularity_auto, true, "无目录：打上自动回落标记")
eq(d_no_toc.collection_active, false, "无目录：不按合集隔离")
local ONE_WORK_TOC = {
    { title = "序",     page = 1,  depth = 0 },
    { title = "第一章", page = 5,  depth = 1 },
    { title = "第二章", page = 50, depth = 1 },
}
local d_one = Spoiler.readProgress(fakeDocUI(ONE_WORK_TOC, 20),
    { enabled = true, granularity = "collection" })
eq(d_one.collection_active, false, "只有 1 个一级条目时不按合集隔离（退回 chapter 语义）")
ok(type(d_one.unread_titles) == "table", "单部目录：未读集合仍是表，不报错")
eq(d_one.work_index, nil, "单部目录：不产出部序号")
local d_flat = Spoiler.readProgress(fakeDocUI(FLAT_NOVEL, 45), { enabled = true, granularity = "collection" })
eq(d_flat.collection_active, false, "平铺目录按普通书处理，不报错")
ok(#d_flat.unread_titles > 0, "平铺目录仍有未读标记（chapter 语义）")
local HEAD_COL = {
    { title = "罗杰疑案",      page = 30, depth = 0 },
    { title = "第一章 波洛",    page = 31, depth = 1 },
    { title = "无人生还",      page = 60, depth = 0 },
    { title = "第一章 十个小士兵", page = 61, depth = 1 },
    { title = "东方快车谋杀案",   page = 90, depth = 0 },
    { title = "第一章 雪夜列车",  page = 91, depth = 1 },
}
local d_head = Spoiler.readProgress(fakeDocUI(HEAD_COL, 5), { enabled = true, granularity = "collection" })
eq(d_head.work_index, 0, "合集书开头（还在序）：work_index = 0")
eq(d_head.work_total, 3, "合集书开头：仍能报出共 3 部")
ok(has(d_head.unread_titles, "罗杰疑案") and has(d_head.unread_titles, "无人生还")
    and has(d_head.unread_titles, "东方快车谋杀案"), "合集书开头：所有部都算未读")
ok(Spoiler.progressLabel(d_head):find("第 0 / 3 部", 1, true) == nil, "书开头不显示「第 0 / 3 部」")
ok(Spoiler.collectionUnreadTitles(nil, 5) ~= nil, "collectionUnreadTitles 无目录安全返回空表")
eq(#Spoiler.collectionUnreadTitles(nil, 5), 0, "无目录时未读集合为空")
eq(#Spoiler.collectionUnreadTokens(FLAT_NOVEL, "x"), 0, "非法页码安全返回空表")
end  -- 合集 do-block

print("=== spoiler: 管道无旁路 / 分层审查 ===")
local ywbf_files = { "cache", "config", "context", "crypto", "deepseek", "httpclient",
                     "prompts", "queue", "spoiler", "store", "suggest", "tokens", "util",
                     "export", "ota" }
local ui_leak = 0
for _, name in ipairs(ywbf_files) do
    local src = Config._read_file(PLUGIN_DIR .. "/ywbf/" .. name .. ".lua")
    if src and (src:find('require("ui/', 1, true) or src:find("require('ui/", 1, true)) then
        ui_leak = ui_leak + 1
    end
end
eq(ui_leak, 0, "ywbf/ 层无任何 KOReader UI 依赖")
local ui_files = { "asker", "chatdialog", "settings", "toastcard",
                   "favorites", "suggestpicker" }
local direct_post = 0
for _, name in ipairs(ui_files) do
    local src = Config._read_file(PLUGIN_DIR .. "/ui/" .. name .. ".lua")
    if src and src:find("HttpClient", 1, true) then direct_post = direct_post + 1 end
end
eq(direct_post, 0, "ui/ 层不直接发 HTTP（必须经 DeepSeek:chat）")

--[[--
**清单漂移检测**（2026-09-20 补）。

背景：这三处硬编码的文件清单**全都漂移过**，而且失效是**静默**的——
新增 `ywbf/export.lua` / `ui/favorites.lua` 时没进 `ywbf_files` / `ui_files`，
`ui/suggestpicker.lua` 更是从头到尾没进过任何清单。表现是 `eq(ui_leak, 0)`
照样绿，因为它根本没扫那个文件：**防线还在，但已经不覆盖新代码了。**

所以这里反向校验：用目录扫描拿到真实存在的文件，要求清单必须把它们都覆盖到。
配套两条对照组（否则"空扫描"会让下面每条断言恒绿）：
扫描必须真的扫到文件，且结果里含已知文件。
--]]
local function luaNamesIn(dir)
    local names = {}
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (ok_lfs and lfs and type(lfs.dir) == "function") then return nil end
    for f in lfs.dir(dir) do
        local n = f:match("^(.+)%.lua$")
        if n then names[#names + 1] = n end
    end
    table.sort(names)
    return names
end

local function hasName(list, want)
    for _i, n in ipairs(list or {}) do if n == want then return true end end
    return false
end

local function missingFrom(list, names)
    local has = {}
    for _i, n in ipairs(list or {}) do has[n] = true end
    local missing = {}
    for _j, n in ipairs(names or {}) do
        if not has[n] then missing[#missing + 1] = n end
    end
    return missing
end

do
    local ywbf_names = luaNamesIn(PLUGIN_DIR .. "/ywbf")
    ok(type(ywbf_names) == "table" and #(ywbf_names or {}) > 0,
        "扫到 ywbf/ 下的 .lua 文件（扫描本身可用，空扫描会让下条恒绿）")
    if type(ywbf_names) == "table" and #ywbf_names > 0 then
        ok(hasName(ywbf_names, "store"), "扫描结果里含已知文件 store.lua（对照）")
        local miss = missingFrom(ywbf_files, ywbf_names)
        eq(#miss, 0, "ywbf_files 覆盖了 ywbf/ 下每个 .lua（缺：" .. table.concat(miss, ",") .. "）")
    end

    local ui_names = luaNamesIn(PLUGIN_DIR .. "/ui")
    ok(type(ui_names) == "table" and #(ui_names or {}) > 0,
        "扫到 ui/ 下的 .lua 文件（扫描本身可用，空扫描会让下条恒绿）")
    if type(ui_names) == "table" and #ui_names > 0 then
        ok(hasName(ui_names, "asker"), "扫描结果里含已知文件 asker.lua（对照）")
        local miss_ui = missingFrom(ui_files, ui_names)
        eq(#miss_ui, 0, "ui_files 覆盖了 ui/ 下每个 .lua（缺：" .. table.concat(miss_ui, ",") .. "）")
    end
end

local ds_src = Config._read_file(PLUGIN_DIR .. "/ywbf/deepseek.lua")
ok(ds_src and ds_src:find("HttpClient.post", 1, true) ~= nil, "DeepSeek:chat 是唯一请求出口")
ok(ds_src and ds_src:find("guardMessages", 1, true) ~= nil, "出口处有截断管道")
ok(ds_src and ds_src:find("sanitizeAnswer", 1, true) ~= nil, "出口处有回答预警")

--[[--
P0 回归防护：逐个检查每个提问入口的调用点是否带上了 progress。
这次 P0 就是因为"没有任何一条断言覆盖入口传参"才漏网的 —— 这类问题只能靠
扫源码的字符串断言抓住（Asker:askSync 的防剧透输入完全来自 opts.progress）。
判定方式：从调用行往下读到调用块结束（`})` 收尾），块内必须出现 progress，
或者是把整个 g 传进去的 toastcard/chatdialog 入口。
--]]
print("=== spoiler: 提问入口 progress 传参检查（P0 回归防护） ===")
local entry_files = { "main.lua", "ui/toastcard.lua", "ui/chatdialog.lua", "ui/settings.lua" }
local entry_checked, missing_progress = 0, {}
do
local function readSrc(rel)
    return Config._read_file(PLUGIN_DIR .. "/" .. rel)
end
local function linesOf(src)
    src = (src or ""):gsub("\r\n", "\n")
    local out = {}
    for line in ("\n" .. src):gmatch("\n([^\n]*)") do out[#out + 1] = line end
    return out
end
for _, rel in ipairs(entry_files) do
    local src = readSrc(rel)
    ok(src ~= nil and #src > 0, "P0 检查：读到源码 " .. rel)
    local lines = linesOf(src)
    for i, line in ipairs(lines) do
        if line:find("^%s*function") then
            -- 函数定义行不算调用点
        else
            local asks = line:find("Asker:", 1, true)
                and (line:find("askAndShow", 1, true) or line:find("submitAsync", 1, true)
                     or line:find("askSync", 1, true))
            local opens = line:find("ToastCard:open", 1, true) or line:find("ChatDialog:open", 1, true)
            if asks or opens then
                entry_checked = entry_checked + 1
                local ok_call = false
                -- 形态 A：整表透传（open(self, g)），g 来自 gather()，天然带 progress
                local arg2 = line:match("%:%s*open%s*%(%s*[%w_]+%s*,%s*([%w_%.]+)%s*%)")
                if arg2 and (arg2 == "g" or arg2 == "opts") then
                    ok_call = true
                else
                    -- 形态 B：内联 table 参数，必须显式出现 progress
                    local block, j = "", i
                    while j <= #lines do
                        block = block .. lines[j] .. "\n"
                        if lines[j]:find("^%s*%}%)") or lines[j]:find("^%s*%)") then break end
                        j = j + 1
                    end
                    if block:find("progress", 1, true) then ok_call = true end
                end
                if not ok_call then
                    missing_progress[#missing_progress + 1] =
                        string.format("%s:%d %s", rel, i, (lines[i]:gsub("^%s+", "")))
                end
            end
        end
    end
end
for _, m in ipairs(missing_progress) do print("        [缺 progress] " .. m) end
ok(entry_checked >= 4, "P0 检查：确实扫到了入口调用点", entry_checked)
eq(#missing_progress, 0, "每个提问入口都传入了 progress（漏传 = 该入口防剧透整体失效）")

-- gather() 是整表透传的根：它必须产出 progress，否则 open(self, g) 全是空的
local gather_src = readSrc("main.lua")
ok(gather_src ~= nil and gather_src:find("progress = self:progress()", 1, true) ~= nil,
    "gather() 产出 progress（整表透传入口的根）")

-- 结构性兜底：即使漏传，Asker 也必须能自己把进度取回来
local asker_src = readSrc("ui/asker.lua")
ok(asker_src ~= nil and asker_src:find("setProgressProvider", 1, true) ~= nil,
    "Asker 提供进度兜底注册口")
ok(asker_src ~= nil and asker_src:find("fetchProgress", 1, true) ~= nil,
    "askSync 会在 progress 缺失时主动补取进度")
ok(asker_src ~= nil and asker_src:find("progress missing at", 1, true) ~= nil,
    "取不到进度时打 warn 日志而非静默")
local main_src = readSrc("main.lua")
ok(main_src ~= nil and main_src:find("setProgressProvider", 1, true) ~= nil,
    "main.lua 在 init 时注册了进度兜底来源")
end  -- P0 检查 do-block

-- 防止回归：菜单项必须带插件名前缀，否则用户分不清是哪个插件的入口。
-- 注意：不能复用 P0 检查段里的 readSrc —— 它定义在那个 do-block 内部，这里是 nil。
local menu_src = Config._read_file(PLUGIN_DIR .. "/main.lua")
ok(menu_src ~= nil, "能读到 main.lua 源码做静态检查")
if menu_src then
    for _, label in ipairs({ "远望书友-AI解释", "远望书友-AI摘要", "远望书友-轻问", "远望书友-深聊" }) do
        ok(menu_src:find(label, 1, true) ~= nil, "长按菜单项带插件前缀：" .. label)
    end
    ok(menu_src:find('"AI 解释"', 1, true) == nil
        and menu_src:find("_(\"AI 解释\")", 1, true) == nil,
        "不再有不带前缀的旧菜单文案")
end

-- 轻问结果必须带用户提问，否则用户不知道回答针对哪个问题
local asker_src = Config._read_file(PLUGIN_DIR .. "/ui/asker.lua")
ok(asker_src ~= nil, "能读到 ui/asker.lua 源码")
if asker_src then
    -- 不锁结尾的括号：收藏与回顾阶段一给 showResult 追加了第 5 个参数 ref（收藏按钮定位用），
    -- 锁到 ')' 会把"加了参数"误报成"丢了 question"。这条断言守的是 question 在不在。
    ok(asker_src:find("function Asker:showResult(title, content, extra_note, question", 1, true) ~= nil,
        "showResult 接受 question 参数（不锁参数个数）")
    ok(asker_src:find("你的问题", 1, true) ~= nil, "结果卡片里渲染「你的问题」")
    ok(asker_src:find("light_auto_popup", 1, true) ~= nil, "轻问回复弹出受 light_auto_popup 控制")
end

-- 深聊必须能连续追问（多轮），不是一问一答就结束
local chat_src = Config._read_file(PLUGIN_DIR .. "/ui/chatdialog.lua")
ok(chat_src ~= nil, "能读到 ui/chatdialog.lua 源码")
if chat_src then
    ok(chat_src:find("继续追问", 1, true) ~= nil, "深聊提供「继续追问」入口")
    ok(chat_src:find("historyForModel", 1, true) ~= nil, "深聊把历史作为多轮上下文传给模型")
    ok(chat_src:find("fetchProgress()", 1, true) ~= nil, "深聊每轮实时重取进度（对话期间可能翻页）")
end

-- 新增配置的默认值
ok(Config.DEFAULTS.light_auto_popup == true, "light_auto_popup 默认开启（快速查看）")
ok(Config.DEFAULTS.spoiler_collection ~= nil, "spoiler_collection 有默认值（合集判定）")

print("=== util: UTF-8 合法性净化（DeepSeek 400 的元凶） ===")
-- 背景：epub 正文里的脏字节会被 json.encode 原样写进请求体，
-- DeepSeek 返回 400 "invalid unicode code point"。必须在请求出口净化。
local CN = "中文正文"
eq(Util.sanitizeUtf8(CN), CN, "正常中文原样保留")
eq(Util.sanitizeUtf8("abc 123"), "abc 123", "ASCII 原样保留")
eq(Util.sanitizeUtf8(""), "", "空串安全")
eq(Util.sanitizeUtf8(nil), nil, "nil 安全")
eq(Util.sanitizeUtf8("表情" .. "\240\159\152\128"), "表情" .. "\240\159\152\128", "4 字节 emoji 保留")

eq(Util.sanitizeUtf8("A" .. "\128" .. "B"), "AB", "孤立续字节被丢弃")
eq(Util.sanitizeUtf8("A" .. "\191" .. "B"), "AB", "孤立续字节 0xBF 被丢弃")
eq(Util.sanitizeUtf8("A" .. "\228\184" .. "B"), "AB", "截断的 3 字节序列被丢弃")
eq(Util.sanitizeUtf8("A" .. "\228\184\173"), "A" .. "\228\184\173", "完整 3 字节汉字保留")
eq(Util.sanitizeUtf8("A" .. "\192\175" .. "B"), "AB", "非法起始字节 0xC0 被丢弃")
eq(Util.sanitizeUtf8("A" .. "\255" .. "B"), "AB", "0xFF 被丢弃")
eq(Util.sanitizeUtf8("A" .. "\237\160\128" .. "B"), "AB", "UTF-16 代理对 U+D800 被丢弃")
eq(Util.sanitizeUtf8("A" .. "\224\128\128" .. "B"), "AB", "超长编码被丢弃")
eq(Util.sanitizeUtf8("A" .. "\244\144\128\128" .. "B"), "AB", "超出 U+10FFFF 被丢弃")
eq(Util.sanitizeUtf8("A" .. string.char(1, 2, 3) .. "B"), "AB", "控制字符被丢弃")
eq(Util.sanitizeUtf8("A\nB\tC"), "A\nB\tC", "换行与制表符保留（prompt 需要）")

-- 幂等：净化过一遍就不该再有脏字节
local dirty = "前" .. "\128\237\160\128\255" .. "中" .. "\228\184" .. "后"
local once = Util.sanitizeUtf8(dirty)
eq(Util.sanitizeUtf8(once), once, "净化结果幂等（已无非法字节）")
ok(#once < #dirty, "脏字节确实被删掉了", #dirty .. " -> " .. #once)

-- 消息表净化
local msgs = {
    { role = "system", content = "系统" .. "\128" },
    { role = "user", content = "用户" .. "\237\160\128" },
}
local cleaned = Util.sanitizeMessages(msgs)
eq(cleaned[1].content, "系统", "sanitizeMessages 净化 system 内容")
eq(cleaned[2].content, "用户", "sanitizeMessages 净化 user 内容")
eq(cleaned[2].role, "user", "非字符串字段不受影响")
eq(Util.sanitizeMessages(nil), nil, "sanitizeMessages 对 nil 安全")

--[[--
行为断言：真的走一次请求出口，检查发出去的请求体里有没有脏字节。

为什么不用静态断言（扫源码里有没有出现 "sanitizeMessages"）：
变异测试证明那样抓不住——把调用注释掉后，注释里仍然含这个函数名，
字符串匹配照样命中，测试全绿而线上照样 400。静态断言对这种"写了没接"的
漏网无效，必须看实际产物。
--]]
local DeepSeek = require("ywbf/deepseek")
-- 单测用的是独立的 testdata 目录，里面没有 API Key，chat 会在取 Key 那步就返回。
-- 这里临时塞一个假 Key（stub 掉了 HttpClient.post，不会真的发出去）。
local had_key = Config:get("api_key_enc")
Config:set("api_key_enc", Crypto:encrypt("sk-mutate-test-key"))

local real_post = HttpClient.post
local captured_body = nil
HttpClient.post = function(url, headers, body, timeout)
    captured_body = body
    return '{"choices":[{"message":{"content":"ok"}}],"usage":{"total_tokens":1}}', 200, "OK", nil
end
local ok_call, res, call_err = pcall(DeepSeek.chat, DeepSeek, {
    { role = "user", content = "前面正常" .. string.char(0x80) .. "\237\160\128" .. "后面正常" },
}, {})
HttpClient.post = real_post
Config:set("api_key_enc", had_key)  -- 还原，别污染后续用例

ok(ok_call, "DeepSeek:chat 正常返回", call_err)
ok(captured_body ~= nil, "请求体被捕获（stub 生效）")
if captured_body then
    ok(captured_body:find(string.char(0x80), 1, true) == nil,
        "发出的请求体不含孤立续字节（出口已净化）")
    ok(captured_body:find("\237\160\128", 1, true) == nil,
        "发出的请求体不含代理对字节（出口已净化）")
    ok(captured_body:find("前面正常", 1, true) ~= nil
        and captured_body:find("后面正常", 1, true) ~= nil,
        "净化没有误删正常中文")
end

-- 源码里也要出现该调用（辅助检查，仅防整段被删；真正兜底的是上面的行为断言）
local ds_src2 = Config._read_file(PLUGIN_DIR .. "/ywbf/deepseek.lua")
ok(ds_src2 ~= nil, "P1 检查：读到源码 ywbf/deepseek.lua")
if ds_src2 then
    ok(ds_src2:find("sanitizeMessages", 1, true) ~= nil,
        "请求出口必须调用 Util.sanitizeMessages（否则脏字节导致 DeepSeek 400）")
    ok(ds_src2:find("Util.sanitizeMessages(guarded)", 1, true) ~= nil,
        "净化作用在 guardMessages 之后的待发送内容上")
end

print("=== util.fillLine：分隔线按像素宽生成 ===")
-- 背景：分隔线写死一串破折号，在 KPW4（1072px）上只占三分之一行。
eq(Util.fillLine(1000, 20, "—"), string.rep("—", 50), "1000px / 20px = 50 个字符")
eq(Util.fillLine(1000, 25, "—"), string.rep("—", 40), "字符变宽就少排几个")
eq(Util.fillLine(1000, 20, "-"), string.rep("-", 50), "自定义填充字符")
eq(Util.fillLine(0, 20, "—"), "", "可用宽度为 0 时返回空串（调用方退回固定长度）")
eq(Util.fillLine(1000, 0, "—"), "", "单字符宽度为 0 时返回空串")
eq(Util.fillLine(nil, 20, "—"), "", "参数缺失时返回空串")
-- 字距微调会让连写的串比 n*unit 略宽，传了 measure 就要递减到真放得下
local measured_n = Util.fillLine(100, 20, "—", function(s)
    return Util.utf8len(s) * 20 + math.max(0, Util.utf8len(s) - 1) * 2
end)
eq(Util.utf8len(measured_n), 4, "measure 报超宽时递减到放得下（5 个 108px → 4 个 86px）")

-- 边界：这些输入都在真机上出现过（屏幕极窄、字体量不出来、measure 自身抛异常）
-- 整段包在函数里：run_tests.lua 是一个巨大的主 chunk，局部变量数量逼近
-- Lua 的 200 个上限，新增断言必须自带作用域，否则编译期直接报
-- "main function has more than 200 local variables"。
local function fillLineEdgeChecks()
eq(Util.fillLine(10, 20, "—"), "", "单字符比可用宽还宽时返回空串（n 先算成 0，调用方退回兜底）")
eq(Util.fillLine(1, 0.5, "-"), "--", "可用宽极小也能算（1px / 0.5px = 2 个）")
eq(Util.fillLine(-100, 20, "-"), "", "负宽度返回空串")
eq(Util.fillLine("1000", 20, "-"), "", "宽度传成字符串返回空串（不崩）")
eq(Util.fillLine(100000, 20, "-"), string.rep("-", 500), "超宽屏有 500 字符上限（防 string.rep 爆掉）")
eq(Util.utf8len(Util.fillLine(100, 10, "界")), 10, "多字节中文按字符数重复（不是按字节）")
eq(Util.utf8len(Util.fillLine(100, 10, nil)), 10, "char 省略时用默认 '-'")
eq(Util.utf8len(Util.fillLine(100, 10, "-", function() error("测量炸了") end)), 10,
    "measure 抛异常被 pcall 吃掉，不冒泡，按未测宽处理")
eq(Util.utf8len(Util.fillLine(100, 10, "-", function() return nil end)), 10, "measure 返回 nil 时不递减")
eq(Util.utf8len(Util.fillLine(100, 10, "-", function() return "宽" end)), 10, "measure 返回非数字时不递减")
eq(Util.utf8len(Util.fillLine(100, 10, "-", function() return 1e9 end)), 1,
    "measure 一直报超宽时只退到 1 个就停（不会死循环）")
local measure_calls = 0
Util.fillLine(100, 10, "-", function()
    measure_calls = measure_calls + 1
    return 1e9
end)
ok(measure_calls <= 10, "measure 最多被调 10 次（递减有上限，不拖慢渲染）", measure_calls)
end
fillLineEdgeChecks()

print("=== 账户余额（GET /user/balance） ===")
--[[--
行为断言：stub 掉 ssl.https.request，看真正发出去的请求是什么。
静态断言（源码里有没有 "HttpClient.get"）抓不住"写了没接"，
也抓不住"用 POST 带了个空 body 去查余额"这类偏差。
--]]
-- 主 chunk 的局部变量上限是 200，本节局部变量多，用 do 块收口，
-- 免得后面再补用例时撞上 "main function has more than 200 local variables"
do
local ltn12 = require("ltn12")
local https_mod = require("ssl.https")
local real_request = https_mod.request

local captured = nil
local function stub_response(body_str, code)
    https_mod.request = function(payload)
        captured = payload
        if payload.sink and body_str then
            ltn12.pump.all(ltn12.source.string(body_str), payload.sink)
        end
        return 1, code or 200, {}, "HTTP/1.1 200 OK"
    end
end

local BALANCE_JSON = '{"is_available":true,"balance_infos":['
    .. '{"currency":"CNY","total_balance":"19.73","granted_balance":"0.00","topped_up_balance":"19.73"}]}'

local had_key2 = Config:get("api_key_enc")
Config:set("api_key_enc", Crypto:encrypt("sk-balance-test-key"))

stub_response(BALANCE_JSON, 200)
local bal, bal_err = DeepSeek:balance()
ok(bal ~= nil, "余额查询成功", bal_err)
if bal then
    eq(bal.is_available, true, "is_available 解析正确")
    ok(type(bal.balances) == "table" and #bal.balances == 1, "解析出 1 条余额",
        bal.balances and #bal.balances)
    eq(bal.balances[1].currency, "CNY", "币种解析正确")
    eq(bal.balances[1].total_balance, "19.73", "总余额解析正确")
    eq(bal.balances[1].topped_up_balance, "19.73", "充值余额解析正确")
    eq(bal.balances[1].granted_balance, "0.00", "赠送余额解析正确")
end
ok(captured ~= nil, "请求被捕获（stub 生效）")
if captured then
    eq(captured.method, "GET", "余额查询用 GET（不是 POST）")
    eq(captured.url, DeepSeek.BALANCE_ENDPOINT, "请求打在 /user/balance")
    ok(captured.source == nil, "GET 不带请求体（不发送任何书籍内容）")
    ok(type(captured.headers) == "table"
        and tostring(captured.headers["Authorization"]):find("^Bearer ") ~= nil,
        "带 Bearer 鉴权头")
    ok(captured.sink ~= nil, "GET 也接收响应体")
end

-- 非 200：余额接口偶尔会返回 401/402，必须把状态码带进错误信息里
stub_response('{"error":{"message":"Insufficient balance"}}', 402)
local bal2, bal_err2 = DeepSeek:balance()
ok(bal2 == nil, "非 200 时余额查询失败")
ok(type(bal_err2) == "string" and bal_err2:find("402", 1, true) ~= nil,
    "错误信息带上状态码 402", bal_err2)

-- 没配 Key 时不能发请求
stub_response(BALANCE_JSON, 200)
Config:set("api_key_enc", nil)
local bal3, bal_err3 = DeepSeek:balance()
ok(bal3 == nil, "未配置 Key 时余额查询直接失败")
ok(type(bal_err3) == "string" and bal_err3:find("API Key", 1, true) ~= nil,
    "未配置 Key 的错误信息可读", bal_err3)
Config:set("api_key_enc", Crypto:encrypt("sk-balance-test-key"))

-- 白名单对 GET 同样生效（只读接口不能成为出站口子）
local get_body, get_code, get_status, get_err = HttpClient.get("https://evil.example.com/balance", {}, 5)
ok(get_body == nil and get_code == nil, "GET 也拒绝白名单外的域名", get_code)
ok(type(get_err) == "string" and get_err:find("host not allowed", 1, true) ~= nil,
    "GET 越界返回 host not allowed", get_err)

-- 余额查询不该往防剧透管道里塞东西：确认它没走 chat
stub_response(BALANCE_JSON, 200)
local bal4 = DeepSeek:balance()
ok(bal4 ~= nil and bal4.spoiler_hit == nil, "余额结果不带防剧透字段（未走 chat 管道）")

-- 边界响应：真机上会遇到的畸形返回，每种都必须"不崩 + 有可读错误或合理降级"
-- 同样包成函数（主 chunk 局部变量上限的原因见 fillLineEdgeChecks 处）
local function balanceEdgeChecks()
stub_response("<html><head><title>502 Bad Gateway</title></head><body>nginx</body></html>", 200)
local bh, bh_err = DeepSeek:balance()
ok(bh == nil and type(bh_err) == "string" and bh_err:find("解析失败", 1, true) ~= nil,
    "HTML 错误页（200）不会崩，给出『响应解析失败』", bh_err)

stub_response("", 200)
local be, be_err = DeepSeek:balance()
ok(be == nil and type(be_err) == "string", "空响应体不会崩，给出错误", be_err)

stub_response('{"is_available":true,"balance_infos":[', 200)
local bt, bt_err = DeepSeek:balance()
ok(bt == nil and type(bt_err) == "string", "JSON 被截断不会崩，给出错误", bt_err)

stub_response('{"error":{"message":"Invalid API key"}}', 401)
local b401, b401_err = DeepSeek:balance()
ok(b401 == nil and type(b401_err) == "string" and b401_err:find("401", 1, true) ~= nil,
    "401 未授权的错误信息带状态码", b401_err)

stub_response('{"is_available":false,"balance_infos":[]}', 200)
local bz = DeepSeek:balance()
ok(bz ~= nil, "is_available=false + 空余额列表：正常返回（不崩）", bz)
if bz then
    eq(bz.is_available, false, "is_available=false 原样带出")
    ok(type(bz.balances) == "table" and #bz.balances == 0, "空列表时 balances 为空表（UI 走降级文案）")
end

stub_response('{"is_available":true}', 200)
local bnf = DeepSeek:balance()
ok(bnf ~= nil and type(bnf.balances) == "table" and #bnf.balances == 0,
    "balance_infos 字段缺失时降级成空列表（不崩）", bnf and #bnf.balances)

stub_response('{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":19.73,"granted_balance":0,"topped_up_balance":19.73}]}', 200)
local bnum = DeepSeek:balance()
ok(bnum ~= nil and bnum.balances[1] and bnum.balances[1].total_balance == 19.73,
    "total_balance 是数字时原样带出（由展示层 tostring）", bnum and bnum.balances[1] and bnum.balances[1].total_balance)

-- 出站内容：余额查询这条路上绝对不能出现 POST（POST 才是携带书籍内容的那条路）
local real_post_for_balance = HttpClient.post
local post_hits = 0
HttpClient.post = function(...)
    post_hits = post_hits + 1
    return real_post_for_balance(...)
end
stub_response(BALANCE_JSON, 200)
local bnp = DeepSeek:balance()
HttpClient.post = real_post_for_balance
ok(bnp ~= nil and post_hits == 0, "余额查询全程不碰 HttpClient.post（不带任何请求体）", post_hits)
end
balanceEdgeChecks()

https_mod.request = real_request
Config:set("api_key_enc", had_key2)  -- 还原，别污染后续用例
end

-- 菜单里必须有入口，否则功能写了用户也找不到
do
local st_src = Config._read_file(PLUGIN_DIR .. "/ui/settings.lua")
ok(st_src ~= nil, "P1 检查：读到源码 ui/settings.lua")
if st_src then
    ok(st_src:find("查询账户余额", 1, true) ~= nil, "设置菜单里有「查询账户余额」入口")
    ok(st_src:find("DeepSeek:balance()", 1, true) ~= nil, "菜单入口真的调到了 DeepSeek:balance()")
    ok(st_src:find("retries = 0", 1, true) ~= nil, "余额查询失败不重试（避免退避等待卡界面）")
end

local cd_src = Config._read_file(PLUGIN_DIR .. "/ui/chatdialog.lua")
ok(cd_src ~= nil, "P1 检查：读到源码 ui/chatdialog.lua")
if cd_src then
    ok(cd_src:find("buildSeparator", 1, true) ~= nil, "深聊分隔线改为按屏幕宽度生成")
    ok(cd_src:find('local SEP = "————————————————"', 1, true) == nil,
        "不再有写死长度的分隔线（宽度写死在宽屏上只占一小截）")
    ok(cd_src:find("Util.fillLine", 1, true) ~= nil, "分隔线长度走 Util.fillLine 计算")
end

--[[--
buildSeparator / formatBalance 的行为断言。

这两个都是 UI 模块的 local 函数，无头环境里 require 不到（CanvasContext 未初始化），
所以把函数体从源码里抠出来，配一套桩直接跑起来看产物。

为什么必须这么绕：静态断言抓不住两类真实事故——
  · buildSeparator 被改成直接 return SEP_FALLBACK：源码里 "Util.fillLine"
    那行还在，静态断言全绿，用户看到的又是"写死 24 个破折号、只占三分之一行"的老 bug；
  · formatBalance 的 for 循环变量 _ 遮蔽了 gettext 的 _：源码里 "_(...)" 一字不差，
    静态断言全绿，真机上点「查询账户余额」直接 attempt to call a number value。
只有把函数真跑一遍才抓得住。
--]]
print("=== 分隔线与余额展示：行为断言（桩环境里跑真函数） ===")
local function uiBehaviourChecks()

-- ---- buildSeparator ----
local bs_s = cd_src and cd_src:find("local SEP_CHAR", 1, true)
local bs_e = cd_src and cd_src:find("local function previewLine", 1, true)
local bs_chunk = (bs_s and bs_e) and cd_src:sub(bs_s, bs_e - 1) or nil
ok(bs_chunk ~= nil and bs_chunk:find("Util.fillLine", 1, true) ~= nil,
    "P1 检查：定位到 buildSeparator 源码段")

-- 按 TextViewer 的几何搭一套屏幕/字体桩：宽度变了，分隔线长度必须跟着变
local SEP_PAD, SEP_MARGIN, SEP_SCREEN_PAD = 20, 10, 30
--[[--
可用宽的安全折扣，必须与 ui/chatdialog.lua buildSeparator() 里的 0.96 保持一致。

折扣不是拍脑袋：用户在 KPW4（1072px）上实测「分隔线多出一个字符、被挤到下一行」，
说明按几何算出来的可用宽比 TextBoxWidget 实际断行使用的宽度略大（字体回退、字距微调、
不同机型 scaleBySize 的取整差异都会贡献这点误差）。压满 100% 换来的只是多 1~2 个字符
的观感，翻车代价却是多出一行，所以两边都留 4% 余量。
KPW4 上的实际效果：49 → 47 个字符。

维护约定：改源码那个 0.96 就必须同步改这里，否则断言假红；反过来这里改了源码没改，
真机上就会重新出现"多一个字符换行"。下面那条"源码折扣仍在"的断言用来提示这种漂移。
--]]
local SEP_SAFETY = 0.96
local function usablePx(screen_w)
    return (screen_w - SEP_SCREEN_PAD - 2 * SEP_PAD - 2 * SEP_MARGIN) * SEP_SAFETY
end
local function wantChars(screen_w, unit_px)
    return math.floor(usablePx(screen_w) / unit_px)
end
ok(cd_src ~= nil and cd_src:find("0.96", 1, true) ~= nil,
    "源码里的 4% 安全折扣仍在（测试与源码必须同步改，防止单边漂移）")

local function makeSeparatorBuilder(screen_w, unit_px, extra_per_char)
    if not bs_chunk then return nil end
    local screen = nil
    if screen_w then
        screen = {
            getWidth = function() return screen_w end,
            scaleBySize = function(_, n) return n end,
        }
    end
    local font = { getFace = function(_, name) return { name = name } end }
    local size = { padding = { large = SEP_PAD }, margin = { small = SEP_MARGIN } }
    local rendertext = {
        sizeUtf8Text = function(_, _a, _b, _face, text)
            local n = Util.utf8len(text)
            return { x = n * unit_px + math.max(0, n - 1) * (extra_per_char or 0) }
        end,
    }
    local lg = { info = function() end, dbg = function() end, warn = function() end }
    local factory = load("local Device, Font, Size, RenderText, Util, logger = ...\n"
        .. bs_chunk .. "\nreturn buildSeparator")
    if not factory then return nil end
    local ok_f, fn = pcall(factory, { screen = screen }, font, size, rendertext, Util, lg)
    if not ok_f then return nil end
    return fn
end

local bs_kpw4 = makeSeparatorBuilder(1072, 20)
ok(bs_kpw4 ~= nil, "P1 检查：buildSeparator 在桩环境里跑起来了")
if bs_kpw4 then
    local sep = bs_kpw4()
    local n = Util.utf8len(sep)
    ok(n == wantChars(1072, 20),
        string.format("KPW4 1072px 上按可用宽算出 %d 个字符（不是兜底的 24）", wantChars(1072, 20)),
        string.format("got=%d want=%d", n, wantChars(1072, 20)))
    ok(n ~= 24, "分隔线不是写死的兜底长度 24（变异：直接 return SEP_FALLBACK）", n)

    local bs_wide = makeSeparatorBuilder(1600, 20)
    if bs_wide then
        local n2 = Util.utf8len(bs_wide())
        ok(n2 == wantChars(1600, 20) and n2 > n,
            "屏宽变大分隔线跟着变长（证明真的按屏幕算）",
            string.format("1072px->%d 1600px->%d", n, n2))
    end
    local bs_narrow = makeSeparatorBuilder(600, 20)
    if bs_narrow then
        local n3 = Util.utf8len(bs_narrow())
        -- 注意：600px / 20px 字宽算出来是 489.6/20 = 24.48 → 24，**恰好等于兜底长度 24**。
        -- 所以这一条无法区分"按公式算出的 24"和"直接 return SEP_FALLBACK 的 24"，
        -- 不能当作"确实按宽度算"的证据；下面那条换字宽的用例才是真正的鉴别性断言。
        ok(n3 == wantChars(600, 20),
            string.format("600px 窄屏按宽度算出 %d 个字符（与兜底值 24 相同，见下条鉴别）",
                wantChars(600, 20)), n3)
    end
    local bs_narrow2 = makeSeparatorBuilder(600, 15)
    if bs_narrow2 then
        local n4 = Util.utf8len(bs_narrow2())
        ok(n4 == wantChars(600, 15) and n4 ~= 24,
            "600px 窄屏换字宽后长度跟着变且不等于兜底值（证明是按宽度算，不是兜底）", n4)
    end
    -- measure 真的接上了：字距让连写比 n*unit 宽时必须递减到放得下
    local bs_kerning = makeSeparatorBuilder(1072, 20, 2)
    if bs_kerning then
        local nk = Util.utf8len(bs_kerning())
        local measured = nk * 20 + math.max(0, nk - 1) * 2
        ok(nk < wantChars(1072, 20) and measured <= usablePx(1072),
            "字距导致超宽时 measure 生效并递减（measure 没接上就会溢出）",
            string.format("n=%d measured=%.0f usable=%.0f", nk, measured, usablePx(1072)))
    end
    -- 拿不到屏幕信息时退回兜底，绝不抛错
    local bs_noscreen = makeSeparatorBuilder(nil, 20)
    if bs_noscreen then
        ok(Util.utf8len(bs_noscreen()) == 24, "无屏幕信息时退回 24 个兜底长度",
            Util.utf8len(bs_noscreen()))
    end
end

-- ---- formatBalance ----
local fb_s = st_src and st_src:find("local CURRENCY_SYMBOL = {", 1, true)
local fb_e = st_src and st_src:find("--[[--\n查询账户余额", 1, true)
local fb_chunk = (fb_s and fb_e) and st_src:sub(fb_s, fb_e - 1) or nil
ok(fb_chunk ~= nil, "P1 检查：定位到 formatBalance 源码段")

local fmt = nil
if fb_chunk then
    local ok_T, ffiutil = pcall(require, "ffi/util")
    local Tpl = (ok_T and ffiutil and ffiutil.template) or function(s, ...)
        local a = { ... }
        return (s:gsub("%%(%d)", function(d) return tostring(a[tonumber(d)] or "") end))
    end
    local factory = load("local _, T, SettingsUI = ...\n" .. fb_chunk .. "\nreturn SettingsUI.formatBalance")
    if factory then
        local ok_f, fn = pcall(factory, function(s) return s end, Tpl, {})
        if ok_f then fmt = fn end
    end
end
ok(fmt ~= nil, "P1 检查：formatBalance 在桩环境里跑起来了")
if fmt then
    local ok1, txt1 = pcall(fmt, {
        is_available = true,
        balances = { { currency = "CNY", total_balance = "19.73",
                      granted_balance = "0.00", topped_up_balance = "19.73" } },
    })
    ok(ok1, "有余额条目时 formatBalance 正常返回（循环变量不得遮蔽 gettext 的 _）", txt1)
    if ok1 then
        ok(tostring(txt1):find("19.73", 1, true) ~= nil, "展示文本里有总余额", txt1)
        ok(tostring(txt1):find("CNY", 1, true) ~= nil, "展示文本里有币种", txt1)
    end
    local _, txt2 = pcall(fmt, nil)
    ok(tostring(txt2):find("没有拿到余额信息", 1, true) ~= nil, "nil 输入给出可读文案", txt2)
    local _, txt3 = pcall(fmt, { is_available = false, balances = {} })
    ok(tostring(txt3):find("接口没有返回余额条目", 1, true) ~= nil,
        "余额列表为空时降级文案可读", txt3)
end
end
uiBehaviourChecks()
end

print("=== 静态护栏：gettext 的 _ 不得被循环变量遮蔽 ===")
--[[--
真 bug 复盘（QA 变异/边界检查抓到的 P0）：
settings.lua 里 `for _, b in ipairs(res.balances)` 把文件头的
`local _ = require("gettext")` 遮蔽成一个 number，循环体里再调 _("…") 就是
"attempt to call a number value" —— 只要账户里有余额（正常情况）必崩。
更阴的是 Queue 用 pcall 包住 on_done，异常被静默吞掉，用户只看到
"正在查询余额…"闪一下然后什么都没有，连错误提示都没有。

这类问题单靠肉眼复查抓不住（同一个文件里还有 3 处同类写法在闭包里，
只有点到对应菜单项时才炸），所以在这里加一条静态护栏。
--]]
local GETTEXT_FILES = {
    "main.lua", "_meta.lua",
    "ui/asker.lua", "ui/chatdialog.lua", "ui/favorites.lua",
    "ui/settings.lua", "ui/suggestpicker.lua", "ui/toastcard.lua",
    "ywbf/deepseek.lua", "ywbf/export.lua", "ywbf/ota.lua", "ywbf/suggest.lua",
}
for _gi, rel in ipairs(GETTEXT_FILES) do
    local src = Config._read_file(PLUGIN_DIR .. "/" .. rel)
    ok(src ~= nil, "读到源码 " .. rel)
    if src then
        ok(src:find('require("gettext")', 1, true) ~= nil, rel .. " 以 _ 作为 gettext")
        ok(src:find("for _, ", 1, true) == nil,
            rel .. " 不用 _ 作循环变量（会遮蔽 gettext）")
        ok(src:find(", _ in ", 1, true) == nil,
            rel .. " 不用 (i, _) 作循环变量（会遮蔽 gettext）")
    end
end

--[[--
GETTEXT_FILES 的漂移检测（同上，同一类故障的第二个实例）。

`ui/favorites.lua` / `ywbf/export.lua` 新增时没进清单，`ui/suggestpicker.lua`
更是从头到尾没进过——也就是说"加了新文件、护栅静默失效"这个故障**至少发生过两次**，
只是前一次没人发现。这里反向校验：凡是源码里 `require("gettext")` 的文件，
都必须在 GETTEXT_FILES 里。

对照组：扫描必须真的扫到文件、且结果里含已知文件（`main.lua`），
否则"空扫描"会让下面两条断言恒绿。
--]]
do
    local rels = {}
    local root_names = luaNamesIn(PLUGIN_DIR)
    for _i, n in ipairs(root_names or {}) do rels[#rels + 1] = n .. ".lua" end
    for _j, n in ipairs(luaNamesIn(PLUGIN_DIR .. "/ui") or {}) do rels[#rels + 1] = "ui/" .. n .. ".lua" end
    for _k, n in ipairs(luaNamesIn(PLUGIN_DIR .. "/ywbf") or {}) do rels[#rels + 1] = "ywbf/" .. n .. ".lua" end

    ok(#rels > 0, "扫到插件目录下的 .lua 文件（扫描本身可用，空扫描会让下条恒绿）")
    ok(hasName(rels, "main.lua"), "扫描结果里含已知文件 main.lua（对照）")

    local miss = {}
    for _m, rel in ipairs(rels) do
        local src = Config._read_file(PLUGIN_DIR .. "/" .. rel)
        if src and src:find('require("gettext")', 1, true) and not hasName(GETTEXT_FILES, rel) then
            miss[#miss + 1] = rel
        end
    end
    eq(#miss, 0, "GETTEXT_FILES 覆盖了每个用 gettext 的 .lua（缺：" .. table.concat(miss, ",") .. "）")
end

print("=== HttpClient 白名单：只认 https ===")
ok(HttpClient.isHostAllowed("https://api.deepseek.com/user/balance"), "放行 https 的余额接口")
ok(not HttpClient.isHostAllowed("http://api.deepseek.com/user/balance"),
    "不放行 http 明文出站（明文会泄露 Key 与请求内容）")

print("")
print(string.format("==== RESULTS: %d passed, %d failed ====", passed, failed))
if failed > 0 then os.exit(1) end
