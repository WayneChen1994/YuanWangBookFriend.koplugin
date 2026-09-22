--[[--
章边界与跨章跃迁（章末总结的地基）。

为什么单独开一个模块：`Spoiler.locateChapter` 只回答"我现在在第几章"，
**不回答"这一章到哪儿结束"**；而"整章读完才准总结"这条硬规矩（望仔拍板第 5 项）
必须先有"章的终点"才谈得上判定。这段逻辑跟防剧透是两件事，不要塞进 spoiler.lua。

序号空间：**与 `Spoiler.fineChapterInfo` 完全同一套**（同一 depth 内计数；
整份目录都没有 depth 时退化为"第几条就是第几章"）。
理由：章末总结里显示的"第 N 章"必须和收藏列表里的回目行对得上，
两套序号混用会重演"两条不同回的收藏显示成同一章"那类真机 bug。

@module ywbf.chapter
--]]--

local Util = require("ywbf/util")

local Chapter = {}

--[[--
"这一章有没有东西可总结"的字符数下限。

探针实测（`docs/design-chapter-summary.md` §9.4）：toc 里混着卷名/书目一类的
**分隔性条目**——人鼠之间「附录」27 B、卡拉马佐夫「第三卷」25 B、「尾声」6 B。
它们不是章节，弹「要不要总结本章」会让用户点进去发现无事可总结。

判定放在**取到正文之后**而不是建索引时：建索引手上只有目录，看不出正文有多长
（那 25 B 是"父条目的标题到它第一个子条目之间"那截，只有真去取才知道）。
取正文是 1–70 ms（§9.2），为这一次判定的代价可以接受。
--]]
Chapter.MIN_CHARS = 50

--[[--
走到文末时最多走多少步（见 endXPointer）。

一步 = 一个可见字符。实测一页约 150–700 步、耗时 15–70 ms；
上限给到 50000 是为了兜住"末页特别长"的极端情况，真走到上限就停在原地
（按已经拿到的终点用，绝不死循环）。
--]]
Chapter.MAX_WALK_STEPS = 50000

local function depthOf(entry)
    if type(entry) ~= "table" then return nil end
    return type(entry.depth) == "number" and entry.depth or nil
end

local function pageOf(entry)
    if type(entry) ~= "table" then return nil end
    return type(entry.page) == "number" and entry.page or nil
end

--[[--
建章索引。

关键：**下一条同层条目必须按 `depth` 找，不能取 `toc[i+1]`**。
探针实测哈利波特 toc 的 `[248]` 与 `[249]` 取出的正文长度**完全相同**（439,942 B）——
目录里存在父子/重叠条目，直接取相邻会把同一段正文算两次、或把"章末"判在一半。
卡拉马佐夫「第三卷」只有 25 B 也是同一个成因：它的下一条其实是自己的子条目。

@param toc        目录数组（{title,page,depth,xpointer}，按 page 升序）
@param page_count 全书页数（给最后一章算"最后一页"用；拿不到传 nil）
@return array 每项 { idx, title, depth, ordinal, total, key,
                     start_xp, end_xp, start_page, end_page, last_page, is_last }
--]]
function Chapter.build(toc, page_count)
    local index = {}
    if type(toc) ~= "table" or #toc == 0 then return index end

    -- 先按 depth 分组数出"同层总数 / 自己在同层里的序号"，
    -- 与 Spoiler.fineChapterInfo 的算法逐行对齐（改动必须两边一起改）
    local same_level_total = {}
    for _i, e in ipairs(toc) do
        local d = depthOf(e)
        local k = tostring(d)
        same_level_total[k] = (same_level_total[k] or 0) + 1
    end
    local no_depth = true
    for _i, e in ipairs(toc) do
        if depthOf(e) ~= nil then no_depth = false break end
    end

    local seen_at_level = {}
    for i, e in ipairs(toc) do
        local d = depthOf(e)
        local k = tostring(d)
        seen_at_level[k] = (seen_at_level[k] or 0) + 1
        local ordinal, total
        if no_depth then
            -- 整份目录都没有 depth：退化成"第几条就是第几章"
            ordinal, total = i, #toc
        else
            ordinal, total = seen_at_level[k], same_level_total[k]
        end

        -- 下一条**同层级**条目：depth 相等（都为 nil 也算相等）
        local next_index = nil
        for j = i + 1, #toc do
            if depthOf(toc[j]) == d then next_index = j break end
        end

        local title = ""
        if type(e.title) == "string" then title = Util.trim(e.title) end
        local nxt = next_index and toc[next_index] or nil
        local start_page = pageOf(e)
        local end_page = pageOf(nxt)
        local last_page
        if nxt then
            -- 下一章从第 N 页开始 ⇒ 本章最后一页是 N-1。
            -- 夹到 start_page：短章（起止同页）时 N-1 会小于章首，那就是同一页。
            last_page = (end_page and end_page - 1) or start_page
            if start_page and last_page and last_page < start_page then
                last_page = start_page
            end
        else
            -- 全书最后一章：末页就是全书最后一页
            last_page = (type(page_count) == "number" and page_count) or start_page
        end

        index[#index + 1] = {
            idx = i,
            title = title,
            depth = d,
            ordinal = ordinal,
            total = total,
            key = tostring(ordinal) .. "|" .. title,
            start_xp = type(e.xpointer) == "string" and e.xpointer ~= "" and e.xpointer or nil,
            end_xp = nxt and (type(nxt.xpointer) == "string" and nxt.xpointer ~= "" and nxt.xpointer or nil) or nil,
            start_page = start_page,
            end_page = end_page,
            last_page = last_page,
            is_last = (nxt == nil),
        }
    end
    return index
