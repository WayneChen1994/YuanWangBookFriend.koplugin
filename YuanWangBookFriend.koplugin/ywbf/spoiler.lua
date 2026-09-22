--[[--
防剧透（PRD 第四章 F4.1–F4.5）纯逻辑层。

设计要点：
1. 本模块不依赖任何 KOReader UI，可在本机/设备 luajit 直接单测。
   进度适配层 readProgress() 只对传入的 table 做**鸭子类型探测**（方法存在才调用，
   且一律 pcall 包裹），因此单测里可以塞一个假 ui 进来。
2. 真正的"章节内容隔离"靠**不送未读文本**实现。插件本来就只取当前页上下文，
   天然不含未读章节，所以这里管的是三条真实泄漏路径：
   a. 上下文窗口的后文段跨过了本章结尾，把下一章开头带进 payload；
   b. 缓存/多轮历史里存着之前在后面章节查过的内容（或用户粘贴的后面章节原文）；
   c. 模型用训练记忆里的全书知识作答 —— 靠 system + user 双保险 prompt 约束。
3. 一切取值都用 pcall 防御：拿不到进度就退化成"不声明进度、不截断"，绝不阻塞提问。
4. 三种粒度：
   · chapter（默认，精确）：按未读章节标题 / 章节号在文本里定位截断点；
   · percent（粗粒度，可选）：按全书进度比例限制"向前看"的文本量。
     只对**后文段**生效——用户的问题、选中内容、多轮历史绝不被比例截断，
     否则"这句话什么意思"在 30% 进度下会被切掉 70%，那是灾难。
   · collection（合集）：一本 epub 里含多部独立作品时（如《十本书读懂阿加莎》），
     用户**不会从头读到尾**，而是直接跳到其中某一部去读。此时按阅读进度判断，
     前面那些部会被误判成"已读"——但用户根本没读过它们。所以合集粒度下
     "未读"= 当前在读的那一部之外的**所有其余各部**（不论在其之前还是之后）
     + 当前这一部里当前位置之后的章节。
5. 合集粒度产出的标记与 chapter 粒度**同一条出口**（prog.unread_titles /
   prog.unread_tokens → Spoiler.markerList），截断、guardMessages、回答预警、
   提问拦截四条消费路径不用改一行就全部生效。绝不为合集新开一条只覆盖截断的
   旁路（M3 的 P0 事故就是"某条路径漏用标记"）。
--]]--

local Config = require("ywbf/config")
local Util = require("ywbf/util")

local Spoiler = {}

Spoiler.GRANULARITY_CHAPTER = "chapter"
Spoiler.GRANULARITY_PERCENT = "percent"
Spoiler.GRANULARITY_COLLECTION = "collection"

-- 「本书是合集」开关的三种取值（设置项 spoiler_collection）
Spoiler.COLLECTION_AUTO = "auto"
Spoiler.COLLECTION_ON = "on"
Spoiler.COLLECTION_OFF = "off"

--[[--
合集**自动检测**的阈值（做成常量，改判定不用翻代码，单测也直接引用）：

· COLLECTION_MIN_WORKS：一级条目少于 3 个不可能是合集（1 个是单本，2 个是上下册
  这种"读完上才有下"的结构，跳读需求不明显）。
· COLLECTION_HEADING_RATIO：一级标题里「第 X 章/篇/卷/部」这类**自带序号的章节式
  标题**占比达到该值时，判定为单本书的卷篇结构而非合集 —— 跳到"第二卷"去读的人，
  不代表第一卷没读过。
--]]
Spoiler.COLLECTION_MIN_WORKS = 3
Spoiler.COLLECTION_HEADING_RATIO = 0.5

--[[--
部标题（作品名）**免边界**的字符数门槛。

部标题是"整部作品的专有名字"（《东方快车谋杀案》），用户想聊的恰恰是作品本身，
漏放（被剧透）的代价远大于误伤（某段上下文被多剪一点），所以长的部标题句中出现
即命中，不看前后是不是标点/换行。但短标题（「茶馆」「雷雨」）放宽会满篇误命中，
所以低于这个长度仍走原来的边界规则。
**只作用于部标题**：章节标题沿用原逻辑，一个字都不动。
--]]
Spoiler.WORK_TITLE_MIN_LEN = 4

-- 前向声明：真正的定义在下面的「文本截断」段（合集判定要用它排除卷篇结构）
local isChapterHeading

--[[--
无目录（拿不到章节边界）时的后文硬上限。

书没有可用目录时，"当前读到百分之几"只能估算每一句话是否已读 —— 不是隔离，
只是缩小暴露窗口。这里在百分比预算之上再压一道绝对上限：无论进度多高，
向前看的文本最多保留这么多字符（约两三句话），而不是整个 800 字窗口。
--]]
Spoiler.AUTO_FALLBACK_MAX_CHARS = 120

-- 明显在问"后面会发生什么"的问法：命中就走模糊话术（省一次请求）
local RISK_PATTERNS = {
    "结局", "最后怎么样", "最后如何", "最终", "后来呢", "之后呢",
    "凶手是谁", "谁是凶手", "犯人是谁", "真凶",
    "死了吗", "会不会死", "最后死", "谁死了",
    "为什么后来", "后面剧情", "后续剧情", "后面的情节",
    "剧透", "提前告诉", "直接告诉",
}

-- 用户可见的模糊回应：问到了未读内容（F4.3 话术）
Spoiler.REFUSAL = "这部分内容在后续章节中才会揭示，先卖个关子——继续读下去会更有意思。"

-- AI 回答里出现了未读内容时的标准化替换文案（PRD F4.4 原文）
Spoiler.WARNING = "这部分内容在后续章节中有所揭示，建议继续阅读。"

-- 「第 N 章」判定为已读时的容差：最后一章附近不再预警
Spoiler.END_CHAPTER_SLACK = 0

-- 中文数字（支持到 999）
local CN_DIGITS = {
    ["零"] = 0, ["一"] = 1, ["二"] = 2, ["三"] = 3, ["四"] = 4,
    ["五"] = 5, ["六"] = 6, ["七"] = 7, ["八"] = 8, ["九"] = 9, ["两"] = 2,
}
local CN_UNITS = { ["十"] = 10, ["百"] = 100 }

-- 标题匹配时允许的"前一个字符"：这些 CJK 标点说明后头是个新句子/新标题
local CJK_PUNCT = {
    ["\227\128\130"] = true, -- 。U+3002
    ["\227\128\129"] = true, -- 、U+3001
    ["\239\188\140"] = true, -- ，U+FF0C
    ["\239\188\155"] = true, -- ；U+FF1B
    ["\239\188\154"] = true, -- ：U+FF1A
    ["\239\188\129"] = true, -- ！U+FF01
    ["\239\188\159"] = true, -- ？U+FF1F
    ["\227\128\140"] = true, -- 「U+300C
    ["\227\128\141"] = true, -- 」U+300D
    ["\227\128\142"] = true, -- 『U+300E
    ["\227\128\143"] = true, -- 』U+300F
    ["\227\128\138"] = true, -- 《U+300A
    ["\227\128\139"] = true, -- 》U+300B
    ["\227\128\144"] = true, -- 【U+3010
    ["\227\128\145"] = true, -- 】U+3011
    ["\226\128\156"] = true, -- “U+201C
    ["\226\128\157"] = true, -- ”U+201D
    ["\239\188\136"] = true, -- （U+FF08
    ["\239\188\137"] = true, -- ）U+FF09
    ["\227\128\128"] = true, -- 　U+3000 全角空格
}