end

--[[--
当前页落在哪一章。
@return entry|nil
--]]
function Chapter.locate(index, page)
    if type(index) ~= "table" or type(page) ~= "number" then return nil end
    -- 不提前 break：引擎偶尔给出非单调递增的目录页码（Spoiler.locateChapter 同款理由）
    local best, best_page = nil, nil
    for _i, e in ipairs(index) do
        local p = e.start_page
        if type(p) == "number" and p <= page then
            if best_page == nil or p >= best_page then best, best_page = e, p end
        end
    end
    return best
end

--[[--
这一章**读完了吗**（望仔拍板第 5 项："整章读完才准总结"）。

判据就是"已经翻到本章的最后一页"：那一页已经在屏幕上出现过，
于是本章正文**物理上**全部进过 payload，不存在拿未读内容去总结的可能。
这条比任何 prompt 嘱咐都硬——它是防剧透里唯一不依赖模型自觉的一道。

@return bool
--]]
function Chapter.isReadThrough(entry, page)
    if type(entry) ~= "table" or type(page) ~= "number" then return false end
    local lp = entry.last_page
    if type(lp) ~= "number" then return false end
    return page >= lp
end

--[[--
显示用标题（"第 3 / 12 章：标题"）。
@return string
--]]
function Chapter.label(entry)
    if type(entry) ~= "table" then return "" end
    local t = (type(entry.title) == "string" and entry.title ~= "") and entry.title or nil
    if type(entry.ordinal) == "number" and type(entry.total) == "number" then
        if t then return string.format("第 %d / %d 章：%s", entry.ordinal, entry.total, t) end
        return string.format("第 %d / %d 章", entry.ordinal, entry.total)
    end
    return t or ""
end

function Chapter.newTracker()
    return { last_key = nil, last_ordinal = nil, last_depth = nil, last_entry = nil }
end

--[[--
喂进当前这一章，返回"刚刚读完的那一章"（没有则返回 nil）。

三种不触发的情况，正是设计文档 §1.3 定的：
  · **跳章**（目录直接跳到第 5 章）：上一页不在第 4 章，序号不连续；
  · **倒翻**：新序号不可能是 旧+1；
  · **一步跨过多个章节**：新-旧 > 1，无法确认中间那些章读了没有，
    宁可漏一次也不要替用户宣布"你读完了三章"。
另外 depth 不同也不触发：不同 depth 的 ordinal 不是同一个序号空间，
拿它们做 +1 比较等于拿第 3 部和第 4 章比大小。

@param tracker Chapter.newTracker() 的产物
@param entry   当前这一章（Chapter.locate 的结果，可为 nil）
@return entry|nil 刚刚读完那一章
--]]
function Chapter.update(tracker, entry)
    if type(tracker) ~= "table" then return nil end
    local finished = nil
    if type(entry) == "table" and type(tracker.last_entry) == "table"
        and type(entry.ordinal) == "number" and type(tracker.last_ordinal) == "number"
        and entry.depth == tracker.last_depth
        and entry.ordinal == tracker.last_ordinal + 1 then
        finished = tracker.last_entry
    end
    if type(entry) == "table" then
        tracker.last_key, tracker.last_ordinal = entry.key, entry.ordinal
        tracker.last_depth, tracker.last_entry = entry.depth, entry
    else
        tracker.last_key, tracker.last_ordinal = nil, nil
        tracker.last_depth, tracker.last_entry = nil, nil
    end
    return finished