-- ---------------- 进度换算 ----------------

--[[--
计算阅读进度百分比。
@number page 当前页/位置
@number total 总页数
@return number|nil 0–100，拿不到数据返回 nil
--]]
function Spoiler.percent(page, total)
    if type(page) ~= "number" or type(total) ~= "number" then return nil end
    if total <= 0 then return nil end
    local p = page / total * 100
    if p < 0 then p = 0 end
    if p > 100 then p = 100 end
    return p
end

--[[--
按百分比粒度判断是否"已读"。
@number cur 当前进度百分比
@number target 目标位置百分比
@number buffer 容差（默认 5），防止同页内被判为未读
--]]
function Spoiler.isReadByPercent(cur, target, buffer)
    if type(cur) ~= "number" or type(target) ~= "number" then return true end
    buffer = buffer or 5
    return target <= cur + buffer
end

-- ---------------- 目录（TOC）处理 ----------------

-- 目录条目标题净化：去不可见字符、折叠空白、去首尾空格
function Spoiler.cleanTitle(title)
    if type(title) ~= "string" then return "" end
    return Util.trim(Util.collapseWhitespace(Util.sanitizeForDisplay(title)))
end

-- 太短的/纯数字的标题拿来做匹配会误伤，先筛掉
function Spoiler.isUsableTitle(title)
    if type(title) ~= "string" then return false end
    local t = Spoiler.cleanTitle(title)
    if Util.utf8len(t) < 2 then return false end
    if t:match("^[%d%s%.%-%_]+$") then return false end
    return true
end

-- 目录里最浅的层级（有的书 depth 从 0 开始，有的从 1 开始）
local function minDepth(toc)
    local m = nil
    for _, e in ipairs(toc) do
        if type(e) == "table" and type(e.depth) == "number" then
            if m == nil or e.depth < m then m = e.depth end
        end
    end
    return m
end