end

-- ---------- 以下三个函数会碰到 document ----------
--[[--
本模块**不 require 任何 KOReader 模块**：document 一律由调用方传进来，
所有方法调用都过 pcall。这样单测里塞一个假 doc 就能跑（见 tools/）。
--]]

--[[--
章正文的**终点 xpointer**。

正常情况下就是"下一条同层条目"的 xpointer，直接取即可。
麻烦在**全书最后一章**：它没有下一条，而 crengine 的 `getTextFromXPointers`
**不接受 nil / 空串当终点**（实测：`bad argument #3 to '?' (string expected, got nil)`，
传空串则返回空文本）。

实测出来的可行走法（`tools/probe_chapter_text.lua` 的同源实验）：
  1. `doc:getPageXPointer(page_count)` 取末页**页首** xpointer；
  2. 从它起用 `doc:getNextVisibleChar` 一路走到文末。
只走末页这一页，实测 156 步 / 14.8 ms，多拿回 410 字节（正好是最后一页）。

@param doc   document 对象（可为 nil）
@param entry 章条目
@return string|nil
--]]
function Chapter.endXPointer(doc, entry)
    if type(entry) ~= "table" then return nil end
    if type(entry.end_xp) == "string" and entry.end_xp ~= "" then return entry.end_xp end
    if type(doc) ~= "table" then return nil end

    local np = nil
    if type(doc.getPageCount) == "function" then
        local ok_c, v = pcall(doc.getPageCount, doc)
        if ok_c and type(v) == "number" and v > 0 then np = v end
    end
    if not np then return nil end
    if type(doc.getPageXPointer) ~= "function" then return nil end

    local ok_p, xp = pcall(doc.getPageXPointer, doc, np)
    if not ok_p or type(xp) ~= "string" or xp == "" then return nil end
    if type(doc.getNextVisibleChar) ~= "function" then return xp end

    local steps = 0
    while steps < Chapter.MAX_WALK_STEPS do
        local ok_n, nxt = pcall(doc.getNextVisibleChar, doc, xp)
        if not ok_n or type(nxt) ~= "string" or nxt == "" or nxt == xp then break end
        xp = nxt
        steps = steps + 1
    end
    return xp
end

--[==[
按字节截断，**且绝不切在半个汉字上**。

为什么要这一步、以及为什么必须放在 `Util.sanitizeUtf8` **之前**：
`Util.sanitizeUtf8` 是 `out[#out+1] = s:sub(i, i+2)` —— **每一个 UTF-8 序列往
table 里塞一个槽**。中文 3 字节/字，一章 440 KB 就是约 14.7 万个槽，加上
`table.concat` 前的那份副本，峰值大约是正文的若干倍（这个倍数是估算，
**不是实测值**）。而后面那道 `chapter_summary_max_chars = 12000` 保护的是
API 账单，不是内存 —— 按原来的顺序，峰值内存**已经先花出去了**。

所以这里先按字节截一刀，再交给 sanitize：槽数从"整章字数"降到"上限字数"，
改的只是顺序。

为什么按**字节**而不是按字：内存账是按字节算的（`Util.utf8len` 要先把整串
扫一遍，那正是要避开的开销）。按字节截完再回退到最后一个完整字符即可。

@param s          string 原文
@param max_bytes  number 上限（字节）
@return string    不超过上限、且末尾一定是完整 UTF-8 字符的串
--]==]
function Chapter.truncateBytes(s, max_bytes)
    if type(s) ~= "string" then return nil end
    if type(max_bytes) ~= "number" or max_bytes <= 0 then return s end
    if #s <= max_bytes then return s end

    -- 从头按字符宽度往前走，只允许"整个字符都落在上限内"的那一步。
    -- 这样 cut 一定是某个完整字符的最后一个字节 —— 末尾不会是半个汉字。
    local i, cut = 1, 0
    while i <= max_bytes do
        local b = s:byte(i)
        if not b then break end
        local step = 1
        if b >= 0xF0 then      step = 4
        elseif b >= 0xE0 then  step = 3
        elseif b >= 0xC0 then  step = 2 end
        if i + step - 1 > max_bytes then break end
        cut = i + step - 1
        i = i + step
    end
    return s:sub(1, cut)