--[[--
取出所有"一级章节"在 toc 里的下标（用于算第 N/M 章）。
@return { idx, idx, ... }（升序）
--]]
function Spoiler.topLevelIndices(toc)
    local out = {}
    if type(toc) ~= "table" then return out end
    local m = minDepth(toc)
    for i, e in ipairs(toc) do
        if type(e) == "table" then
            if m == nil or e.depth == m then out[#out + 1] = i end
        end
    end
    if #out == 0 then
        -- 目录没有 depth 信息：整份目录都当一级章节
        for i = 1, #toc do out[i] = i end
    end
    return out
end

--[[--
在目录里定位当前所属章节。
@param toc 目录数组：{ {title=string, page=number, depth=number}, ... }，按 page 升序
@number page 当前页
@bool whole_chapter true=归到该条目所在的一级章节（按 depth 最浅往上找）
@return idx(number), entry(table) 找不到返回 nil, nil
--]]
function Spoiler.locateChapter(toc, page, whole_chapter)
    if type(toc) ~= "table" or type(page) ~= "number" then return nil, nil end
    -- 不 break：KOReader 自己的 validateAndFixToc 也承认引擎偶尔会给出非单调递增的
    -- 目录页码，提前 break 会在这种书上定位错章。改为扫描全表取"页码 ≤ 当前页"的最大者。
    local idx, best_page = nil, nil
    for i, e in ipairs(toc) do
        if type(e) == "table" and type(e.page) == "number" and e.page <= page then
            if best_page == nil or e.page >= best_page then
                idx, best_page = i, e.page
            end
        end
    end
    if not idx then return nil, nil end
    if whole_chapter then
        -- 往上找最近的一级章节（depth 最浅者）
        local top = Spoiler.topLevelIndices(toc)
        local best = nil
        for _, ti in ipairs(top) do
            if ti <= idx then best = ti end
        end
        if best then idx = best end
    end
    return idx, toc[idx]
end

--[[--
算出当前是第几章 / 共几章 / 章节名。
@param toc 目录
@number page 当前页
@return { index=number|nil, total=number|nil, title=string|nil, raw_index=number|nil }
--]]
function Spoiler.chapterInfo(toc, page)
    local empty = { index = nil, total = nil, title = nil, raw_index = nil }
    if type(toc) ~= "table" or type(page) ~= "number" then return empty end
    local raw_idx, entry = Spoiler.locateChapter(toc, page, true)
    if not raw_idx or not entry then return empty end
    local top = Spoiler.topLevelIndices(toc)
    local ordinal = nil
    for i, ti in ipairs(top) do
        if ti == raw_idx then ordinal = i end
    end
    if ordinal == nil then ordinal = raw_idx end
    return {
        index = ordinal,
        total = (#top > 0) and #top or #toc,
        title = Spoiler.cleanTitle(entry.title),
        raw_index = raw_idx,
    }
end

--[[--
算出当前所在的**最细粒度**章节（回目级）。

为什么不能直接拿 `chapterInfo` 的结果给收藏列表用：它刻意走**粗**粒度
（`locateChapter` 的第三个参数传 true），会把当前页往上归到最近的一级目录条目。
这个选择对防剧透是对的——未读判定要按一级部/卷收口，粒度太细会漏掉
"同一部里后面的那些回"。但《红楼梦》的目录是「上 / 中 / 下」套「第 N 回 回目名」
两层，粗粒度下第 19 回和第 25 回会一起归到一级条目「红楼梦 上」，
收藏列表里两章就被并成一章了（真机反馈：两条不同回的收藏显示成同一个章节行）。

所以**另开一套**，原来的那一套一行都不动。两处的序号**不是同一个序号空间**：
这里的 ordinal 在**同一 depth 的条目里数**（depth 缺失就把整份目录当同一层），
`chapterInfo` 的 index 是一级条目里的序号，两者不许互相套用、不许互相覆盖。

@param toc 目录
@number page 当前页
@return { index=number|nil, total=number|nil, title=string|nil }
--]]
function Spoiler.fineChapterInfo(toc, page)
    local empty = { index = nil, total = nil, title = nil }
    if type(toc) ~= "table" or type(page) ~= "number" then return empty end
    -- 第三个参数 false：**不**往上归，取包含当前页的最细那条目录
    local idx, entry = Spoiler.locateChapter(toc, page, false)
    if not idx or type(entry) ~= "table" then return empty end

    local my_depth = type(entry.depth) == "number" and entry.depth or nil
    local ordinal, same_level = nil, 0
    for _i, e in ipairs(toc) do
        if type(e) == "table" then
            local d = type(e.depth) == "number" and e.depth or nil
            if d == my_depth then
                same_level = same_level + 1
                if _i == idx then ordinal = same_level end
            end
        end
    end
    if same_level == 0 then
        -- 整份目录都没有 depth：退化成"目录里的第几条就是第几章"
        ordinal, same_level = idx, #toc
    end

    local title = Spoiler.cleanTitle(entry.title)
    return {
        index = ordinal,
        total = (same_level > 0) and same_level or nil,
        title = (title ~= "") and title or nil,
    }
end

--[[--
收集"还没读到的章节"的标题（用于文本截断与回答预警）。
@param toc 目录（升序）
@number chapter_index 当前一级章节序号（1-based）
@return { title, title, ... }
--]]
function Spoiler.unreadTitles(toc, chapter_index)
    local out = {}
    if type(toc) ~= "table" or type(chapter_index) ~= "number" then return out end
    local m = minDepth(toc)
    local ordinal = 0
    for _, e in ipairs(toc) do
        if type(e) == "table" then
            if m == nil or e.depth == m then ordinal = ordinal + 1 end
            if ordinal > chapter_index then
                local t = Spoiler.cleanTitle(e.title)
                if Spoiler.isUsableTitle(t) then out[#out + 1] = t end
            end
        end
    end
    return out
end

--[[--
收集"还没读到的章节"的**序号片段**（如从「第九章 雪夜其九」抽出「第九章」）。

真实 EPUB 的目录标题常带副标题，而正文里往往只写序号。只用整条标题匹配会漏，
所以把抽出来的序号短写法作为附加标记，与整条标题并行匹配。
（单独放一个字段，不改 unreadTitles，避免改变"未读章节数"这类计数语义。）
--]]
function Spoiler.unreadTokens(toc, chapter_index)
    local out, seen = {}, {}
    if type(toc) ~= "table" or type(chapter_index) ~= "number" then return out end
    local m = minDepth(toc)
    local ordinal = 0
    for _, e in ipairs(toc) do
        if type(e) == "table" then
            if m == nil or e.depth == m then ordinal = ordinal + 1 end
            if ordinal > chapter_index then
                for _, tok in ipairs(Spoiler.extractChapterTokens(e.title)) do
                    local t = Spoiler.cleanTitle(tok)
                    if Spoiler.isUsableTitle(t) and not seen[t] then
                        seen[t] = true
                        out[#out + 1] = t
                    end
                end
            end
        end
    end
    return out
end

--[[--
未读标记表 = 整条目录标题 + 标题里抽出的序号短写法（去重后合并）。
所有需要"找未读章节标记"的地方都必须经过这里，保证两种写法都被覆盖。
--]]
function Spoiler.markerList(prog)
    local out, seen = {}, {}
    local function add_list(list)
        if type(list) ~= "table" then return end
        for _, t in ipairs(list) do
            if type(t) == "string" and t ~= "" and not seen[t] then
                seen[t] = true
                out[#out + 1] = t
            end
        end
    end
    if type(prog) == "table" then
        add_list(prog.unread_titles)
        add_list(prog.unread_tokens)
        -- 兜底：调用方只给了 toc + index 时，现算一份
        if #out == 0 and type(prog.toc) == "table" and type(prog.chapter_index) == "number" then
            add_list(Spoiler.unreadTitles(prog.toc, prog.chapter_index))
            add_list(Spoiler.unreadTokens(prog.toc, prog.chapter_index))
        end
    end
    return out
end

--[[--
需要**放宽边界**（句中出现即命中）的标记集合：长的部标题。
与 markerList 同一条出口的配套产物：只认 prog.unread_work_titles（部标题），
章节标题一律不放宽 —— 章节标题那条规则已经调过一轮，不能跟着动。
@return { [title] = true, ... }
--]]
function Spoiler.relaxedMarkers(prog)
    local out = {}
    if type(prog) ~= "table" then return out end
    for _, t in ipairs(prog.unread_work_titles or {}) do
        if type(t) == "string" and t ~= ""
            and Util.utf8len(t) >= Spoiler.WORK_TITLE_MIN_LEN then
            out[t] = true
        end
    end
    return out
end

-- ---------------- 合集（collection 粒度） ----------------

--[[--
"一部作品" = 目录里**层级最浅**的条目（与一级章节同一套判定：minDepth）。
合集的目录形如《罗杰疑案》→ 章 → 章 → 《无人生还》→ 章 …，最浅的那层就是作品名。
@return { { index=toc 下标, title=净化后标题, page=number|nil }, ... }（按目录顺序）
--]]
function Spoiler.workEntries(toc)
    local out = {}
    if type(toc) ~= "table" then return out end
    for _, i in ipairs(Spoiler.topLevelIndices(toc)) do
        local e = toc[i] or {}
        out[#out + 1] = {
            index = i,
            title = Spoiler.cleanTitle(e.title),
            page = (type(e.page) == "number") and e.page or nil,
        }
    end
    return out
end

-- 是否存在比最浅层级更深的条目（= 作品内还有章节，不是平铺的章节列表）
function Spoiler.hasNestedEntries(toc)
    if type(toc) ~= "table" then return false end
    local m = minDepth(toc)
    if m == nil then return false end
    for _, e in ipairs(toc) do
        if type(e) == "table" and type(e.depth) == "number" and e.depth > m then
            return true
        end
    end
    return false
end

--[[--
自动检测"这本书**可能**是合集"（可单独单测）。

三条**同时**成立才判为合集：
  1. 一级条目数 >= COLLECTION_MIN_WORKS（3）；
  2. 存在更深层级条目 —— 平铺目录（30 个「第 X 章」）是单本小说的章节列表，
     不是"N 部作品"，缺这条必然把普通小说误判成合集；
  3. 一级标题不大多是「第 X 章/篇/卷/部」这类序号式标题 —— 那是单本书的卷篇结构。

第 2、3 条是防误判的核心：只按"一级条目数 >= 3"猜，任何一本超过三章的小说都会中招。
--]]
function Spoiler.isCollection(toc)
    local works = Spoiler.workEntries(toc)
    if #works < Spoiler.COLLECTION_MIN_WORKS then return false end
    if not Spoiler.hasNestedEntries(toc) then return false end
    local heading = 0
    for _, w in ipairs(works) do
        if isChapterHeading(w.title) then heading = heading + 1 end
    end
    if #works > 0 and (heading / #works) >= Spoiler.COLLECTION_HEADING_RATIO then
        return false
    end
    return true
end

--[[--
把"本书是合集"开关 + 目录实况解析成最终是否按合集隔离。
@param setting "auto" | "on" | "off"（nil/其它值一律按 auto）
@param toc 目录（可为 nil）
@return bool
--]]
function Spoiler.resolveCollectionMode(setting, toc)
    if setting == Spoiler.COLLECTION_OFF then return false end
    if setting == Spoiler.COLLECTION_ON then
        -- 手动开：目录至少能分出两"部"才有隔离意义，否则降级（单部书隔不出东西）
        return #Spoiler.workEntries(toc) >= 2
    end
    return Spoiler.isCollection(toc)
end

--[[--
当前位置属于第几部。
@return ordinal(number|nil) 1-based 部序号, toc_index(number|nil) 该部在 toc 里的下标
--]]
function Spoiler.currentWork(toc, page)
    if type(toc) ~= "table" or type(page) ~= "number" then return nil, nil end
    local idx = Spoiler.locateChapter(toc, page, true)
    if not idx then return nil, nil end
    local ordinal = nil
    for i, ti in ipairs(Spoiler.topLevelIndices(toc)) do
        if ti == idx then ordinal = i end
    end
    return ordinal or idx, idx
end

--[[--
当前部的 { index, total, title }。
--]]
function Spoiler.collectionInfo(toc, page)
    local empty = { index = nil, total = nil, title = nil }
    if type(toc) ~= "table" or type(page) ~= "number" then return empty end
    local total = #Spoiler.workEntries(toc)
    local ordinal, idx = Spoiler.currentWork(toc, page)
    -- 还在封面/序时 index 为 nil，但"共几部"仍然要报得出来
    if not ordinal or not idx or not toc[idx] then
        return { index = nil, total = total, title = nil }
    end
    return {
        index = ordinal,
        total = total,
        title = Spoiler.cleanTitle(toc[idx].title),
    }
end

--[[--
合集粒度下的"未读条目"（内部用）。
返回 nil 有两种含义：入参非法，或**还在封面/序**（一部都没开始读）——
后者由调用方回落到 unreadTitles(toc, 0)，即全部算未读。

规则：
  · 其它部：只取那一部的**一级标题**（不取它的子章节 —— 各部都从「第一章」开始，
    把子章节也当标记会在正文里到处误命中「第一章」这种通用词）；
  · 当前部：当前位置之后的章节。
--]]
local function collectionUnreadEntries(toc, page)
    if type(toc) ~= "table" or type(page) ~= "number" then return nil end
    local _, my_idx = Spoiler.currentWork(toc, page)
    if not my_idx then return nil end
    local is_work = {}
    for _, i in ipairs(Spoiler.topLevelIndices(toc)) do is_work[i] = true end
    local out = {}
    local cur_work = nil
    for i, e in ipairs(toc) do
        if type(e) == "table" then
            if is_work[i] then cur_work = i end
            local add = false
            if cur_work ~= my_idx then
                add = (i == cur_work)
            elseif type(e.page) == "number" then
                add = (e.page > page)
            else
                add = (i > my_idx)
            end
            if add then out[#out + 1] = e end
        end
    end
    return out
end

--[[--
合集粒度下的**部标题**（作品名）集合：当前部之外其余各部的标题。
是 collectionUnreadTitles 的子集，单独留一份是为了让这些"整部作品的名字"
能在匹配时放宽边界（见 WORK_TITLE_MIN_LEN）。
--]]
function Spoiler.collectionWorkTitles(toc, page)
    local out = {}
    if type(toc) ~= "table" then return out end
    local _, my_idx = Spoiler.currentWork(toc, page)
    for _, w in ipairs(Spoiler.workEntries(toc)) do
        -- my_idx 为 nil = 还在封面/序，一部都没读，此时各部标题全算
        if (my_idx == nil or w.index ~= my_idx) and Spoiler.isUsableTitle(w.title) then
            out[#out + 1] = w.title
        end
    end
    return out
end

--[[--
合集粒度的未读**标题**集合：其余各部的标题 + 当前部内当前位置之后的章节标题。
--]]
function Spoiler.collectionUnreadTitles(toc, page)
    local entries = collectionUnreadEntries(toc, page)
    if entries == nil then
        -- 还在封面/序：一部都没开始读 → 全部算未读（与 chapter 粒度的 P1-1 行为一致）
        return Spoiler.unreadTitles(toc, 0)
    end
    local out = {}
    for _, e in ipairs(entries) do
        local t = Spoiler.cleanTitle(e.title)
        if Spoiler.isUsableTitle(t) then out[#out + 1] = t end
    end
    return out
end

--[[--
合集粒度的未读**序号短写法**（如从「第二章 孤岛之夜」抽出「第二章」）。
与 collectionUnreadTitles 并行喂给 markerList。
--]]
function Spoiler.collectionUnreadTokens(toc, page)
    local entries = collectionUnreadEntries(toc, page)
    if entries == nil then return Spoiler.unreadTokens(toc, 0) end
    local out, seen = {}, {}
    for _, e in ipairs(entries) do
        for _, tok in ipairs(Spoiler.extractChapterTokens(e.title)) do
            local t = Spoiler.cleanTitle(tok)
            if Spoiler.isUsableTitle(t) and not seen[t] then
                seen[t] = true
                out[#out + 1] = t
            end
        end
    end
    return out
end

-- ---------------- 进度读取适配层（T3.1） ----------------

--[[--
从 KOReader 的 ui 对象里读阅读进度（EPUB 与 PDF 两条路都走一遍，取可用的）。
真机接口（已在 KPW4 / KOReader v2026.07.2 上 grep 确认）：
  · ui.document:getPageCount()      -> Document:getPageCount()（读 info.number_of_pages）
  · ui.document:getCurrentPage()    -> CreDocument:getCurrentPage()（滚动文档 = crengine 页码）
  · ui.paging.current_page          -> ReaderPaging 的当前页（PDF/分页文档）
  · ui.document:getXPointer()       -> 当前 xpointer（EPUB 精确定位）
  · ui.document:getToc()            -> { {title, page, depth, xpointer}, ... }
  · ui.document.info.has_pages      -> true 表示分页文档（PDF/DjVu/CBZ）
全部 pcall 包裹：任何一步失败都只是少一个字段，绝不抛错、绝不阻塞提问。

@param ui KOReader 的 ReaderUI 实例（单测里可传任意 table）
@param cfg 可选 { enabled=bool, granularity="chapter"|"percent"|"collection",
                  collection="auto"|"on"|"off" }
@return prog table，字段见下（拿不到的为 nil）
--]]
function Spoiler.readProgress(ui, cfg)
    local p = {
        ok = false,
        enabled = true,
        granularity = Spoiler.GRANULARITY_CHAPTER,
        collection_setting = Spoiler.COLLECTION_AUTO,
        collection_detected = false,
        collection_active = false,
        work_index = nil,
        work_total = nil,
        work_title = nil,
        source = nil,
        page = nil,
        total = nil,
        percent = nil,
        xpointer = nil,
        has_pages = false,
        chapter = nil,
        chapter_index = nil,
        chapter_total = nil,
        -- 细粒度章节（回目级）：只给收藏列表 / 详情页展示用，
        -- 防剧透的未读判定一律只用上面那三个粗粒度字段。
        chapter_fine = nil,
        chapter_fine_index = nil,
        toc = nil,
        unread_titles = nil,
    }
    if type(cfg) == "table" then
        p.enabled = (cfg.enabled ~= false)
        if cfg.granularity == Spoiler.GRANULARITY_PERCENT then
            p.granularity = Spoiler.GRANULARITY_PERCENT
        elseif cfg.granularity == Spoiler.GRANULARITY_CHAPTER then
            p.granularity = Spoiler.GRANULARITY_CHAPTER
        elseif cfg.granularity == Spoiler.GRANULARITY_COLLECTION then
            p.granularity = Spoiler.GRANULARITY_COLLECTION
        end
        if cfg.collection == Spoiler.COLLECTION_ON
            or cfg.collection == Spoiler.COLLECTION_OFF
            or cfg.collection == Spoiler.COLLECTION_AUTO then
            p.collection_setting = cfg.collection
        end
    end

    if type(ui) ~= "table" then return p end
    local doc = ui.document
    if type(doc) ~= "table" then return p end

    if type(doc.info) == "table" then
        p.has_pages = (doc.info.has_pages == true)
    end

    -- 1) 总页数
    local total = nil
    if type(doc.getPageCount) == "function" then
        local okc, v = pcall(doc.getPageCount, doc)
        if okc and type(v) == "number" and v > 0 then total = v end
    end
    if total == nil and type(doc.info) == "table" and type(doc.info.number_of_pages) == "number"
        and doc.info.number_of_pages > 0 then
        total = doc.info.number_of_pages
    end
    p.total = total

    -- 2) 当前位置：PDF 走 ui.paging.current_page，EPUB 走 doc:getCurrentPage()
    local page = nil
    if type(ui.paging) == "table" and type(ui.paging.current_page) == "number"
        and ui.paging.current_page > 0 then
        page = ui.paging.current_page
        p.source = "paging"
    end
    if page == nil and type(doc.getCurrentPage) == "function" then
        local okp, v = pcall(doc.getCurrentPage, doc)
        if okp and type(v) == "number" and v > 0 then
            page = v
            p.source = p.source or "rolling"
        end
    end
    p.page = page
    p.percent = Spoiler.percent(page, total)

    -- 3) EPUB 精确锚点（供上层按需使用，也用作"有没有在读书"的判据）
    if type(doc.getXPointer) == "function" then
        local okx, xp = pcall(doc.getXPointer, doc)
        if okx and type(xp) == "string" and xp ~= "" then p.xpointer = xp end
    end

    -- 4) 目录 → 章节序号
    local toc = nil
    if type(doc.getToc) == "function" then
        local okt, t = pcall(doc.getToc, doc)
        if okt and type(t) == "table" and #t > 0 then toc = t end
    end
    p.toc = toc

    -- 没有目录但有百分比时，**自动回落到百分比粒度**。
    -- 章节粒度全靠目录定位，无目录时它会完全空转（只是嘴上说"不许剧透"），
    -- 所以还不如让百分比截断真的把后面的文字剪短。设置页会把这次回落显示给用户。
    -- 合集粒度同样靠"一级条目"定位，无目录时一样得回落（降级要求 3）。
    if toc == nil and type(p.percent) == "number"
        and (p.granularity == Spoiler.GRANULARITY_CHAPTER
             or p.granularity == Spoiler.GRANULARITY_COLLECTION) then
        p.granularity = Spoiler.GRANULARITY_PERCENT
        p.granularity_auto = true
    end

    if toc then
        p.collection_detected = Spoiler.isCollection(toc)
    end

    --[[--
    是否按合集隔离：**开关**与**粒度**共同决定。
      · 开关关 → 一律不隔离（用户明确说"不是合集"，粒度选了也不生效）；
      · 粒度 percent → 不隔离（用户主动选了粗粒度，合集标记属于精确标记体系）；
      · 其余情况看开关解析结果（auto = 自动检测，on = 强制隔离）。
    注意：粒度 chapter + 开关 auto 时，检测出合集**照样隔离** —— 默认粒度就是
    chapter，若要求必须显式选 collection 才生效，默认配置下的合集书就完全没有防护。
    --]]
    if toc and p.granularity ~= Spoiler.GRANULARITY_PERCENT then
        p.collection_active =
            Spoiler.resolveCollectionMode(p.collection_setting, toc)
    end

    if toc and page then
        local ci = Spoiler.chapterInfo(toc, page)
        p.chapter_index = ci.index
        p.chapter_total = ci.total
        p.chapter = ci.title
        --[[--
        细粒度章节：与上面的粗粒度**同时**算出来一起带走。

        两件事必须同时成立，缺一个就会再出一次真机 bug：
          · 收藏列表要的是回目级（"第 19 回"而不是"红楼梦 上"）；
          · 防剧透用的仍是粗粒度那三个字段，这里**不覆盖**它们。
        拿不到（还在封面/序，或目录缺 depth 但页码早于首条）就是 nil，由调用方兜底。
        --]]
        local fi = Spoiler.fineChapterInfo(toc, page)
        p.chapter_fine = fi.title
        p.chapter_fine_index = fi.index
        if not ci.index then
            -- 页码早于首个目录条目（还在封面/序/前言）：此时**所有**章节都还没读到。
            -- 以前这里什么防护都不做，等于书开头零防护（P1）。
            -- 合集同理：一部都还没开始读，parts 全部算未读。
            local all = Spoiler.unreadTitles(toc, 0)
            if #all > 0 then
                local top = Spoiler.topLevelIndices(toc)
                p.chapter_total = (#top > 0) and #top or #toc
                p.chapter_index = 0          -- 0 = 还没进第 1 章
                p.chapter = nil
                p.unread_titles = all
                p.unread_tokens = Spoiler.unreadTokens(toc, 0)
                if p.collection_active then
                    p.work_total = #Spoiler.workEntries(toc)
                    p.work_index = 0         -- 0 = 还没进第 1 部
                    p.work_title = nil
                    p.unread_work_titles = Spoiler.collectionWorkTitles(toc, page)
                end
            end
        elseif p.collection_active then
            local wi = Spoiler.collectionInfo(toc, page)
            p.work_index, p.work_total, p.work_title = wi.index, wi.total, wi.title
            p.unread_titles = Spoiler.collectionUnreadTitles(toc, page)
            p.unread_tokens = Spoiler.collectionUnreadTokens(toc, page)
            -- 部标题单独留一份：匹配时可放宽边界（见 WORK_TITLE_MIN_LEN）
            p.unread_work_titles = Spoiler.collectionWorkTitles(toc, page)
        else
            p.unread_titles = Spoiler.unreadTitles(toc, ci.index)
            p.unread_tokens = Spoiler.unreadTokens(toc, ci.index)
        end
    end

    p.ok = (p.percent ~= nil) or (p.chapter_index ~= nil)
    return p
end

--[[--
从 Config 读防剧透配置（给未显式传 cfg 的调用方用）。
@return { enabled=bool, granularity=string, collection="auto"|"on"|"off" }
--]]
function Spoiler.currentConfig()
    local enabled = true
    local granularity = Spoiler.GRANULARITY_CHAPTER
    local collection = Spoiler.COLLECTION_AUTO
    if type(Config) == "table" and type(Config.get) == "function" and Config.settings ~= nil then
        local v = Config:get("spoiler_guard")
        if v ~= nil then enabled = (v == true) end
        local g = Config:get("spoiler_granularity")
        if g == Spoiler.GRANULARITY_PERCENT then
            granularity = Spoiler.GRANULARITY_PERCENT
        elseif g == Spoiler.GRANULARITY_COLLECTION then
            granularity = Spoiler.GRANULARITY_COLLECTION
        end
        local c = Config:get("spoiler_collection")
        if c == Spoiler.COLLECTION_ON or c == Spoiler.COLLECTION_OFF
            or c == Spoiler.COLLECTION_AUTO then
            collection = c
        end
    end
    return { enabled = enabled, granularity = granularity, collection = collection }
end

--[[--
把 cfg 合并进 prog，返回一份新的 prog（不改动入参）。

优先级：**cfg（用户在设置页的全局开关）最高**。
理由：这是安全开关，宁可被"全局开启"覆盖成开启，也不能被某次调用里的
片断数据关掉。所以 prog.enabled=false 遇到 cfg.enabled=true 会被改写回 true，
这是刻意为之（QA 记为 GAP-F，我们不改语义，只在此注明）。
粒度同理：没有目录时 readProgress 已把 chapter 自动回落成 percent，
此时 cfg 若显式给了合法粒度则尊重 cfg，否则沿用 prog 的回落结果。
--]]
function Spoiler.withConfig(prog, cfg)
    local out = {}
    if type(prog) == "table" then
        for k, v in pairs(prog) do out[k] = v end
    end
    if type(cfg) == "table" then
        if cfg.enabled ~= nil then out.enabled = (cfg.enabled == true) end
        if cfg.granularity == Spoiler.GRANULARITY_PERCENT
            or cfg.granularity == Spoiler.GRANULARITY_CHAPTER
            or cfg.granularity == Spoiler.GRANULARITY_COLLECTION then
            -- 自动回落的 percent 不应被空的/默认的 chapter 覆盖回去
            if not out.granularity_auto then
                out.granularity = cfg.granularity
            end
        end
        if cfg.collection == Spoiler.COLLECTION_ON
            or cfg.collection == Spoiler.COLLECTION_OFF
            or cfg.collection == Spoiler.COLLECTION_AUTO then
            out.collection_setting = cfg.collection
        end
    end
    if out.enabled == nil then out.enabled = true end
    if out.granularity == nil then out.granularity = Spoiler.GRANULARITY_CHAPTER end
    return out
end

--[[--
给设置页展示用的一句话进度描述。
--]]
function Spoiler.progressLabel(prog)
    if type(prog) ~= "table" then return "未识别到阅读进度" end
    local parts = {}
    -- 合集：第 N / M 部（work_index == 0 表示还没进第 1 部，不展示）
    if type(prog.work_index) == "number" and prog.work_index >= 1
        and type(prog.work_total) == "number" then
        parts[#parts + 1] = string.format("第 %d / %d 部", prog.work_index, prog.work_total)
        if type(prog.work_title) == "string" and prog.work_title ~= "" then
            parts[#parts + 1] = "（" .. prog.work_title .. "）"
        end
    end
    -- chapter_index == 0 表示"还没进第 1 章"（页码早于首个目录条目），不当作第 0 章展示
    if type(prog.chapter_index) == "number" and prog.chapter_index >= 1
        and type(prog.chapter_total) == "number" then
        parts[#parts + 1] = string.format("第 %d / %d 章", prog.chapter_index, prog.chapter_total)
        if type(prog.chapter) == "string" and prog.chapter ~= "" then
            parts[#parts + 1] = "（" .. prog.chapter .. "）"
        end
    end
    if type(prog.percent) == "number" then
        parts[#parts + 1] = string.format("%.0f%%", prog.percent)
    end
    if #parts == 0 then return "未识别到阅读进度" end
    return table.concat(parts, " ")
end

-- ---------------- 文本截断（T3.2） ----------------

-- 「第 X 章 / 节 / 回 / 篇 / 卷 / 部」这类自带序号的目录标题
local HEADING_TAILS = {
    ["章"] = true, ["节"] = true, ["回"] = true,
    ["篇"] = true, ["卷"] = true, ["部"] = true,
}

--[[--
判断标题是否是"自带章节序号"的标题（如「第七章」「第 12 回」）。
这类标题在正文里几乎不会作为普通词出现，因此可以把命中边界放宽到句中。
按字符步进，避免中英混排标题按 3 字节硬切出错。
--]]
-- 注意：这里用 `function` 而不是 `local function` —— 顶部已前向声明，
-- 合集判定（isCollection）要复用它排除「卷/篇」式单本结构。
function isChapterHeading(title)
    if type(title) ~= "string" then return false end
    if Util.utf8len(title) < 2 then return false end
    if title:sub(1, 3) ~= "第" then return false end
    local pos, len, guard = 4, #title, 0
    while pos <= len and guard < 8 do
        local b = string.byte(title, pos)
        local step = 1
        if b >= 0xF0 then      step = 4
        elseif b >= 0xE0 then  step = 3
        elseif b >= 0xC0 then  step = 2 end
        if HEADING_TAILS[title:sub(pos, pos + step - 1)] then return true end
        pos = pos + step
        guard = guard + 1
    end
    return false
end

--[[--
判断 pos 处是否处于"边界"：行首，或前一个字符是空白/标点。
中文 3 字节，只看最后一个字节判断是不是 ASCII 空白/标点；
多字节的情况查 CJK 标点表（避免把"某某大结局"这种连续文本当成标题）。
自带序号的章节标题例外（见 isChapterHeading）。
--]]
local function isBoundary(text, pos)
    if pos <= 1 then return true end
    local one = text:sub(pos - 1, pos - 1)
    if one == "\n" or one == "\r" then return true end
    if one:match("[%s%p]") then return true end
    if pos >= 4 then
        local three = text:sub(pos - 3, pos - 1)
        if CJK_PUNCT[three] then return true end
    end
    return false
end

--[[--
在 text 里找最早出现的未读章节标题。
@param relaxed_set 可选 { [title]=true }：这些标题不要求落在边界上（句中即命中）。
                  只对"长的部标题"开放，见 Spoiler.relaxedMarkers。
@return pos(number|nil), title(string|nil)
--]]
function Spoiler.findMarker(text, titles, relaxed_set)
    if type(text) ~= "string" or type(titles) ~= "table" then return nil, nil end
    local best_pos, best_title = nil, nil
    for _, t in ipairs(titles) do
        if type(t) == "string" and t ~= "" then
            local relaxed = isChapterHeading(t)
                or (type(relaxed_set) == "table" and relaxed_set[t] == true)
            local i = 1
            while true do
                local f = text:find(t, i, true)
                if not f then break end
                -- 普通标题要求落在句子/行的边界上；自带序号的章节标题放宽到句中
                if relaxed or isBoundary(text, f) then
                    if best_pos == nil or f < best_pos then
                        best_pos, best_title = f, t
                    end
                    break
                end
                i = f + 1
            end
        end
    end
    return best_pos, best_title
end

-- 按字符数安全截断，优先落在句号/换行处
local function cutAt(text, keep_chars)
    if keep_chars <= 0 then return "" end
    local cut = Util.utf8sub(text, keep_chars)
    local last_end = 0
    for _, pat in ipairs({ "。", "！", "？", "\n", "；", "，" }) do
        local idx_end, i = nil, 1
        while true do
            local f = cut:find(pat, i, true)
            if not f then break end
            idx_end = f + #pat - 1
            i = idx_end + 1
        end
        if idx_end and idx_end > last_end then last_end = idx_end end
    end
    if last_end > #cut * 0.5 then return cut:sub(1, last_end) end
    return cut
end

--[[--
截断引擎核心：把一段文本裁掉"未读部分"。
@param text 待发送文本
@param prog 进度（含 enabled / granularity / percent / unread_titles）
@param opts 可选 { markers_only = bool }
       markers_only=true 时无论粒度都只按章节标题标记截断
       （多轮历史与用户问题只吃这条精确规则，绝不被百分比比例切碎）
@return out(string), info({ truncated=bool, reason=string, cut_at=number, marker=string })
--]]
function Spoiler.truncate(text, prog, opts)
    opts = opts or {}
    prog = prog or {}
    local info = { truncated = false, reason = "none", cut_at = nil, marker = nil }

    if type(text) ~= "string" or text == "" then
        info.reason = "empty"
        return text, info
    end
    if prog.enabled == false then
        info.reason = "disabled"
        return text, info
    end

    local granularity = prog.granularity or Spoiler.GRANULARITY_CHAPTER

    -- 粗粒度：按全书进度比例限制文本长度（只对"向前看"的文本用）
    if granularity == Spoiler.GRANULARITY_PERCENT and not opts.markers_only then
        local pct = prog.percent
        if type(pct) ~= "number" then
            info.reason = "no_percent"
            return text, info
        end
        if pct >= 100 then
            info.reason = "finished"
            return text, info
        end
        local n = Util.utf8len(text)
        local keep = math.floor(n * Util.clamp(pct / 100, 0, 1) + 0.5)
        -- 无目录场景（自动回落）：百分比只是估算，再压一道绝对上限收紧暴露窗口
        if prog.granularity_auto == true and keep > Spoiler.AUTO_FALLBACK_MAX_CHARS then
            keep = Spoiler.AUTO_FALLBACK_MAX_CHARS
        end
        if keep >= n then
            info.reason = "within"
            return text, info
        end
        local out = cutAt(text, keep)
        info.truncated = true
        info.reason = "percent"
        info.cut_at = Util.utf8len(out)
        return out, info
    end

    -- 精确粒度：按未读章节标题定位截断点（整条标题 + 标题里的序号短写法）
    local titles = Spoiler.markerList(prog)
    if #titles > 0 then
        local pos, title = Spoiler.findMarker(text, titles, Spoiler.relaxedMarkers(prog))
        if pos then
            local out = (pos > 1) and text:sub(1, pos - 1) or ""
            info.truncated = true
            info.reason = "chapter"
            info.cut_at = Util.utf8len(out)
            info.marker = title
            return out, info
        end
        info.reason = "no_marker"
        return text, info
    end

    info.reason = "no_toc"
    return text, info
end

--[[--
截断上下文窗口。
只有 after（选中位置之后）可能越过阅读位置；before 与 selected 在光标之前，
必然已读，原样保留 —— 否则释义/摘要功能会被无谓削弱。
@param win { before, selected, after }
@param prog 进度
@return win(table), info(table)
--]]
function Spoiler.truncateWindow(win, prog)
    local info = { truncated = false, reason = "none", cut_at = nil, marker = nil }
    if type(win) ~= "table" then return win, info end
    if type(prog) ~= "table" or prog.enabled == false then
        info.reason = "disabled"
        return win, info
    end
    if type(win.after) ~= "string" or win.after == "" then
        info.reason = "empty"
        return win, info
    end
    local cut, ti = Spoiler.truncate(win.after, prog)
    if ti.truncated then
        return { before = win.before, selected = win.selected, after = cut }, ti
    end
    return win, ti
end

--[[--
把所有待发送消息过一遍截断（多轮历史 / 用户粘贴的原文都在这里被剪）。
只按章节标题标记精确截断，不做比例裁剪。
@return messages(table), info({ changed=bool, hits=number })
--]]
function Spoiler.guardMessages(messages, prog)
    local info = { changed = false, hits = 0 }
    if type(messages) ~= "table" then return messages, info end
    if type(prog) ~= "table" or prog.enabled == false then
        info.reason = "disabled"
        return messages, info
    end
    local titles = Spoiler.markerList(prog)
    if #titles == 0 then
        info.reason = "no_toc"
        return messages, info
    end

    local out = {}
    for _, m in ipairs(messages) do
        if type(m) == "table" and type(m.content) == "string" then
            local cut, ti = Spoiler.truncate(m.content, prog, { markers_only = true })
            if ti.truncated then
                local nm = { role = m.role, content = cut }
                for k, v in pairs(m) do
                    if k ~= "role" and k ~= "content" then nm[k] = v end
                end
                out[#out + 1] = nm
                info.changed = true
                info.hits = info.hits + 1
            else
                out[#out + 1] = m
            end
        else
            out[#out + 1] = m
        end
    end
    return out, info
end

-- ---------------- 剧透预警（T3.4） ----------------

--[[--
解析章节序号：支持阿拉伯数字与中文数字（一 ~ 九百九十九）。
@return number|nil
--]]
function Spoiler.parseChapterNumber(s)
    if type(s) ~= "string" then return nil end
    s = Util.trim(s)
    if s == "" then return nil end
    if s:match("^%d+$") then return tonumber(s) end

    local total, cur, seen = 0, 0, false
    local i, n = 1, #s
    while i <= n do
        local three = s:sub(i, i + 2)
        local d = CN_DIGITS[three]
        if d then
            cur = d
            seen = true
            i = i + 3
        else
            local u = CN_UNITS[three]
            if u then
                if cur == 0 then cur = 1 end
                total = total + cur * u
                cur = 0
                seen = true
                i = i + 3
            else
                return nil  -- 混进了非数字字符，交给调用方忽略
            end
        end
    end
    if not seen then return nil end
    return total + cur
end

--[[--
抽出文本里所有「第 X 章/节/回/篇/卷」的**原文片段**（保留写法）。
例："详见第 12 章与第十三回" → { "第 12 章", "第十三回" }
@return { token, ... }
--]]
function Spoiler.extractChapterTokens(text)
    local out = {}
    if type(text) ~= "string" then return out end
    local n = #text
    local i = 1
    while i <= n do
        local f = text:find("第", i, true)
        if not f then break end
        local j, has_num = f + 3, false
        while j <= n do
            local three = text:sub(j, j + 2)
            if CN_DIGITS[three] or CN_UNITS[three] then
                has_num = true
                j = j + 3
            else
                local one = text:sub(j, j)
                if one:match("%d") then
                    has_num = true
                    j = j + 1
                elseif one == " " or one == "\t" then
                    j = j + 1
                else
                    break
                end
            end
        end
        local tail = text:sub(j, j + 2)
        -- HEADING_TAILS 里的单元词都是 3 字节 CJK，直接取 3 字节即可
        if has_num and HEADING_TAILS[tail] then
            out[#out + 1] = text:sub(f, j + 2)
        end
        i = f + 3
    end
    return out
end

--[[--
抽出文本里所有「第 X 章/节/回/篇/卷」的序号。
@return { number, ... }
--]]
function Spoiler.extractChapterNumbers(text)
    local out = {}
    for _, tok in ipairs(Spoiler.extractChapterTokens(text)) do
        -- 掐掉首尾的「第」与单元词（各 3 字节），中间交给 parseChapterNumber 去解析
        local v = Spoiler.parseChapterNumber(tok:sub(4, -4))
        if v then out[#out + 1] = v end
    end
    return out
end

--[[--
扫描 AI 回答：出现未读章节标题 / 未读章节号 → 整段替换为标准化模糊提示。
纯本地正则 + 目录表，不额外消耗 API 调用。
@return text(string), hit(bool), reason(string|nil)
--]]
function Spoiler.scanAnswer(answer, prog)
    if type(answer) ~= "string" or answer == "" then return answer, false, nil end
    if type(prog) ~= "table" or prog.enabled == false then return answer, false, nil end

    -- 1) 命中未读章节标题（含标题里的序号短写法）
    local titles = Spoiler.markerList(prog)
    if #titles > 0 then
        local pos, title = Spoiler.findMarker(answer, titles, Spoiler.relaxedMarkers(prog))
        if pos then
            return Spoiler.WARNING, true, "title:" .. tostring(title)
        end
    end

    -- 2) 命中未读章节号（"第 12 章…"）
    if type(prog.chapter_index) == "number" then
        local limit = prog.chapter_index - Spoiler.END_CHAPTER_SLACK
        for _, num in ipairs(Spoiler.extractChapterNumbers(answer)) do
            if num > limit then
                return Spoiler.WARNING, true, "chapno:" .. tostring(num)
            end
        end
    end

    return answer, false, nil
end

--[[--
统一的回答出口：过一遍剧透预警。
@return text(string), hit(bool), reason(string|nil)
--]]
function Spoiler.sanitizeAnswer(answer, prog)
    return Spoiler.scanAnswer(answer, prog)
end

-- ---------------- prompt 注入与统一入口 ----------------

--[[--
生成注入 system 的防剧透说明（PRD F4.2 进度感知 + F4.3 章节隔离 + F4.4 预警）。
@param p {enabled=bool, granularity=string, book=string, chapter=string,
          chapter_index=number, chapter_total=number, percent=number, buffer=number,
          work_index=number, work_total=number, work_title=string（合集，可选）}
@return string 空串表示不注入
--]]
function Spoiler.buildNote(p)
    p = p or {}
    if p.enabled == false then return "" end

    local lines = {}
    lines[#lines + 1] = "【防剧透约束（最高优先级）】"

    -- 合集：声明"当前在读第几部"，并明确其余各部**不论前后**都算未读
    if type(p.work_index) == "number" and p.work_index >= 1
        and type(p.work_total) == "number" then
        local where = p.work_title and ("（" .. p.work_title .. "）") or ""
        lines[#lines + 1] = string.format(
            "· 这是一本合集，用户当前读到第 %d / %d 部%s", p.work_index, p.work_total, where)
        lines[#lines + 1] = "· 除当前这一部之外，其余各部**不论排在它前面还是后面**都算未读，"
            .. "不许引用、推断或暗示其中的情节、人物命运、结局与反转"
    elseif p.granularity == Spoiler.GRANULARITY_PERCENT and type(p.percent) == "number" then
        lines[#lines + 1] = string.format(
            "· 用户当前读到全书 %.0f%%，只许基于已读范围作答", p.percent)
    elseif type(p.chapter_index) == "number" and p.chapter_index >= 1
        and type(p.chapter_total) == "number" then
        local where = p.chapter and ("（" .. p.chapter .. "）") or ""
        lines[#lines + 1] = string.format(
            "· 用户当前读到第 %d / %d 章%s，只许基于已读范围作答",
            p.chapter_index, p.chapter_total, where)
    elseif type(p.percent) == "number" then
        lines[#lines + 1] = string.format(
            "· 用户当前读到全书 %.0f%%，只许基于已读范围作答", p.percent)
    end

    lines[#lines + 1] = "· 你拿到的原文已在用户阅读位置处截断，截断点之后的原文你没有看到，"
        .. "也不许引用、推断或暗示其中的情节、人物命运、结局与反转"
    lines[#lines + 1] = "· 你即使知道全书内容，也必须当作不知道"
    lines[#lines + 1] = "· 若用户的问题涉及未读内容，不要直接回答，"
        .. "改用这句模糊提示：" .. Spoiler.REFUSAL
    lines[#lines + 1] = "· 若你的回答不得不涉及未读内容，改用这句提示：" .. Spoiler.WARNING
    lines[#lines + 1] = "· 回答中可以分析已读部分的写法、人物动机与主题"

    return table.concat(lines, "\n")
end

--[[--
判断用户提问是否明显指向未读内容（命中就先在本地拦一道，省一次请求）。
@string question
@return bool
--]]
function Spoiler.detectRisk(question)
    if Util.isEmpty(question) then return false end
    for _, pat in ipairs(RISK_PATTERNS) do
        if question:find(pat, 1, true) then return true end
    end
    return false
end

--[[--
统一入口：决定是否拦截、以及要注入的 system 说明。
@param cfg {enabled=bool, granularity=string, buffer=number}（来自 Config）
@param prog {page=number, total=number, chapter=string,
             chapter_index=number, chapter_total=number, percent=number}
@string question 用户问题（可空）
@return blocked(bool), note(string), refusal(string|nil)
--]]
function Spoiler.evaluate(cfg, prog, question)
    cfg = cfg or {}
    prog = prog or {}
    if cfg.enabled == false then return false, "", nil end
    if prog.enabled == false then return false, "", nil end

    local percent = prog.percent
    if percent == nil then
        percent = Spoiler.percent(prog.page, prog.total)
    end

    local note = Spoiler.buildNote({
        enabled = true,
        granularity = prog.granularity or cfg.granularity,
        buffer = cfg.buffer,
        book = prog.book,
        chapter = prog.chapter,
        chapter_index = prog.chapter_index,
        chapter_total = prog.chapter_total,
        percent = percent,
        work_index = prog.work_index,
        work_total = prog.work_total,
        work_title = prog.work_title,
        collection_active = prog.collection_active,
    })

    -- 用户在提问里直接引用了未读章节的标题/原文。
    -- 这里在**提问入口**整句回模糊话术，而不是等到出口把 user 消息切掉半句
    -- （那会让模型收到残缺指令）。
    local markers = Spoiler.markerList(prog)
    if not Util.isEmpty(question) and #markers > 0 then
        if Spoiler.findMarker(question, markers, Spoiler.relaxedMarkers(prog)) then
            return true, note, Spoiler.REFUSAL
        end
    end

    -- 进度完全拿不到时**不阻塞**（只靠 prompt 约束），避免退化场景挡住正常提问
    local known = (type(percent) == "number")
        or (type(prog.chapter_index) == "number" and type(prog.chapter_total) == "number")
    if not known then return false, note, nil end

    -- 本地硬拦：明显问后续剧情，且确实还没读到接近结尾
    if Spoiler.detectRisk(question) then
        local near_end = false
        if type(percent) == "number" and percent >= 92 then near_end = true end
        if type(prog.chapter_index) == "number" and type(prog.chapter_total) == "number"
            and prog.chapter_total > 0
            and prog.chapter_index >= prog.chapter_total then
            near_end = true
        end
        if not near_end then return true, note, Spoiler.REFUSAL end
    end

    return false, note, nil
end

return Spoiler