end

--[==[
一章正文的**内存上限**（字节），默认 64 KiB。

取值的道理：章总结真正会被送出去的是 `chapter_summary_max_chars = 12000`
字，中文 3 字节/字 ⇒ 约 36 KB。64 KiB 是它的 1.8 倍富余，超出部分本来就会
被截掉，**所以这道闸功能上零损失，只是不让峰值内存跟着整章长度涨**。

⚠️ 这个数**还没拿到真实上界**：探针实测的最大单区间 439,942 B **不等于上界**
—— `Chapter.build` 取的是"下一条**同 depth** 的条目"，目录分层且顶层只有几条
时（如「第一部 / 第二部」），顶层区间等于一整部，可以到 MB 级。等实测出真实
上界再定最终值；现在先按常量留着，改一处即可。
--]==]
Chapter.MAX_CHAPTER_BYTES = 65536

--[[--
取这一章的正文。

@param doc       document 对象
@param entry     章条目
@param max_bytes number|nil 内存上限（字节）；不给就用 `Chapter.MAX_CHAPTER_BYTES`
@return string|nil 取不到（无锚点 / 引擎报错）返回 nil
--]]
function Chapter.textOf(doc, entry, max_bytes)
    if type(doc) ~= "table" or type(entry) ~= "table" then return nil end
    local start_xp = type(entry.start_xp) == "string" and entry.start_xp ~= "" and entry.start_xp or nil
    if not start_xp then return nil end
    local end_xp = Chapter.endXPointer(doc, entry)
    if not end_xp then return nil end
    if type(doc.getTextFromXPointers) ~= "function" then return nil end

    local ok, txt = pcall(doc.getTextFromXPointers, doc, start_xp, end_xp)
    if not ok or type(txt) ~= "string" then return nil end

    -- **先截再净化**：顺序就是这次改动的全部价值（见 truncateBytes 的注释）。
    -- 反过来（先净化再截）峰值内存已经按整章长度花出去了。
    local limit = (type(max_bytes) == "number" and max_bytes > 0)
        and max_bytes or Chapter.MAX_CHAPTER_BYTES
    txt = Chapter.truncateBytes(txt, limit)
    -- 发送前必须净化：epub 正文里的脏字节会让 DeepSeek 回 400（Util.sanitizeUtf8 的注释）
    return Util.sanitizeUtf8(txt)
end

--[[--
这一章有没有东西可总结（过滤分隔性条目，见 MIN_CHARS 的注释）。
@param text Chapter.textOf 的返回值
@return bool
--]]
function Chapter.hasContent(text)
    if type(text) ~= "string" then return false end
    return Util.utf8len(Util.trim(text)) >= Chapter.MIN_CHARS
end

--[==[
=====================================================================
频次落盘（§8 第 4 步：自动弹窗不能每章都弹）
=====================================================================

为什么必须落盘而不是只放在内存里：插件随时会被 KOReader 重启（真机今天
就重启过一次），放内存的计数一重启就清零 ⇒ 用户刚被弹过、重启后**又**被弹一遍。
"刚读完就想安静看下一章"的人会被这东西烦到关掉整个开关，那这一期的活就白干了。

两条闸，缺一条都不够：
  · **同一章一天只弹一次**（`chapters[key] = day`）：倒着翻回去再翻过来
    是最常见的动作，不记"这一章弹没弹过"就会反复弹同一章；
  · **一天总共最多 N 次**（`count`）：一本回目极多的书（哈利波特 254 条目录）
    一晚上翻十几章，每章都问一次就是骚扰。

落盘只记"弹过没"，**不记正文、不记回答**。它是个计数器，不是内容库。
--]==]

Chapter.FREQ_VERSION = 1

--[==[
读写两个小工具**就放在本模块里**，不去 `Util` 加函数。

原因很实际：`ywbf/util.lua` 这一版正被严过关锁 md5 做独立验收，动它就会让
他那边的复现白做。等验收放行了，这两个函数该挪回 `Util.readFile/writeFile`
（那里才是它们的家，届时一并搬 + 补断言）。
--]==]
local function readAll(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local s = fh:read("*a")
    fh:close()
    return s
end

--[[--
"今天"是哪一天：`os.date("*t")` 在函数内部取，便于测试注入。
@return string "YYYY-MM-DD"
--]]
function Chapter.today(now)
    local t = (type(now) == "table") and now or os.date("*t")
    if type(t) ~= "table" then return "" end
    return string.format("%04d-%02d-%02d", t.year or 0, t.month or 0, t.day or 0)
end

function Chapter.newFreq(now)
    return { version = Chapter.FREQ_VERSION, day = Chapter.today(now),
             count = 0, chapters = {} }
end

--[[--
@return string|nil 频次文件的路径（Config 没 init 时是 nil）
--]]
function Chapter.freqPath()
    local ok, Config = pcall(require, "ywbf/config")
    if not ok or type(Config) ~= "table" then return nil end
    if type(Config.paths) ~= "table" then return nil end
    if type(Config.paths.data) ~= "string" or Config.paths.data == "" then return nil end
    return Config.paths.data .. "/chapter_freq.json"
end

--[[--
读频次。文件不存在 / 坏了 / 是昨天的 → 统统返回一张**干净的表**。

坏了就当没有，不修也不报错：这只是一个"别烦用户"的计数器，
它读不出来最坏的结果是"多弹一次"，而为了它去弹错误框才是真的烦人。
--]]
function Chapter.loadFreq(path, now)
    local today = Chapter.today(now)
    local freq = Chapter.newFreq(now)
    if type(path) ~= "string" or path == "" then return freq end

    local ok_json, json = pcall(require, "json")
    if not ok_json or type(json) ~= "table" then return freq end

    local raw = readAll(path)
    if type(raw) ~= "string" or raw == "" then return freq end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" then return freq end
    -- 换天就整张作废：昨天的 count 不该拿来卡今天
    if data.day ~= today then return freq end

    freq.count = type(data.count) == "number" and data.count or 0
    freq.chapters = type(data.chapters) == "table" and data.chapters or {}
    return freq
end

function Chapter.saveFreq(path, freq)
    if type(path) ~= "string" or path == "" then return false end
    if type(freq) ~= "table" then return false end
    local ok_json, json = pcall(require, "json")
    if not ok_json or type(json) ~= "table" then return false end
    local ok, body = pcall(json.encode, freq)
    if not ok or type(body) ~= "string" then return false end
    local fh = io.open(path, "wb")
    if not fh then return false end
    fh:write(body)
    fh:close()
    return true
end

--[[--
这一章**现在**许不许弹（纯判定，不碰磁盘，好测）。

@param freq      table  Chapter.loadFreq 的产物
@param key       string 章标识（`entry.key`）
@param now       table|nil os.date("*t")，测试注入用
@param max_per_day number 一天最多弹几次；<= 0 = 不限次
@return bool, string 许不许，以及不许的**原因**（日志要用，归因不能靠猜）
--]]
function Chapter.canAuto(freq, key, now, max_per_day)
    if type(freq) ~= "table" then return false, "no_freq" end
    if type(key) ~= "string" or key == "" then return false, "no_key" end

    local today = Chapter.today(now)
    if freq.day ~= today then
        -- 换天：整张表作废（调用方拿到的 freq 是旧的，这里只判不许，让调用方重置）
        return true, "new_day"
    end
    if type(freq.chapters) == "table" and freq.chapters[key] == today then
        return false, "already_asked_today"
    end
    if type(max_per_day) == "number" and max_per_day > 0
        and type(freq.count) == "number" and freq.count >= max_per_day then
        return false, "quota_exhausted"
    end
    return true, "ok"
end

--[[--
记一次"已经弹过"（同一章一天只记一次）。
@return bool 这次是不是真的记上了（重复记返回 false，调用方别重复写盘）
--]]
function Chapter.markAuto(freq, key, now)
    if type(freq) ~= "table" then return false end
    if type(key) ~= "string" or key == "" then return false end
    local today = Chapter.today(now)
    if freq.day ~= today then
        freq.day = today
        freq.count = 0
        freq.chapters = {}
    end
    if type(freq.chapters) ~= "table" then freq.chapters = {} end
    if freq.chapters[key] == today then return false end
    freq.chapters[key] = today
    freq.count = (type(freq.count) == "number" and freq.count or 0) + 1
    return true
end

return Chapter
