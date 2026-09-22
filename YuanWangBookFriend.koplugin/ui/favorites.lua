--[[--
「我的问答收藏」：按书回顾收藏过的问答，并支持跨书检索。

设计上的三条硬约束：

1. **收藏不是一份新文件**。它就是 history 条目上的一个 `favorite` 字段
   （理由写在 ywbf/store.lua 开头）。所以本文件不持有任何数据，全部现读 Store。
2. **问答成对展示**。收藏的是 assistant 那一条，提问由 Store:questionFor 带出来
   （先读条目自带的 question 字段，读不到再按 turn_id 回查同轮 user 条目）。
   列表里一个问答只出现一次——把 user 那一条也列进来只会显得重复。
3. **列表项摘要必须按字符截**（Util.preview / Util.utf8sub）：中文 3 字节，
   裸 string.sub 会切在汉字中间变乱码。

列表用 KOReader 的 Menu：分页、滚动、返回手势都是现成的，自己拼一个反而要重新踩一遍。
跨书列表按书名排序让同一本的行相邻，**每一行都必须点得动**（曾因分组标题行不可点
被反馈"点了没反应"）。
--]]--

local BookMeta = require("ywbf/bookmeta")
local Export = require("ywbf/export")
local Prompts = require("ywbf/prompts")
local Store = require("ywbf/store")
local Util = require("ywbf/util")

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

--[[--
分隔线（详情页分块用）。

**长度必须现算，不许写死**：屏幕从 600 到 1900px 都有，写死一个长度在别的机型上
会多出一个字符、被挤到下一行（真机踩过一次）。算不出来就退回一条短的兜底——
短的在任何屏上都铺得下，比"多出一行"强。

这几个 require 一律用 pcall 包住：本文件在设备上是被 KOReader 加载的，
但在无头 luajit 里单独跑验收脚本时 `ui/font` 这类模块拿不到，
直接 require 会让整个模块加载失败、后面所有断言跟着一起崩。
--]]
local ok_dev, Device = pcall(require, "device")
local ok_font, Font = pcall(require, "ui/font")
local ok_size, Size = pcall(require, "ui/size")
local ok_rt, RenderText = pcall(require, "ui/rendertext")

local SEP_CHAR = "—"
local SEP_FALLBACK = string.rep(SEP_CHAR, 12)

local function buildSeparator()
    local ok, sep = pcall(function()
        if not (ok_dev and ok_font and ok_size and ok_rt) then return SEP_FALLBACK end
        local screen = Device.screen
        if not screen or not screen.getWidth then return SEP_FALLBACK end

        local face = Font:getFace("x_smallinfofont")
        local unit = RenderText:sizeUtf8Text(0, nil, face, SEP_CHAR, true, false)
        if type(unit) ~= "table" or type(unit.x) ~= "number" or unit.x <= 0 then
            return SEP_FALLBACK
        end

        -- 可用宽打 96 折：按几何算出来的宽度比 TextBoxWidget 实际断行用的略大，
        -- 压满到 100% 换来的只是 1~2 个字符的观感，翻车的代价是多出一行，不值。
        local usable = (screen:getWidth() - screen:scaleBySize(30)
                       - 2 * Size.padding.large - 2 * Size.margin.small) * 0.96
        local measure = function(s)
            local m = RenderText:sizeUtf8Text(0, nil, face, s, true, false)
            return type(m) == "table" and m.x or 0
        end

        local s = Util.fillLine(usable, unit.x, SEP_CHAR, measure)
        if s == "" then return SEP_FALLBACK end
        return s
    end)
    if ok and type(sep) == "string" and sep ~= "" then return sep end
    return SEP_FALLBACK
end

local Favorites = {}

-- 列表项摘要里"提问"最多展示多少个字符
local SUMMARY_CHARS = 20

local function timePresetText(key)
    for _i, p in ipairs(Favorites.TIME_PRESETS) do
        if p.key == key then return _(p.text) end
    end
    return _(Favorites.TIME_PRESETS[1].text)
end

-- 风格显示名一律取自 Prompts.STYLES（唯一定义处），不在这里抄一份列表：
-- 抄了以后加一种风格就得记得改两个地方，而我们已经在别处吃过这个亏。
local function styleFilterText(key)
    if key == nil then return _("全部风格") end
    if key == Store.UNKNOWN_STYLE then return _("未知风格（老数据）") end
    return Prompts.styleText(key)
end

--[[--
收藏状态显示名。三档，与 Store:matchesFilters 的 `opts.favorite` 一一对应。

  true  = 仅已收藏（**默认**：用户说"我的问答收藏"，指的就是这些）
  false = 已取消收藏（曾经收藏、后来取消的；靠 unfavorited_at 墓碑识别）
  nil   = 不限（只剩「全部」这一档在用；检索页不走收藏状态，见 runSearch）
--]]
local function favFilterText(state)
    if state == true then return _("仅已收藏") end
    if state == false then return _("已取消收藏") end
    return _("全部")
end

--[[--
按当前「收藏状态」选列表来源。

三个视图只差"读哪一批行"，所以收在一处；判据本身留在 Store（listFavorites /
listUnfavorited / listAnswerRows），UI 这边不自己拼 `favorite == ...` 的谓词——
否则"什么算已取消收藏"就有了第二个定义处，两边迟早对不上。
--]]
local function sourceForState(state, scope_fp)
    if state == false then return Store:listUnfavorited(scope_fp) end
    if state == true then return Store:listFavorites(scope_fp) end
    return Store:listAnswerRows(scope_fp)
end

--[[--
列表标题。**跟着收藏状态变**：在「已取消收藏」视图里还写着「《X》的收藏」，
用户会以为这些是收藏着的（标题和内容自相矛盾，比没有标题更糟）。
--]]
local function listTitle(state, book_title)
    if state == false then
        return book_title and T(_("《%1》· 已取消收藏"), book_title) or _("已取消收藏")
    elseif state == nil then
        return book_title and T(_("《%1》· 全部问答"), book_title) or _("全部问答（含已取消）")
    end
    return book_title and T(_("《%1》的收藏"), book_title) or _("全部收藏")
end

--[[--
某个收藏档位下"一条都没有"时的提示。

**必须分档位**：默认档要说"还没收藏过"，已取消档才能说"没有取消过的"——说反了
用户会以为功能坏了（"本来就没有"和"被筛没了"是两回事）。
真机上见过一次反的：档位**残留**成「已取消收藏」（见 showBookFavorites 的注释），
于是打开「本书收藏」弹的是「没有『已取消收藏』的条目」，用户根本不知道自己
什么时候切过档，只看见一句莫名其妙的提示。

文案里不出现"AI"字样：跟用户说话的是这个插件（人设见 `Prompts.PERSONA_NAME`），
不该写成"AI 助手"之类把人设抹掉的说法。
--]]
local function emptyTextForState(state, title)
    if state == false then
        if title then
            return T(_("《%1》没有「已取消收藏」的条目。在收藏列表里取消掉的会出现在这里。"),
                title) -- luacheck: ignore
        end
        return _("没有「已取消收藏」的条目。在收藏列表里取消掉的问答会出现在这里。")
    end
    if state == nil then
        if title then return T(_("《%1》还没有任何问答。"), title) end -- luacheck: ignore
        return _("还没有任何问答。")
    end
    if title then
        return T(_("《%1》这本书还没有收藏。看到好的回答，在结果卡片上点「收藏」就会存到这里。"),
            title) -- luacheck: ignore
    end
    return _("还没有任何收藏。看到好的回答，在结果卡片上点「收藏」就会存到这里。")
end

--[[--
时间筛选预设。

**为什么是预设而不是日期选择器**：墨水屏上用模拟渲染的日历/滚轮选日期，
每动一格要重绘一次整屏，128 级灰阶下那个白闪闪的键盘简直没法对准，
而用户真实想要的只有"最近读的"和"再早一点"这两三档。

`days` 为 nil 表示不限；`since` 一律在打开列表那一刻按 `os.time()` 现算，
不存快照——存了以后"最近 7 天"就会随着旧快照一天天变宽。
--]]
Favorites.TIME_PRESETS = {
    { key = "all", text = "全部时间", days = nil },
    { key = "d7", text = "最近 7 天", days = 7 },
    { key = "d30", text = "最近 30 天", days = 30 },
}

-- 当前筛选条件（会话内保留：用户多半想连着看几屏）。
-- style == nil 表示不限；== Store.UNKNOWN_STYLE 表示专挑老数据（没有 style 字段的）。
--[[--
`favorite`：收藏状态，**默认 true = 仅已收藏**。

为什么默认不是 nil：这个列表叫「收藏」，默认就该只显示收藏的；把没收藏过的
也列出来会让"我的问答收藏"和"我的历史"混成一锅。想找取消掉的那条，用户在筛选里
选一下「已取消收藏」——那条通路正是这次要补的东西（见 showFilterMenu）。
--]]
Favorites.filter = { time = "all", style = nil, tag = nil, favorite = true }

--[[--
当前还开着的**收藏详情页**（TextViewer）。列表整体关闭时（右上角 X）要把它一并关掉，
否则重建过的列表一关，底下那张详情页就露出来了（真机反馈，见 showList 里的注释）。

只在"详情页被 show 出来"和"列表被关掉"两处读写；不复用、不跨列表传递。

**同一时刻只许有一张**（真机 A）：在默认档里按「取消收藏」时详情页是**故意留在屏上**
的（给用户一次手滑撤销的机会，见 showEntry 里那段注释）。于是它成了"还开着但已经
不被列表需要"的一张；用户接着从列表点开**另一条**时，若不先把它收走，它就变成孤儿：
登记表只认最后开的那张，X 关列表时关掉的是登记的那张，底下这张孤儿没人关，
列表一关它就露出来——用户原话"又回显了一次之前打开过的一条收藏问答的详情界面"。
--]]
Favorites.open_entry_viewer = nil

--[==[
注销"当前还开着的详情页"。

为什么必须有这个函数（真机 A）：详情页自己被关掉的每一条路径（「关闭」按钮、
「恢复收藏」的自动关闭、删除）都只 `UIManager:close(viewer)`，登记表里那条引用
**不会自己消失**。留着它会变成一个**悬空引用**：X 关列表时去 close 一个早就关掉的
对象，而"还开着的"判定又依赖这个引用——真正在屏上的那张反而没人认领。

传 v：只有登记表里存的正是这一张才清（后来的详情页已经顶掉了就别误清）。
传 nil：无条件清空（"我现在就是要把它忘掉"）。
@return boolean 是否真的注销了一个
--]==]
function Favorites:unregisterEntryViewer(v)
    if v == nil then
        Favorites.open_entry_viewer = nil
        return true
    end
    if Favorites.open_entry_viewer == v then
        Favorites.open_entry_viewer = nil
        return true
    end
    return false
end

--[==[
开一张新详情页之前，先把还开着的那张**关掉并注销**（真机 A）。

不关的后果见上面 `open_entry_viewer` 字段的注释：取消收藏时留在屏上那张会变成孤儿。
这里收走它，同一时刻就只会有一张详情页，X 关列表时关掉的一定是屏上那张。
@return boolean 是否真的收走了一张
--]==]
function Favorites:closeOpenEntryViewers()
    local v = Favorites.open_entry_viewer
    Favorites.open_entry_viewer = nil
    if v then UIManager:close(v) end
    return v ~= nil
end

--[[--
把一段长文本收成摘要（按字符边界，绝不用裸 string.sub）。
@return string
--]]
local function brief(s, n)
    if type(s) ~= "string" or s == "" then return "" end
    local txt, _total, truncated = Util.preview(Util.collapseWhitespace(s), n or SUMMARY_CHARS)
    return truncated and (txt .. "…") or txt
end

--[[--
这一行的"章节身份"该用哪一套字段。

两套并存是刻意的：

  · `chapter_fine_*`（回目级）是现在写进去的那套 —— 第 19 回就是第 19 回；
  · `chapter_title` / `chapter_index`（一级部卷级）是**老数据里唯一的一对**，
    而它们是防剧透那套**粗粒度**结果（《红楼梦》的目录是「上/中/下」套回目，
    粗粒度会把第 19 回和第 25 回一起归到「红楼梦 上」，于是两条不同回的收藏
    显示成同一个章节行 —— 真机反馈的 Bug 2）。

规则：**细粒度优先；细粒度两个都缺才回落到粗粒度。**
"细粒度只缺一半"也按细粒度算（缺的那一项当 nil），绝不用粗粒度的另一半去补齐：
那会造出"第 19 回 + 红楼梦 上"这样的混血身份，同一本书里两种 key 混着出现，
分组当场错乱，而且比一直错更难查。

@return number|nil index, string|nil title
--]]
local function fineChapter(row)
    if type(row) ~= "table" then return nil, nil end
    local fi = type(row.chapter_fine_index) == "number" and row.chapter_fine_index or nil
    local ft = type(row.chapter_fine_title) == "string" and row.chapter_fine_title ~= ""
        and row.chapter_fine_title or nil
    if fi ~= nil or ft ~= nil then return fi, ft end
    local ci = type(row.chapter_index) == "number" and row.chapter_index or nil
    local ct = type(row.chapter_title) == "string" and row.chapter_title ~= ""
        and row.chapter_title or nil
    return ci, ct
end

--[[--
这个标题**自己带不带序号**？（「第十九回 …」「第 一 回 …」这种）

带了就别再套一层 `第 N 章` —— 否则显示成「第 2 章 第十九回 情切切良宵花解语」，
「第2章」和「第十九回」自相矛盾，跟用户抱怨的「第2章 红楼梦 上」一样糟。
真机反馈要的是**回目名本身**，不是再编一层号。

判断里**不许用 `[回章]` 这种字节类**：「回」「章」都是 3 字节，字节类等价于
"首字节落在某集合"，会把一堆不相干的汉字也匹配进来（本项目踩过三次）。
一律用 `find(x, 1, true)` 的**纯文本**查找。

**已知边界（故意不做，不是漏了）**：同一本书里若有两条**回目名完全相同**的章节
（OCR 目录 / 重排本才会出现），去掉 `第 N 章` 前缀之后，这两行会**长得一模一样**。
分组不会并错——分组 key 里有 index 参与，两条仍然是两个章节；单纯是行文字相同，
用户看不出它们是两个。要消掉它，就得让本函数知道"这本书里还有没有同名的另一章"，
那是往一个纯判定函数里塞书级上下文，代价和收益不成比例，故按已知边界留存。
**写下这条是为了不让它变成以后没人知道的暗坑。**

@return boolean
--]]
local CHAPTER_ORDINALS = { "回", "章", "篇", "卷", "节", "讲", "折" }

local function titleHasOwnOrdinal(title)
    if type(title) ~= "string" or title == "" then return false end
    if Util.utf8sub(title, 1) ~= "第" then return false end
    local head = Util.utf8sub(title, 8)
    for _i, w in ipairs(CHAPTER_ORDINALS) do
        if head:find(w, 1, true) then return true end
    end
    return false
end

--[[--
位置标签：「第 3 章 章节名」/「章节名」/「第 42 页」/ 都没有就给空串。
老数据没有章节字段，也不要硬凑一个"未知位置"占位——没有就是没有。

章节身份一律经 `fineChapter` 取（回目级优先）：详情页和扁平列表跟折叠列表
必须用同一套口径，否则列表是对的、点进去还是「红楼梦 上」，用户会再报一次。
拿不到任何章节信息时**保留原来的兜底顺序**（退页码 → 空串），这里不改。
--]]
local function chapterLabel(row)
    if type(row) ~= "table" then return "" end
    local index, title = fineChapter(row)
    -- 标题自带序号（「第十九回 …」）就别再套 `第 N 章`，否则「第 2 章 第十九回」自相矛盾
    if title and titleHasOwnOrdinal(title) then return title end
    if title and index then
        return T(_("第 %1 章 %2"), tostring(index), title) -- luacheck: ignore
    end
    if title then return title end
    if type(row.page) == "number" then
        return T(_("第 %1 页"), tostring(row.page)) -- luacheck: ignore
    end
    return ""
end

--[[--
列表项的尾标：这条有没有备注 / 标签。

不加尾标的话，用户只能一条条点进去看哪条写过备注——他收藏了几十条的时候，
这件事就变成"整屏重看一遍"。
--]]
local function rowMarks(row)
    if type(row) ~= "table" then return "" end
    local parts = {}
    if type(row.note) == "string" and Util.trim(row.note) ~= "" then
        parts[#parts + 1] = _("注")
    end
    if type(row.tags) == "table" and #row.tags > 0 then
        for _i, t in ipairs(row.tags) do parts[#parts + 1] = t end
    end
    return table.concat(parts, "·")
end

--[[--
条目自己的那一段（提问摘要 + 备注/标签尾标），不含书名、不含章节。

单独抽出来是因为折叠列表里**条目行只显示这一段**：书名已经在书行上、
章节已经在章节行上，再重复一遍，一行里真正有用的那几个字就被挤没了。
--]]
local function entrySummary(row)
    if type(row) ~= "table" then return "" end
    local q = Store:questionFor(row.book_fp, row.index)
    local head = q ~= "" and brief(q) or brief(row.content)
    local marks = rowMarks(row)
    if marks ~= "" then return head .. "  [" .. marks .. "]" end
    return head
end

--[[--
列表项的一行摘要（完整版：书名 + 位置 + 条目）。
折叠列表里条目行不用它（用 entrySummary），搜索结果等扁平视图仍然用它。
--]]
function Favorites:rowText(row, show_group_title)
    if type(row) ~= "table" then return "" end
    local book = show_group_title and (Store:bookTitle(row.book_fp)) or nil
    local loc = chapterLabel(row)
    local parts = {}
    if book then parts[#parts + 1] = book end
    if loc ~= "" then parts[#parts + 1] = loc end
    local prefix = table.concat(parts, " · ")
    local core = (prefix ~= "") and (prefix .. " — " .. entrySummary(row)) or entrySummary(row)
    return core
end

--[[--
章节身份。`index` 与 `title` **一起**构成身份。

只用其中一个都不行：有些书的章节名是"第一章/第二章"这样带序号的（此时 index 冗余），
另一些书的章节名会重复（不同章同名），只用 title 就会把两章并成一章。

用哪一套字段由 `fineChapter` 决定（回目级优先、老数据回落到一级部卷级），
**两套的序号不许混在同一个 key 里**——《红楼梦》粗粒度下第 19、25 回都归到
「红楼梦 上」，若让它们与回目级序号共处一个 key 空间，不同层级的"第 2 章"
会被合并成一个分组（Bug 2 的成因）。
--]]
local function chapterKeyOf(row)
    if type(row) ~= "table" then return "" end
    local index, title = fineChapter(row)
    return tostring(index or "") .. "\1" .. tostring(title or "")
end

--[[--
章节行的标题。

没有章节信息的条目也要有一个筐把它们装起来：列表里每一行都必须点得动，
让条目直接散在书行下面等于退回扁平列表（用户就是嫌扁平才要折叠的）。

标题取 `fineChapter` 的结果（回目级优先，老数据回落到一级部卷级），
用户明确要的是"章节名称或回目名称也能显示出来"——只有"第 N 章"三个字
仍然分不清这一章讲的是什么。

回目名会很长（《红楼梦》「第十九回 皇恩重元妃省父母 天伦乐宝玉呈才藻」），
所以按字符截到 CHAPTER_TITLE_CHARS：一行放不下的话，后面的字会把折叠箭头挤出屏幕。
--]]
local CHAPTER_TITLE_CHARS = 24

local function chapterLabelOf(row)
    if type(row) ~= "table" then return _("未标注位置") end
    local index, title = fineChapter(row)
    if title then
        -- Util.preview 返回三个值（正文、原文长度、是否截断），只取第一个：
        -- 直接 return 的话后两个会顺着冒号调用一起漏出去。
        local clipped, _n_chars, was_cut = Util.preview(title, CHAPTER_TITLE_CHARS)
        if type(clipped) == "string" and clipped ~= "" then title = clipped end
        if was_cut == true then title = title .. "…" end
    end
    -- 标题自带序号（「第十九回 …」）就别再套 `第 N 章`，否则「第 2 章 第十九回」自相矛盾
    if title and titleHasOwnOrdinal(title) then return title end
    if index and title then
        return T(_("第 %1 章 %2"), tostring(index), title) -- luacheck: ignore
    end
    if title then return title end
    if index then
        return T(_("第 %1 章"), tostring(index)) -- luacheck: ignore
    end
    return _("未标注位置")
end

--[[--
详情界面元信息的来源：优先 books.json 里的记录（那里有作者/出版社/ISBN），
没有记录（老数据）就退回条目自带的 book_title 现认一遍。
--]]
local function bookMetaSource(row)
    local info = Store:bookInfo(row.book_fp)
    if type(info) == "table" then return info end
    --[[--
    两个来源都没有时兜底成"未知书"，**绝不能把 nil 交出去**。

    交出去的后果（真机反馈：详情页里书名显示成《nil》）：`BookMeta:metaLines` 收到
    非 table 会 `BookMeta:parse(x)` 一遍，parse 里 `simplify(title)` 对非字符串做的是
    `tostring(title)`（`ywbf/bookmeta.lua:528`），`tostring(nil)` 就是字符串 "nil"——
    于是 JSON 里"这个字段不存在"被原样印到了屏幕上。

    这里拦一次，屏幕上看到的就是"未知书"而不是语言的内部表示。
    （注：`simplify` 那条 non-string 分支本身是个还在的地雷，别的调用点传 nil 进去
    照样会印出 "nil"。本轮只修这条真实路径，改动 ywbf/bookmeta.lua 涉及 QA 那边
    一堆书名夹具，留给 team-lead 拍板。）
    --]]
    return (type(row.book_title) == "string" and row.book_title ~= "")
        and row.book_title or BookMeta.FALLBACK_TITLE
end

--[[--
一条收藏的完整文本（给 TextViewer）。

顺序按"回想一段问答时的自然顺序"：先说这是哪一本书、哪一章（定位），
再给当时的引文（上下文），然后是提问，最后是回答。
--]]
function Favorites:entryText(row)
    if type(row) ~= "table" then return "" end
    local lines = {}
    local sep = buildSeparator()

    --[[--
    每一块之间插一条分隔线。

    原来只靠换行分块，中文一整段连下来根本看不出边界——真机反馈"书名、引文、
    提问、回复挤到一块了"。块本身可能缺（没备注、没段落），所以分隔线只在**真的
    要往下加一块时**才加，末尾不会多出一条孤零零的线。
    --]]
    local function addBlock(heading, body)
        if #lines > 0 then lines[#lines + 1] = sep end
        lines[#lines + 1] = heading
        if body ~= nil then lines[#lines + 1] = body end
    end

    --[[--
    书籍元信息**分行**显示（真机反馈：书名、章节挤在一坨分不清）。

    一行一个字段，认不出的字段**整行不出现**（BookMeta:metaLines 保证）：
    屏幕上挂一个孤零零的"作者："比什么都不写更糟。
    --]]
    for _i, line in ipairs(BookMeta:metaLines(bookMetaSource(row))) do
        lines[#lines + 1] = line
    end

    -- 位置单独一块：它是"这条收藏在书的哪里"，和"这本书是什么"是两件事
    local loc = chapterLabel(row)
    if loc ~= "" then
        lines[#lines + 1] = sep
        lines[#lines + 1] = loc
    end

    if type(row.note) == "string" and Util.trim(row.note) ~= "" then
        addBlock(_("【我的备注】"), row.note)
    end

    if type(row.tags) == "table" and #row.tags > 0 then
        addBlock(T(_("【标签】%1"), table.concat(row.tags, "、")), nil) -- luacheck: ignore
    end

    --[[--
    引文**保留原文的段落结构**。

    为什么这里还要再过一次 `keepParagraphs` 而不是直接用 `row.selection`：
    历史里两种记录并存——
      · 新记录（深聊/轻问）从 `selected_kept` 写入，已经是规整过的；
      · 更早的记录存的是 `selected_clean`（`sanitizeForDisplay` 的产物，它的 `%c`
        **包含 `\n`**），**存进去时就没换行了**，这里再怎么也补不回来；
      · AI解释/AI摘要那一路（`main.lua`）存的是**原始**选中文本，epub 里为了排版
        塞的一大串空行会原样带进来。
    过一遍 `keepParagraphs` 三边统一：换行留着、连续 3 个以上换行压成 2 个、
    首尾空行去掉。老记录（本来就没换行）走它只是去掉首尾空白，**渲染结果不变**。

    **不截断**：这一段是"回顾"，不是摘要（`ywbf/export.lua` 同口径）。
    --]]
    if type(row.selection) == "string" and row.selection ~= "" then
        -- 外层再套一层 quoteBlock：详情页是**显示**，可以排好看；
        -- `row.selection` 与导出那一路都不动（导出 Markdown 有它自己的段落规矩）。
        addBlock(Prompts.QUOTE_LABEL, Util.quoteBlock(Util.keepParagraphs(row.selection)))
    end

    local q = Store:questionFor(row.book_fp, row.index)
    if q ~= "" then
        addBlock(_("【你的提问】"), q)
    end

    addBlock(T(_("【%1的回复】"), Prompts.PERSONA_NAME), row.content or "") -- luacheck: ignore

    return table.concat(lines, "\n")
end

--[[--
改备注。

两个 UI 上的硬约束：
1. **不能叠弹层**：输入框自带虚拟键盘，叠在详情页之上时，键盘会压住输入区，
   而上面那一层还关不掉（真机实测的症状）。所以调用方负责先关详情页再调这里。
2. 存完之后**把详情页还给用户**：他改完备注多半还要接着看这条回答，
   把他丢回列表等于让他再翻一次。

@param row table
@param on_changed function|nil 数据变了之后回调（列表页用它重画）
@param view_favorite bool|nil 当前列表的收藏状态（原样传回详情页，别把「恢复收藏」掉成「收藏」）
--]]
function Favorites:askNote(row, on_changed, view_favorite)
    if type(row) ~= "table" then return end
    local dialog
    dialog = InputDialog:new{
        title = _("备注"),
        description = _("记在这条收藏上的想法，导出时会一起带走。留空再保存即清除备注。"),
        input = Store:noteOf(row.book_fp, row.index) or "",
        input_hint = _("备注"),
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
                        local text = dialog:getInputText()
                        UIManager:close(dialog)
                        local saved = Store:setNote(row.book_fp, row.index, text)
                        UIManager:show(InfoMessage:new{
                            text = saved and _("备注已保存") or _("保存失败，这条记录可能已经不在历史里了"),
                        })
                        if saved and on_changed then on_changed() end
                        self:showEntry(row, on_changed, view_favorite)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--[[--
改标签。逗号分隔，**中文逗号和英文逗号都认**（输入法默认给全角，
让用户为了填标签去切输入法等于这个功能一半人用不了）。
去重、去空白、丢空串都交给 Store:setTags。
--]]
function Favorites:askTags(row, on_changed, view_favorite)
    if type(row) ~= "table" then return end
    local dialog
    dialog = InputDialog:new{
        title = _("标签"),
        description = _("多个标签用逗号分隔（中英文逗号都行）。留空再保存即清除标签。"),
        input = table.concat(Store:tagsOf(row.book_fp, row.index), "，"),
        input_hint = _("例如：伏笔，人物"),
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
                        local text = dialog:getInputText()
                        UIManager:close(dialog)
                        local saved = Store:setTags(row.book_fp, row.index, text)
                        UIManager:show(InfoMessage:new{
                            text = saved and _("标签已保存") or _("保存失败，这条记录可能已经不在历史里了"),
                        })
                        if saved and on_changed then on_changed() end
                        self:showEntry(row, on_changed, view_favorite)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--[[--
单条收藏的详情页。底部给「备注 / 标签 / 收藏开关 / 删除 / 关闭」。

@param row table
@param on_changed function|nil 收藏状态或条目本身变了之后回调（列表页用它重画）
@param view_favorite bool|nil 当前列表的「收藏状态」筛选（true/false/nil）：
       在「已取消收藏」这个视图里，按钮应当写「恢复收藏」而不是「收藏」
--]]
--[[--
列表项的统一入口：包一层 pcall，失败也要**看得见**。

"点了没反应"是最难排查的一类反馈——用户分不清是没点着、是数据没了、还是代码抛了异常。
这里把异常兜住并原样显示出来，至少让"点了"这件事有回执。
--]]
function Favorites:showEntrySafe(row, on_changed, view_favorite)
    local ok, err = pcall(function() self:showEntry(row, on_changed, view_favorite) end)
    if not ok then
        logger.warn("YWBF: showEntry failed: " .. tostring(err))
        UIManager:show(InfoMessage:new{
            text = T(_("打不开这条记录：%1"), tostring(err)), -- luacheck: ignore
        })
    end
end

function Favorites:showEntry(row, on_changed, view_favorite)
    if type(row) ~= "table" then return end
    local viewer

    local fav_id = "ywbf_fav_toggle"
    --[[--
    收藏状态在建卡时算**一次**就够。

    原来回调里还要再 `Store:isFavorite` 一次，而它是"整份 JSON 读进来"——
    真机实测：300KB 的历史文件上一次 ≈ 71ms，1MB ≈ 227ms（见
    `tools/eng_measure_io.lua` 的量表）。少一次整份读是实打实的减负。
    --]]
    local favored = Store:isFavorite(row.book_fp, row.index)

    --[[--
    在「已取消收藏」视图里，未收藏状态的动作叫**恢复收藏**，不叫「收藏」。

    同一个接口在两个视图里语义不同：默认视图点「收藏」是"把这条加进收藏"，
    而已取消视图里看到的那条本来就曾经是收藏，用户的心智是"把它放回去"。
    文案照实际语义写，别用一个「收藏」糊过去。
    --]]
    local function favLabel(is_fav)
        if is_fav then return _("取消收藏") end
        if view_favorite == false then return _("恢复收藏") end
        return _("收藏")
    end

    --[[--
    就地刷新按钮文字。

    两个坑都是踩出来的：
      1. `Button:setText(text)` **不传 width** 会走 `label_widget:free(); self:init()`
         把按钮重建一遍，而 KOReader 的按下/抬起反馈只把**按钮旧尺寸**那块区域
         排进刷新（`frontend/ui/widget/button.lua` 的 `_undoFeedbackHighlight`，
         波形还是 `fast`）。「收藏」→「取消收藏」变宽后，多出来的像素没人重绘 →
         墨水屏上就是残影。传 `width = 当前宽度` 走"只换文字、几何不动"那条分支。
      2. 换完文字必须**自己**排一次重绘，且不能用 `fast`（局部无闪波形正是留残影的刷法）。
    --]]
    local function refreshButtons()
        local btn = viewer and viewer.button_table and viewer.button_table:getButtonById(fav_id)
        if btn and btn.setText then
            btn:setText(favLabel(favored), btn.width)
        end
        -- 裸调，与 ui/asker.lua:refreshFavoriteButton 同口径：桩已补齐 setDirty，
        -- 判空是死分支（判空跳过时"有没有排重绘"就断言不出来了）。
        UIManager:setDirty(viewer, "ui")
    end

    viewer = TextViewer:new{
        title = _("收藏的问答"),
        text = self:entryText(row),
        buttons_table = {
            {
                {
                    id = fav_id,
                    text = favLabel(favored),
                    callback = function()
                        local now = Store:setFavorite(row.book_fp, row.index, not favored)
                        if now == nil then
                            UIManager:show(InfoMessage:new{
                                text = _("这条记录已经不在历史里了"),
                            })
                            return
                        end
                        favored = now
                        refreshButtons()
                        --[[--
                        提示要把**后果**说明白，不能只丢一个"已取消收藏"：

                          · 取消收藏 **不是** 删除 —— 它只是从默认列表里移走，去筛选里
                            选「已取消收藏」还能找回来。用户追问的那半句
                            （"取消收藏后怎么重新收藏"）就由这句话回答。
                          · 在「已取消收藏」视图里按下去是恢复，措辞跟着换。
                        --]]
                        local notice
                        if now then
                            notice = (view_favorite == false) and _("已恢复收藏") or _("已收藏")
                        else
                            notice = _("已移出收藏，可在筛选里选「已取消收藏」找回")
                        end
                        --[[--
                        先重画列表、**再**弹本次动作的提示（顺序不能反）。

                        `on_changed()` 重画时，如果这一屏正好被清空（比如刚把「已取消收藏」
                        里的最后一条恢复走），`showList` 会自己弹一条「没有『已取消收藏』的
                        条目」。提示若先弹，那条空列表提示就盖在它上面——正是项目规则 7
                        （不要在已打开的提示之上再叠一层）要避免的。

                        这条顺序在桩环境里是**可断言**的：桩 UIManager 没有"层级栈"这个
                        维度，堆叠本身测不出来，但**调用顺序**是可观测的（`info_log` 按
                        show 的先后记录），而 KOReader 后 show 的在上层——顺序是叠层的忠实
                        代理量。`tools/eng_check_ui_fix.lua` 的 4d 就用这条断言，把两行
                        换回去它就会红（U12 变异背书）。
                        （曾经写在这里的"无法在桩环境断言"是错的：混淆了"测不出 X"和
                        "测不出 X 的代理量"。）
                        --]]
                        if on_changed then on_changed() end
                        UIManager:show(InfoMessage:new{ text = notice })
                        --[[--
                        「恢复收藏」按完就把详情页**关掉**，把列表还给用户。

                        为什么必须关：这一按钮只有在「已取消收藏」这一屏里才写成「恢复收藏」
                        （见上面的 favLabel），而按完之后这一条就**不再属于这一屏**——
                        底下那份列表已经把它移走了。留着详情页等于让用户盯着一张
                        "屏幕上已经不存在的东西"的卡片，还得自己按「关闭」才能回去
                        （真机反馈：「没有回到收藏列表界面，要手动关掉详情窗口」）。

                        为什么只在这一格关、不推广到「取消收藏」：
                        在默认视图里按「取消收藏」之后片子留在屏上，是为了让用户能当场再按一下
                        变成「收藏」（手滑取消时的撤销方式）；而「恢复收藏」是这个视图里
                        一件事的终点——做完就该回到列表，没有要在原地接着做的事。
                        --]]
                        if view_favorite == false and now == true then
                            UIManager:close(viewer)
                            -- 同上：这条自动关闭的路径也必须注销，不能只 close
                            self:unregisterEntryViewer(viewer)
                        end
                    end,
                },
            },
            {
                {
                    id = "ywbf_fav_note",
                    text = _("备注"),
                    callback = function()
                        -- 先关掉详情页再弹输入框：带键盘的层绝对不能叠在别人上面（真机实测）
                        UIManager:close(viewer)
                        self:askNote(row, on_changed, view_favorite)
                    end,
                },
                {
                    id = "ywbf_fav_tags",
                    text = _("标签"),
                    callback = function()
                        UIManager:close(viewer)
                        self:askTags(row, on_changed, view_favorite)
                    end,
                },
            },
            {
                {
                    --[[--
                    删除是唯一不可撤销的动作，必须二次确认，而且要把**为什么不可撤销**
                    写清楚：一条收藏往往翻了好几页才找到，误删就没了。

                    顺带跟「取消收藏」划清界线——这两个动作在一个卡片上挨着，
                    用户分不清哪个能回头，正是这次要解决的那个追问。
                    --]]
                    text = _("删除"),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = _("删除这条问答记录？删除会从历史里彻底移除，无法恢复。\n"
                                .. "如果只是想从收藏列表里拿掉，请用「取消收藏」，之后还能找回来。"),
                            ok_text = _("删除"),
                            cancel_text = _("取消"),
                            ok_callback = function()
                                local ok = Store:delete(row.book_fp, { row.index })
                                UIManager:close(viewer)
                                -- 关了就要注销：留着会变成悬空引用（见 unregisterEntryViewer）
                                self:unregisterEntryViewer(viewer)
                                UIManager:show(InfoMessage:new{
                                    text = ok and _("已删除") or _("删除失败"),
                                })
                                if ok and on_changed then on_changed() end
                            end,
                        })
                    end,
                },
                {
                    text = _("关闭"),
                    callback = function()
                        UIManager:close(viewer)
                        -- 同上：用户自己按「关闭」也要注销，否则登记表里留一个
                        -- 已经关掉的对象，X 关列表时去关它，屏上那张反而漏掉
                        self:unregisterEntryViewer(viewer)
                    end,
                },
            },
        },
    }
    --[[--
    A：开新的之前**先把还开着的那张收走**（真机 A 的根因）。

    取消收藏时详情页是故意留在屏上的（给用户撤销的机会），它就变成了"还开着、
    但列表已经不需要"的一张。不收走的话，用户接着点开另一条时它就成了孤儿：
    登记表只认最后开的那张，X 关列表时关的是登记的那张，底下这张孤儿没人关，
    列表一关它就露出来（用户原话：又回显了一次之前打开过的一条收藏问答的详情）。
    --]]
    self:closeOpenEntryViewers()
    UIManager:show(viewer)
    --[[--
    A：记下"当前还开着的详情页"，列表整体关闭时（右上角 X）要把它一并关掉。

    为什么用类上的字段而不是往 showEntry 多加一个参数：能关掉这个详情页的时机
    不属于详情页自己——是**列表**被关掉那一刻，而那一刻发生在另一个函数里。

    收走旧的那张之后再登记，所以这里登记的一定是屏上唯一的那张。
    --]]
    Favorites.open_entry_viewer = viewer
end

--[[--
当前筛选条件翻译成 Store 的 opts。

`since` 当场现算：不存时间戳快照，否则"最近 7 天"会随着快照一天天变宽，
用户第二天看到的就不是他要的那 7 天了。

@return table { since, style, tag, favorite }
--]]
function Favorites:filterOpts(ignore_favorite)
    local since = nil
    for _i, p in ipairs(Favorites.TIME_PRESETS) do
        if p.key == self.filter.time and type(p.days) == "number" then
            since = os.time() - p.days * 86400
        end
    end
    local favorite = self.filter.favorite
    --[[--
    `ignore_favorite`：显式把收藏状态置回"不限"。

    只有跨书检索用得上它：检索是**唯一**能把"取消掉的收藏"再捞回来的通路
    （见 runSearch 的注释）。要是让默认的 `favorite = true` 筛上去，
    用户取消过的东西在检索里也搜不到，这条通路就断了。
    --]]
    if ignore_favorite then favorite = nil end
    return { since = since, style = self.filter.style, tag = self.filter.tag,
             favorite = favorite }
end

--[[--
在一批行上应用当前筛选。
@param rows table
@param ignore_favorite bool|nil true = 不按收藏状态筛（检索页专用）
@return table 新数组
--]]
function Favorites:applyFilter(rows, ignore_favorite)
    return Store:filterRows(rows, self:filterOpts(ignore_favorite))
end

--[[--
筛选条件的单行说明（放在列表第一行的入口上）。
@param ignore_favorite bool|nil true = 这一屏不按收藏状态筛，标签里就别写它
--]]
function Favorites:filterLabel(ignore_favorite)
    local s = timePresetText(self.filter.time) .. " · " .. styleFilterText(self.filter.style)
    if not ignore_favorite then
        s = s .. " · " .. favFilterText(self.filter.favorite)
    end
    return s
end

--[[--
筛选菜单：时间预设 + 风格。**不做日期选择器**（理由见 TIME_PRESETS 的注释）。

选中之后关掉自己、回调让调用方重画列表：菜单+菜单叠在一起时上面那层点不动，
和输入框叠弹层是同一个坑。

@param on_done function 选完调用（调用方在这里重建列表）
@param scope_fp string|nil 「已取消收藏（N 条）」里 N 的统计范围（nil = 跨书）
@param ignore_favorite bool|nil true = 不显示「收藏状态」这一组（检索页专用）
--]]
--[[--
把菜单里"分组标题"那几行的点击**彻底**拆掉（真机第 1 项不通过）。

为什么光有 `select_enabled = false` 不够：望仔在真机上点标题，看到的是
"变黑、刷新一下、然后什么事也没有"——`MenuItem:onTapSelect`
（`frontend/ui/widget/menu.lua:513`）在调 `menu:onMenuSelect` **之前**先做了一次
反色 + `setDirty(nil, "fast", dimen)` + `forceRePaint`，`select_enabled` 只挡得住
后面的回调，**挡不住这一次闪烁**。用户看到"有反应但没结果"，就当它是个坏按钮。

所以这里在菜单建好之后直接把标题行的手势表清空、并把 onTapSelect / onHoldSelect
换成空实现：点上去不反色、不重绘、不回调 —— 跟点在一块空白处一样。

怎么认出哪几行是标题：`Menu:updateItems` 建 MenuItem 时把我们在 `items` 里塞的
那张表原样传成了 `entry`（menu.lua `entry = item`），所以 `entry.ywbf_group_title`
就是标记；`menu.item_group` 是按顺序插进去的 MenuItem 数组。

@param menu table 已经建好的 Menu 实例
@return number 冻住的行数（0 = 一行都没认出来，调用方可以据此打日志）
--]]
local function freezeGroupTitles(menu)
    local group = type(menu) == "table" and menu.item_group or nil
    if type(group) ~= "table" then return 0 end
    local n = 0
    for _i = 1, #group do
        local w = group[_i]
        local entry = type(w) == "table" and w.entry or nil
        if type(entry) == "table" and entry.ywbf_group_title == true then
            -- 两手一起上：清空 ges_events 让手势根本匹配不上；
            -- 换掉 onTapSelect / onHoldSelect 让"万一还有别的路径调进来"也是空转。
            w.ges_events = {}
            w.onTapSelect = function() return true end
            w.onHoldSelect = function() return true end
            n = n + 1
        end
    end
    return n
end

function Favorites:showFilterMenu(on_done, scope_fp, ignore_favorite)
    local menu = nil
    local function pick(apply)
        apply()
        if menu then UIManager:close(menu) end
        if on_done then on_done() end
    end

    local items = {}

    --[[--
    分组标题（真机 D）：**不可点**，并且**看起来就不像选项**。

    两个字段一起上，缺一不可：
      · `select_enabled = false` —— 真 Menu 的 `onMenuSelect` 在 `onMenuChoice`
        之前就为它直接返回（`frontend/ui/widget/menu.lua`），点了不会有动作；
        不给 callback 是第二道保险：哪天 Menu 改了判定，点了也**没东西可调**；
      · `bold = true` —— 视觉上跟下面的选项分开（字重）。

    为什么要视觉区分：以前标题跟选项长得一模一样，用户点上去**只闪一下、什么都
    没发生**——`MenuItem:onTapSelect` 那段反色高亮照旧执行，只是回调被拦了，看着
    就像"这一项坏了"。加粗之后它是"这一组的小标题"，不是"一个没反应的选项"。

    为什么不加缩进/改字号：缩进要往标题或选项的文案里塞空格，而筛选菜单的文案
    有专门的断言逐条盯着（多一个全角空格就会红一片）；字号 Menu 这一版没有逐项
    开关。字重是唯一"不改文案、又有区分度"的手段。

    第三条（真机新一轮反馈）：`select_enabled = false` 挡得住回调、挡不住
    `MenuItem:onTapSelect` 里那次**反色 + 重绘**，所以点上去仍会"变黑刷新一下"。
    彻底点不动靠菜单建好之后的 `freezeGroupTitles(menu)`（见它的注释）——
    标题行带上 `ywbf_group_title` 这个标记就是给那一步认人用的。
    --]]
    local function addGroupTitle(text)
        items[#items + 1] = { text = text, select_enabled = false, bold = true,
                              ywbf_group_title = true }
    end

    --[[--
    「收藏状态」放在菜单**最上面**。

    它是这一屏"有哪些条目"的主轴（默认只显示已收藏的），而用户追问的
    "取消收藏之后怎么找回来"，答案就藏在这一组里。理由跟当初把「筛选」入口
    放在列表第一行一样：藏在下面的等于没有。
    --]]
    if not ignore_favorite then
        addGroupTitle(_("收藏状态"))
        -- N 当场数出来（Store:countUnfavorited），不写死也不估
        local n_unfav = Store:countUnfavorited(scope_fp)
        local function addFav(key, text)
            local mark = (self.filter.favorite == key) and "✓ " or ""
            items[#items + 1] = {
                text = mark .. text,
                callback = function() pick(function() self.filter.favorite = key end) end,
            }
        end
        addFav(true, favFilterText(true))
        addFav(false, T(_("%1（%2 条）"), favFilterText(false), tostring(n_unfav))) -- luacheck: ignore
        addFav(nil, favFilterText(nil))
    end

    addGroupTitle(_("时间范围"))
    for _i, preset in ipairs(Favorites.TIME_PRESETS) do
        local key = preset.key
        local mark = (self.filter.time == key) and "✓ " or ""
        items[#items + 1] = {
            text = mark .. _(preset.text),
            callback = function() pick(function() self.filter.time = key end) end,
        }
    end

    addGroupTitle(_("回复风格"))
    --[[--
    「全部风格」这一项必须**显式**加进去。

    原来写的是 `local style_keys = { nil }`，然后 `for _k, key in ipairs(style_keys)`：
    Lua 里 `{ nil }` 是一张**空表**（数组部分长度为 0），ipairs 一步也不会走，
    于是"不限风格"这一项被静默吞掉——用户一旦选中某种风格就再也找不到回到
    "全部"的路。这个洞是自测里那条"菜单项数必须不多不少"的断言挖出来的：
    单项存在与否的断言查不到它，因为没有任何一项凭空消失，只是少了一项。
    --]]
    local function addStyle(key)
        local mark = (self.filter.style == key) and "✓ " or ""
        items[#items + 1] = {
            text = mark .. styleFilterText(key),
            callback = function() pick(function() self.filter.style = key end) end,
        }
    end
    -- 风格候选一律从 Prompts.STYLES 取，绝不在这里另抄一份列表
    addStyle(nil)
    for _s, s in ipairs(Prompts.STYLES) do addStyle(s.key) end
    addStyle(Store.UNKNOWN_STYLE)

    menu = Menu:new{ title = _("筛选"), item_table = items }
    -- 建好就冻一次（Menu:init 里已经排过一轮条目），
    -- 再把 updateItems 包一层：翻页 / 重排之后新建出来的标题行同样冻上。
    freezeGroupTitles(menu)
    local orig_updateItems = menu.updateItems
    menu.updateItems = function(self_, ...)
        orig_updateItems(self_, ...)
        freezeGroupTitles(self_)
    end
    UIManager:show(menu)
    return menu
end

--[[--
F11：默认展开态按"当前正在读的那本书"智能匹配。

三条产品规则（用户定案）：

  1. **没在读书**（在 KOReader 书库视图）→ 全部折叠；
  2. **在读 X，且 X 有收藏**（X 出现在列表里）→ 只展开 X，其余书全折叠；
     并尽量再展开 X 里**正在读的那一章**（渐进增强，匹配不上就停在书级）；
  3. **在读 X，但 X 没收藏**（列表里没有 X）→ 全部折叠。

规则 1 与规则 3 结果相同（都全折叠），但**成因不同**，验收必须分开写——
一条坏掉时另一条不该跟着变红。

这层为什么**不**套到所有调用点：老的"章节全预展开"是为了"跨书视图点开一本就直接
看见条目"。F11 只对**收藏列表**（showAllFavorites）启用，检索结果页不启用——
检索是"我找某个词"，把章节全收起来等于把命中藏起来。
--]]

--[[--
取"当前在读的书 + 进度"（F11 的唯一数据源）。

真机路径：从当前 UI 上按 duck-typing 找插件实例（带 `hasOpenBook` + `bookFingerprint`
的那个模块），再调 `plugin:hasOpenBook()` / `plugin:bookFingerprint()` / `plugin:progress()`。

**为什么不吃 `require("main")` 里的插件名**：实例是**按 UI 注册**的
（`readerui.lua` 的 `registerModule(name, instance)` 把实例挂到 `self[name]`），
而"在不在读书"取决于**当前是哪个 UI**——书库里 `ReaderUI.instance` 就是 nil，
天然对应规则 1；不写死插件名，日后改名也不受影响。

**必须先过 `hasOpenBook()`**：`bookFingerprint()` 没书时返回的是字符串 `"unknown"`，
不是 nil（见 main.lua:71），只判类型会把书库当成一本叫 unknown 的书。

无头验收脚本怎么造出"在读某本书"：**不**给这条路径开专用旁路，而是把
`package.loaded["apps/reader/readerui"]` 换成一个只有 `instance` 字段的小表
（`require` 先查 `package.loaded`，命中就不去找真文件）。这样脚本跑的就是
**真的 `readingFromPlugin()`**——三种情况分别是 `instance = nil`（书库）、
`hasOpenBook()` 假（接口说没书）、`hasOpenBook()` 真 + 真实指纹（在读某本书）。
--]]
local function readingFromPlugin()
    local ok_ru, ReaderUI = pcall(require, "apps/reader/readerui")
    local ru = (ok_ru and type(ReaderUI) == "table") and ReaderUI.instance or nil
    if type(ru) ~= "table" then return nil, nil end
    local plugin = nil
    for _i, m in ipairs(ru) do
        if type(m) == "table" and type(m.hasOpenBook) == "function"
            and type(m.bookFingerprint) == "function" then
            plugin = m
            break
        end
    end
    if not plugin then return nil, nil end
    local ok_has, has = pcall(plugin.hasOpenBook, plugin)
    if not ok_has or has ~= true then return nil, nil end
    local ok_fp, fp = pcall(plugin.bookFingerprint, plugin)
    if not ok_fp or type(fp) ~= "string" or fp == "" or fp == "unknown" then
        return nil, nil
    end
    local prog = nil
    if type(plugin.progress) == "function" then
        local ok_p, p = pcall(plugin.progress, plugin)
        if ok_p then prog = p end
    end
    return fp, prog
end

--[[--
当前章在收藏列表里的分组 key，返回**候选列表**（先 fine，后 coarse）。

为什么两个都要试：章节分组的 key 来自 `chapterKeyOf(row)`，而它的口径是
"有细粒度用细粒度、没有才回落粗粒度"。老收藏（没回填 fine 字段）的分组 key
是**粗粒度**的——只拿 fine 去比，那批永远匹配不上，表现就是
"换了章在读、列表却没跟着展开"。

字段名两边不一致也一并兜住：`Spoiler.readProgress` 给的是 `chapter_fine`（标题）
+ `chapter_fine_index`，而行数据里那一列叫 `chapter_fine_title`（asker.lua:286）。
两个拼写都认，免得日后只改一处。
--]]
local function currentChapterKeys(prog)
    if type(prog) ~= "table" then return nil end
    local keys = {}
    local fi = type(prog.chapter_fine_index) == "number" and prog.chapter_fine_index or nil
    local ft = prog.chapter_fine_title
    if type(ft) ~= "string" or ft == "" then ft = prog.chapter_fine end
    if type(ft) ~= "string" or ft == "" then ft = nil end
    if fi ~= nil or ft ~= nil then
        keys[#keys + 1] = tostring(fi or "") .. "\1" .. tostring(ft or "")
    end
    local ci = type(prog.chapter_index) == "number" and prog.chapter_index or nil
    local ct = type(prog.chapter) == "string" and prog.chapter ~= "" and prog.chapter or nil
    if ci ~= nil or ct ~= nil then
        keys[#keys + 1] = tostring(ci or "") .. "\1" .. tostring(ct or "")
    end
    if #keys == 0 then return nil end
    return keys
end

--[[--
按"当前在读"填默认展开态（跨书收藏列表专用）。就地写 expanded_books / expanded_chapters。
--]]
local function applyReadingExpand(expanded_books, expanded_chapters, book_order)
    local cur_fp, prog = readingFromPlugin()
    if not cur_fp then return end                    -- 规则 1：没在读书 → 全折叠
    local want = tostring(cur_fp)
    local target = nil
    for _i, b in ipairs(book_order) do
        if tostring(b.fp) == want then target = b break end
    end
    if not target then return end                    -- 规则 3：在读但没收藏 → 全折叠
    expanded_books[target.fp] = true                 -- 规则 2：只展开这一本
    local cand = currentChapterKeys(prog)
    if not cand then return end
    for _c, key in ipairs(cand) do                   -- 先 fine，后 coarse
        for _j, c in ipairs(target.chapter_order) do
            if c.key == key then
                expanded_chapters[tostring(target.fp) .. "\1" .. c.key] = true
                return
            end
        end
    end
    -- 匹配不上：停在书级（不比"只做书级"更差）
end

--[[--
把若干行画成一个**可折叠**的 Menu（书 → 章节 → 条目，两级）。

为什么是折叠：用户收藏一多，一屏十几行全是同一本书的长标题，
根本分不出这一条是哪本书的哪一章。按书、再按章节收起来之后，
一屏能看见的是"有哪几本书"，点开才进到具体条目。

为什么用 `switchItemTable` **原地换表**而不是新建菜单：新建会叠一层，
上一层的点击会被挡住（真机踩过两次），而这一版 KOReader 的
`sub_item_table_func` 只在 1585 行管显示格式、不负责打开，指望不上。
`switchItemTable` 的第三个参数是 itemnumber（要停在哪一项），
传 nil 会跳回第 1 页——所以下面每次换表都把**用户刚点的那一行**的下标
在新表里找出来传进去，焦点不丢。

@param title    string
@param rows     table 行数组（Store 的行格式）
@param rebuild  function 需要重画时调用它（删/取消收藏/改完筛选之后要重新读一遍数据）
@param group    bool 是否跨书视图（决定默认折叠到哪一层）
@param empty_text string 一条都没有时的提示
@param opts     table|nil { show_filter = bool, keep_expanded = bool, scope_fp = string|nil,
                            ignore_favorite = bool, expand_reading = bool }
                show_filter  —— 给不给"筛选"入口
                keep_expanded —— **保留上次的展开状态**（见下面"默认展开到哪一层"）。
                scope_fp     —— 「已取消收藏（N 条）」里 N 的统计范围（nil = 跨书）
                ignore_favorite —— 这一屏不认「收藏状态」这一档（检索页专用，见 runSearch）
                ignore_filter   —— 这一屏**完全不筛**（检索页专用，见 runSearch 的注释）。
                                  与 ignore_favorite 的区别：后者只丢掉"收藏状态"这一档，
                                  时间 / 风格 / 标签照样筛；前者是 time/style/tag/favorite
                                  一档都不上。检索要的是"全书里有没有这个词"，
                                  不是"当前筛选档位下有没有这个词"。
                expand_reading —— F11：跨书视图默认只展开"当前在读的那本书"（收藏列表用；
                                  检索页**不传**，否则命中会被章节折叠藏起来）。
                expand_all     —— 跨书视图也把**每一本书**展开（检索页专用，真机 B）。
                                  检索的落点是"含这个词的那一问一答"，命中本身就是条目；
                                  先给一层"有哪几本书"等于让用户为看一条命中多点一下。
                                  收藏列表**一律不传**：它的默认展开态归 F11 管（expand_reading），
                                  一格都不许动（真机 B 的硬边界）。
                用尾参 opts 传而不是新增位置参数：尾参不改变任何既有调用点。
--]]
function Favorites:showList(title, rows, rebuild, group, empty_text, opts)
    local incoming = (type(rows) == "table") and rows or {}
    local use_filter = type(opts) == "table" and opts.show_filter == true
    local ignore_favorite = type(opts) == "table" and opts.ignore_favorite == true
    --[[--
    `ignore_filter`：这一屏**一次筛选都不做**（检索页专用，真机新 bug）。

    为什么检索必须完全不筛：望仔把筛选切到「仅已收藏」之后再去搜一条**未收藏**
    的条目，搜不到——`showList` 会拿当前档位把命中再筛一遍。用户看到的"搜不到"
    是假的：命中其实取回来了，只是被档位挡在门外。搜索是"全书里有没有这个词"，
    不是"当前筛选档位下有没有这个词"。

    为什么不动 `self.filter`：档位是用户自己挑的，搜完还得原样站着。
    这里只在**渲染这一屏**时不套它，一行都没写回去。
    --]]
    local ignore_filter = type(opts) == "table" and opts.ignore_filter == true
    local scope_fp = type(opts) == "table" and opts.scope_fp or nil
    local expand_reading = type(opts) == "table" and opts.expand_reading == true
    local expand_all = type(opts) == "table" and opts.expand_all == true
    --[[--
    `keep_expanded`：这次是"列表内容变了所以重画"，不是"用户刚打开列表"。

    两者的默认态要求是相反的：刚打开时希望看见"有哪几本书"（跨书视图全折叠），
    而"我在详情页取消了一条收藏、退回来"时，用户希望**原来展开的那本书还在原地展开**。
    以前不区分，`refresh()` 走一遍 `rebuild()` 就把 `expanded_*` 全清空了——
    用户看到的是"我动了一条，别的书全被收起了"，也就是他反馈的
    "操作某本书会影响其它书的状态"。
    --]]
    local keep_expanded = type(opts) == "table" and opts.keep_expanded == true
    local shown = (use_filter and not ignore_filter)
        and self:applyFilter(incoming, ignore_favorite) or incoming
    -- 空态提示（P0-1）：非空时是 nil，空结果时由下面那段赋值，交给 buildItems 渲染成一行
    local empty_hint = nil

    if #shown == 0 then
        --[[--
        断头路：**「已取消收藏」这一档被清空时，落回默认档**（`favorite = true`）。

        场景：用户在「已取消收藏」里把**最后一条**按「恢复收藏」恢复走 → 这一档
        一条都不剩 → 按下面那条老逻辑，只弹一句「没有『已取消收藏』的条目」并且
        `return nil`（列表根本没建出来）。用户眼前的详情页关掉之后**没有列表可交互**，
        只能重新从菜单进来、还得自己把档位再切回「仅已收藏」——一条路走到头没有出口。

        所以这里先把档位落回默认档，再用新档位重画一遍（`rebuild`）：用户按完
        「恢复收藏」就直接站回「仅已收藏」的列表上，中间没有空转。

        判据用 `#incoming == 0` 而不是 `#shown == 0`：
          · `#incoming == 0` 是"这一档真的没内容了"（与本次动作直接相关）；
          · `#shown == 0` 还可能是被时间/标签筛没的（`incoming` 有货），那种情况
            该给的是下面那句"改一下筛选条件"，把档位也一并改掉反而更莫名其妙。

        再窄一层：**只认"内容变了的重画"**（`keep_expanded`，即上面那个局部量）。
        它只由 `refresh()` 写成 true（`rebuild(true)`），也就是"用户刚在这一屏里做了
        一个动作（恢复收藏 / 删除）"；而"用户刚打开列表"和"刚在筛选菜单里选了档位"
        走的都是 `rebuild()`（keep 为 nil）。没有这一层收窄，用户**主动**选一个
        「已取消收藏（0 条）」也会被弹回默认档——那是把用户刚做的选择改掉，比断头路
        更让人恼火（菜单项上明明写着 0 条，他是知情选的）。

        为什么是 `true` 而**不是** `nil`：在 `favFilterText` / `sourceForState` 里
        `nil` 就是「全部」，会把 `books.json` 里没有对应键的那些 fp（真机上就是
        history/unknown.json 那批无归属书）一起放出来 —— 上一轮要挡的正是它们。
        默认值写在 `Favorites.filter`（本文件 167 行，`favorite = true`），这里照抄它，
        不另立一份"默认是什么"的定义。

        为什么只认 `favorite == false` 这一档：「全部」（nil）空了意味着压根没有历史，
        「仅已收藏」（true）空了是"还没收藏过"——两句空文案都是实话，不算断头路。
        --]]
        if use_filter and (not ignore_favorite) and self.filter.favorite == false
            and #incoming == 0 and keep_expanded and rebuild then
            self.filter.favorite = true
            logger.info("YWBF: favorites: 已取消收藏 emptied -> fall back to default state (favorite=true)")
            rebuild(false)
            return nil
        end
        -- 筛没了和本来就没有是两回事：前者要提示"改条件"，后者才是"还没有收藏"
        local text = empty_text or _("还没有收藏。")
        if use_filter and #incoming > 0 then
            --[[--
            真机 C：这句话**缩短**成一句大白话。

            旧文案是「当前筛选（仅已收藏 · 最近 7 天 · 某风格）下一条都没有。改一下
            筛选条件就能看到其余 N 条。」——把整套档位又念一遍，在小屏上要占两三行，
            用户其实只需要知道一件事：**是筛选的锅**。

            缩短后"你怎么脱困"那半句没了，出口靠列表第一行那个「筛选：…」承担——
            它就在提示的正上方，比在文案里写一遍"改一下筛选条件"更直接。
            缩这条文案的硬边界就是**出口不许一起缩没**：第一行那个「筛选：…」
            必须还在（由 §13 的 13b 与 §9 的 9b 一起守着）。
            --]]
            text = _("当前筛选条件下没有收藏。")
        end
        --[[--
        真机 P0-1：**空结果不许退回菜单**。

        以前这里 `UIManager:show(InfoMessage)` 之后直接 `return nil` —— 列表压根没建出来，
        用户眼前只剩一句提示，连"改筛选条件"的入口都没有（筛选入口是列表的第一行）。
        筛选条件粘在单例上，再点一次进来还是 0 条 ⇒ 死循环，只能重启。

        现在：只要有筛选入口（`use_filter`），就**照常把列表建出来**，空态由
        `buildItems` 里那一行提示承担。这样用户站在列表里，第一行的「筛选：…」
        就是出口，点开改条件即可，不需要重启。

        没有筛选入口的调用点（不存在的筛选可改）才退回原来的提示 + `return nil`，
        那不是死路。
        --]]
        if not use_filter then
            UIManager:show(InfoMessage:new{ text = text })
            return nil
        end
        empty_hint = text
    end

    -- 删掉/取消收藏之后要重画列表。重画前**必须先关掉当前这一层**：
    -- 两层列表叠在一起时，上面那层会挡住下面那层的点击（真机踩过同样的坑）。
    local current_menu = nil
    local function refresh()
        -- 先关掉当前这一层再重画（两层叠着时上面那层会挡住下面那层的点击）。
        -- 传 true = "这次是内容变了重画，不是用户刚打开" → 保留展开状态，
        -- 否则用户从详情页退回来会发现"别的书全被收起了"。
        if current_menu then UIManager:close(current_menu) end
        if rebuild then rebuild(true) end
    end

    -- ---------- 分组：书 -> 章节 -> 条目 ----------
    local books, book_order = {}, {}
    for _i, row in ipairs(shown) do
        local fp = tostring(row.book_fp or "")
        local b = books[fp]
        if b == nil then
            b = { fp = row.book_fp, rows = {}, chapters = {}, chapter_order = {} }
            books[fp] = b
            book_order[#book_order + 1] = b
        end
        b.rows[#b.rows + 1] = row

        local ck = chapterKeyOf(row)
        local c = b.chapters[ck]
        if c == nil then
            -- 排序章号 / 章名也走 fineChapter：回目级编号升序才是书里的真实顺序，
            -- 用粗粒度的一级序号排（《红楼梦》所有回都是 2）会把章节行排成一团。
            local c_index, c_title = fineChapter(row)
            c = { key = ck, label = chapterLabelOf(row),
                  index = c_index, title = c_title, rows = {} }
            b.chapters[ck] = c
            b.chapter_order[#b.chapter_order + 1] = c
        end
        c.rows[#c.rows + 1] = row
    end

    --[[--
    书名：先收齐全书的**原始全名**，再交给 `BookMeta:disambiguate` 一次算完。

    为什么不逐本单独 `shortTitle`：化简之后同名的书（`罪与罚_曾思艺译本` /
    `_朱海观王汶译本` / `_臧仲伦译本` 都是 `罪与罚`）只有放进同一组里才看得出撞名，
    逐本算永远发现不了——用户抱怨的"分不出是哪本书"就是这么漏掉的。

    排序键 `b.sort_key` 单独存一份：**不带消歧后缀**。用带后缀的展示名排序的话，
    `罪与罚（曾思艺）` 会跟 `罪与罚（朱海观王汶）` 按译者名字排开，
    而它们本来应该紧挨着、按书名跟别的书一起排。

    书：按**精简后**的书名排（用原始全名排的话，"《红楼梦》人文社…" 这类
    长串会按修饰词排序，同一本书的不同写法就散开了）
    --]]
    local raws = {}
    for _i, b in ipairs(book_order) do
        local info = Store:bookInfo(b.fp)
        local raw = nil
        if type(info) == "table" and type(info.title) == "string" and info.title ~= "" then
            raw = info.title
        elseif type(b.rows[1]) == "table" and type(b.rows[1].book_title) == "string"
            and b.rows[1].book_title ~= "" then
            raw = b.rows[1].book_title
        else
            -- 两个来源都取不到时兜底成"未知书"：传 nil 给 shortTitle 会算出一个
            -- 字面量 "nil" 当书名，那比"未知书"难看得多
            raw = BookMeta.FALLBACK_TITLE
        end
        b.raw = raw
        raws[#raws + 1] = raw
    end
    local disp = BookMeta:disambiguate(raws)
    for _i, b in ipairs(book_order) do
        b.sort_key = BookMeta:shortTitle(b.raw)
        b.short = disp[b.raw] or b.sort_key
    end
    table.sort(book_order, function(a, b) return (a.sort_key or "") < (b.sort_key or "") end)

    -- 章节：先按章号，再按章名（都取不到的排在最后）。
    -- 章号取自 fineChapter —— 回目级优先，没有细粒度字段的老数据自动按粗粒度排。
    for _i, b in ipairs(book_order) do
        table.sort(b.chapter_order, function(x, y)
            local ix = type(x.index) == "number" and x.index or math.huge
            local iy = type(y.index) == "number" and y.index or math.huge
            if ix ~= iy then return ix < iy end
            return tostring(x.title or "") < tostring(y.title or "")
        end)
        --[[--
        条目：**先按页码，再按时间倒序**。

        用户要的是"引文在原书中的前后位置"，而我们手上存得到的最接近的
        代理就是页码——**它不是真实的字符偏移**。同一页里的几条，
        页码分不出先后，才退回时间。别把它说成"按原文位置排序"：
        那会让"同一页里顺序看起来不对"变成一个说不清的 bug。
        --]]
        for _j, c in ipairs(b.chapter_order) do
            table.sort(c.rows, function(p, q)
                local pp = type(p.page) == "number" and p.page or math.huge
                local qq = type(q.page) == "number" and q.page or math.huge
                if pp ~= qq then return pp < qq end
                return (p.ts or 0) > (q.ts or 0)
            end)
        end
    end

    --[[--
    默认展开到哪一层：
      · **收藏列表跨书视图（F11，opts.expand_reading）** → 只展开"当前在读的那本书"
        （没在读书 / 在读的书没收藏 → 全折叠），并尽量再展开它的当前章（见 applyReadingExpand）；
      · 单书视图（「本书收藏」，group == false）→ 该书展开 + 章节展开（直接看到条目）；
      · **检索结果页（opts.expand_all，真机 B）** → 书也展开、章节也展开（直接看见命中条目）；
      · 跨书视图的其余调用点 → 书折叠（先看见"有哪几本书"）、章节展开。

    **为什么放在 self 上、又在入口一律清空**：`refreshInPlace` 换表时要照着 `buildItems()`
    重画一遍，展开状态总得有个地方放，所以挂在 `self` 上；但它是**这一次列表**的内部状态，
    `showList` 入口（下面两行）每次都清空——不跨调用、更不落盘（真记住上次展开到哪的话，
    下次打开会先看见一堆跟当前任务无关的展开项）。

    由此有一条**给验收的边界**：同一次列表里点开了一本书，它就一直是展开的，这是有意的
    （点一下就弹回全折叠才是 bug）。所以"默认展开到哪一层"只能看**刚建出来的那一次**，
    拿一张已经被点过的列表去验默认态是验不出来的。
    --]]
    -- keep_expanded（= 重画，不是新打开）：原样留着，一格都不动，
    -- 也不再套一遍默认态——否则"保留"就白保留了。
    if not keep_expanded then
        self.expanded_books = {}
        self.expanded_chapters = {}
        if group and expand_reading then
            -- F11：跨书收藏列表 —— 只展开"当前在读的那本书"（含它的当前章）
            applyReadingExpand(self.expanded_books, self.expanded_chapters, book_order)
        else
            --[[--
            老默认态（单书视图 / 检索页 / 没开 F11 的调用点）：
              · 单书视图 → 书展开 + 章节全展开（「本书收藏」就是要直接看到条目，27n 的定案）；
              · 检索页（expand_all）→ 书也展开（真机 B：命中就是条目，不再藏在一层书后面）；
              · 跨书视图的其余调用点 → 书折叠、章节全展开（点开一本就看见条目）。

            为什么 expand_all 只加在**书**这一层：章节本来就是全展开的，书一开就直达到条目；
            再往里没有更深的层级，不存在"展开过头"。
            --]]
            for _i, b in ipairs(book_order) do
                if (not group) or expand_all then self.expanded_books[b.fp] = true end
                for _j, c in ipairs(b.chapter_order) do
                    self.expanded_chapters[tostring(b.fp) .. "\1" .. c.key] = true
                end
            end
        end
    end

    --[[--
    `buildItems()` 产出的每一行都带一个 `row_kind`，QA 的行层级断言靠它精确匹配。

    为什么需要它：以前只能靠 `▸`/`▾` 和全角空格的**个数**推导"这是书级行还是章节行"，
    哪天改一下缩进符号，断言就会假红（或者更糟：假绿）。多带一个字段比猜缩进可靠。
    缩进和箭头是给用户看层级的，**一个字都没动**，这只是额外加的机器可读标记。
    --]]
    local refreshInPlace
    local function buildItems()
        local items, keys = {}, {}

        -- 筛选入口放最上面：它是"这一屏有哪些行"的开关，藏在下面等于没有。
        if use_filter then
            items[#items + 1] = {
                row_kind = "filter",
                text = T(_("筛选：%1"), self:filterLabel(ignore_favorite)), -- luacheck: ignore
                callback = function()
                    if current_menu then UIManager:close(current_menu) end
                    --[[--
                    检索页（`ignore_filter`）上改筛选走**另一条**回调。

                    检索默认不套筛选（见 runSearch），若还走 `rebuild()`，用户挑完档位
                    结果一动不动——那就是本轮要治的"看着像按钮、点了没结果"。
                    所以这一屏改档位 = 用户**明确要求**按筛选看，切到"套筛选"重跑一遍。
                    --]]
                    local on_changed = (type(opts) == "table") and opts.on_filter_changed or nil
                    if ignore_filter and type(on_changed) == "function" then
                        self:showFilterMenu(on_changed, scope_fp, ignore_favorite)
                        return
                    end
                    self:showFilterMenu(function() if rebuild then rebuild() end end,
                        scope_fp, ignore_favorite)
                end,
            }
            keys[#keys + 1] = "filter"
        end

        --[[--
        空态成一行（P0-1）：列表一条内容都没有时，把那句提示渲染成列表里的一行，
        而不是"弹个 InfoMessage 然后列表不存在"。

        为什么必须是列表里的一行：筛选入口就在本列表的第一行（见上）。提示若以
        InfoMessage 呈现，用户看完关掉就是空白一片，没有出口；成行之后他站在列表里，
        抬头就是「筛选：…」，点开改条件即可脱困。

        `callback` 给空函数而不是 nil：Menu 的每一行都要有回调，给 nil 的话
        点到这一行会报错。空函数 = 可点、无副作用。
        --]]
        if empty_hint then
            items[#items + 1] = {
                row_kind = "empty",
                text = empty_hint,
                callback = function() end,
            }
            keys[#keys + 1] = "empty"
        end

        for _i, b in ipairs(book_order) do
            local fp_key = tostring(b.fp)
            local open = (self.expanded_books[b.fp] == true)
            items[#items + 1] = {
                row_kind = "book",
                text = (open and "▾ " or "▸ ")
                    .. T(_("《%1》 · %2 条"), b.short or "", tostring(#b.rows)), -- luacheck: ignore
                callback = function()
                    if open then
                        self.expanded_books[b.fp] = nil
                    else
                        self.expanded_books[b.fp] = true
                    end
                    refreshInPlace(fp_key)
                end,
            }
            keys[#keys + 1] = fp_key

            if open then
                for _j, c in ipairs(b.chapter_order) do
                    local ck = fp_key .. "\1" .. c.key
                    local copen = (self.expanded_chapters[ck] == true)
                    items[#items + 1] = {
                        row_kind = "chapter",
                        text = "　" .. (copen and "▾ " or "▸ ") .. c.label
                            .. T(_(" · %1 条"), tostring(#c.rows)), -- luacheck: ignore
                        callback = function()
                            if copen then
                                self.expanded_chapters[ck] = nil
                            else
                                self.expanded_chapters[ck] = true
                            end
                            refreshInPlace(ck)
                        end,
                    }
                    keys[#keys + 1] = ck

                    if copen then
                        for _k, row in ipairs(c.rows) do
                            items[#items + 1] = {
                                row_kind = "entry",
                                text = "　　" .. entrySummary(row),
                                callback = function()
                                    -- 尾传当前视图的收藏状态：在「已取消收藏」视图里
                                    -- 详情页按钮要写「恢复收藏」（见 showEntry）
                                    self:showEntrySafe(row, refresh, self.filter.favorite)
                                end,
                            }
                            keys[#keys + 1] = "row:" .. tostring(row.book_fp) .. ":"
                                .. tostring(row.index)
                        end
                    end
                end
            end
        end
        return items, keys
    end

    --[[--
    换表时把焦点与视口都留在用户刚点的那一行上。

    两层都要管，缺一层用户就会觉得"我动了一本书，别的书也跟着变了"：
      · `itemnumber`（这里先设）—— `Menu:updateItems` 是靠 `self.itemnumber`
        决定给哪一行打焦点框的（`ui/widget/menu.lua`：`if index == self.itemnumber
        then select_number = idx end`）。而 `switchItemTable` 只在 FileChooser
        （`self.path ~= nil`）那条分支里回写 `self.itemnumber`，菜单这条路**不写**。
        于是不自己设的话焦点会落到本页第一行 —— 用户点的是第 3 本，高亮却跑到第 1 本，
        看起来就像"别的书被选中了"。
      · `itemnumber` 参数 —— `switchItemTable` 用它算 `self.page = ceil(n / perpage)`，
        即"让这一行所在的那一页显示出来"。传 nil 会跳回第 1 页。

    为什么锚点用"用户点的那一行"而不是"本页第一行"：展开/收起插入或删除的行
    都在这行**之后**，所以这一行的下标不变 → 页码不变 → 上面的内容一格都不动。
    （这一点由 `tools/eng_check_fold.lua` 的行为断言锁住：展开 A 后 B 的折叠态不变、
    且换表时传进去的锚点下标仍是 A 自己。）
    --]]
    refreshInPlace = function(focus_key)
        if not current_menu then return end
        local new_items, new_keys = buildItems()
        local num = nil
        if focus_key ~= nil then
            for i, k in ipairs(new_keys) do
                if k == focus_key then num = i break end
            end
        end
        -- 先设焦点再换表：updateItems 在 switchItemTable 内部就跑掉了，设晚了不生效
        if num then current_menu.itemnumber = num end
        current_menu:switchItemTable(title, new_items, num)
    end

    local initial_items = buildItems()
    current_menu = Menu:new{
        title = title,
        item_table = initial_items,
    }
    --[[--
    A：点右上角那个 X（= "我要关掉整个问答列表"）必须**一路退到插件菜单**，
    不能把之前打开过的某条收藏详情又翻出来。

    为什么会有"翻出来"这回事：详情页是**独立 show 出来的 widget**。在默认档位里
    按「取消收藏」时它故意留在屏上（给用户一次手滑撤销的机会，见 showEntry 的注释），
    而 `refresh()` 会把列表**关掉再重建**——重建出来的列表就压在详情页**上面**了。
    这时按 X 只关掉列表，底下那张详情页立刻露出来，而且它对应的那条已经不在列表里了
    （真机反馈原话："不能再次回显之前打开过的某条收藏问答的详情窗口"）。

    挂在哪里：`Menu:onCloseAllMenus`。它是"用户要求关掉整个列表"这一个语义的
    唯一入口（X、向下滑、点空白都汇到它），而 `Menu:onMenuSelect` 走的 `close_callback`
    **不能用**——那条在"点了某一项之后"也会触发（`menu.lua` 里 `onMenuChoice` 之后紧跟
    一句 `close_callback()`），挂上去等于"点开详情页的瞬间又把它关掉"。

    `Menu.onCloseAllMenus(self_)`（点号调用、显式传 self）而不是 `self_:onCloseAllMenus()`：
    实例字段一旦被赋成这个闭包，冒号调用会无限递归。
    --]]
    current_menu.onCloseAllMenus = function(self_)
        local v = Favorites.open_entry_viewer
        if v then
            Favorites.open_entry_viewer = nil
            UIManager:close(v)
        end
        return Menu.onCloseAllMenus(self_)
    end
    UIManager:show(current_menu)
    logger.info(string.format("YWBF: favorites list shown, rows=%d shown=%d grouped=%s books=%d",
        #incoming, #shown, tostring(group == true), #book_order))
    return current_menu
end

--[[--
「收藏状态」这一档**只在本次打开的列表实例内存活**：每次从菜单打开列表都拨回默认档。

真机事故（第 7 项）：用户上一次为了看筛选进过一次「已取消收藏」档，之后再打开
「本书收藏」「全部收藏」，两个入口都弹「没有『已取消收藏』的条目」——他压根不记得
自己切过档。根因不是空文案写反（文案本来就读当前档位），而是**档位粘住了**：
`Favorites.filter` 是模块级的表（进程内单例），而这两个入口只换 scope、不碰收藏状态，
于是那次选择一直生效，直到 KOReader 进程结束。

证据（`tools/eng_probe_f7.lua` 在 KPW4 上跑出来的实际值）：
  · 默认值在 `Favorites.filter`（本文件 167 行，`favorite = true`）；
  · 全文件只有两处写它：筛选菜单的 `pick`（825 行）与本文件那处断头路兜底；
  · `require("ui/favorites")` 两次拿到**同一个表**（单例）；
  · `data/settings.json` 里没有 `favorite` 字样 → 不跨进程持久化，只跨"本次打开"。

为什么只重置这一个字段、不顺手把时间/风格/标签也重置：会造成"看不懂的空列表"的
只有收藏状态这一档（它在三个档位之间有"我到底在看哪一批"的歧义）。时间/风格筛没了
的话，空文案会明说「当前筛选（最近 7 天）下一条都没有。改一下筛选条件就能看到其余 N 条」
——那是一句会自我解释的提示，不重置也不会把人困住。少改一处就少一处回归面。

为什么不能写在 `open()` 里：`open` 既用于"打开列表"，也用于"筛选菜单选完之后重画"
（`showFilterMenu` 的 on_done 就是 `rebuild`）。写在那里等于"选了「已取消收藏」
立刻被拨回默认档"，筛选菜单当场失效。
--]]
function Favorites:resetFavoriteState()
    --[[--
    为什么现在连 `time` / `style` / `tag` 一起清（真机 P0-1）：

    以前只清 `favorite`，于是出现一条**能把用户永久关在收藏列表外面**的死路——
    用户选了一个风格（或时间/标签），该条件下一条收藏都没有 ⇒ `showList` 发现
    `#shown == 0`，弹一句提示就 `return nil`（列表压根没建出来）。此时用户再点
    「本书收藏」/「全部收藏」，`style` 还粘在单例上 ⇒ 又是 0 条 ⇒ 又是一句提示、
    又没有列表。**除了重启进程没有任何出口**（filter 不落盘，重启才恢复）。

    所以"回到默认档"必须是**整套**回到默认值，只清一半等于没修：
    `time` 同理（选「最近 7 天」而 7 天内没有收藏，是同一条死路）。

    默认值照抄 `Favorites.filter` 的定义（本文件 198 行），不另立一份"默认是什么"。
    --]]
    self.filter.favorite = true
    self.filter.time = "all"
    self.filter.style = nil
    self.filter.tag = nil
end

--[[--
本书收藏。
@param book_fp string|nil 当前书指纹
@param book_title string|nil 书名（没有时由 Store 回退）
--]]
function Favorites:showBookFavorites(book_fp, book_title)
    self:resetFavoriteState()
    if not book_fp then
        UIManager:show(InfoMessage:new{ text = _("当前没有打开的书。") })
        return
    end
    if book_title and book_title ~= "" then Store:noteBook(book_fp, book_title) end

    -- keep 由 `refresh()` 传进来（true = 内容变了重画，保留展开状态）；
    -- 直接调用 open() 打开新列表时它是 nil，走默认展开策略。
    local function open(keep)
        local state = self.filter.favorite
        local title = Store:bookTitle(book_fp)
        local rows = sourceForState(state, book_fp)
        self:showList(listTitle(state, title), rows, open, false,
            emptyTextForState(state, title),
            { show_filter = true, keep_expanded = (keep == true), scope_fp = book_fp })
    end
    open()
end

--[[--
全部收藏（跨书，按书名分组）。
--]]
function Favorites:showAllFavorites()
    self:resetFavoriteState()
    local function open(keep)
        local state = self.filter.favorite
        local rows = sourceForState(state, nil)
        self:showList(listTitle(state, nil), rows, open, true,
            emptyTextForState(state, nil),
            { show_filter = true, keep_expanded = (keep == true), scope_fp = nil,
              expand_reading = true })
    end
    open()
end

--[[--
跨书检索。

命中范围：**提问 / 引文 / 回答**三处都搜（理由见 Store:search）。

为什么命中要做去重：一次问答在历史里是两条记录（user 提问 + assistant 回答），
关键词同时出现在提问和回答里时，同一次问答会命中两次，列表里看着像"收藏了两条"，
实际上是一回事。所以命中的 user 记录一律换算成它配对的 assistant 记录再展示，
换算不出来（老数据没有 turn_id）就保留 user 那条。

@param book_fp string|nil 传了就只搜当前书
--]]
function Favorites:askSearch(book_fp)
    local dialog
    dialog = InputDialog:new{
        title = book_fp and _("在本书中搜索") or _("在所有书中搜索"),
        description = _("搜索提问、引文和小望的回复。"),
        input_hint = _("关键词"),
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("搜索"),
                    is_enter_default = true,
                    callback = function()
                        local q = dialog:getInputText()
                        UIManager:close(dialog)
                        q = (q or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        if q == "" then
                            UIManager:show(InfoMessage:new{ text = _("请输入关键词") })
                            return
                        end
                        self:runSearch(q, book_fp)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--[[--
@param query   string 关键词
@param book_fp string|nil 限定在某本书内（nil = 跨书）
@param opts    table|nil { ignore_filter = bool } 尾参，不改既有调用点。
               `ignore_filter == false` = 这一屏**套**当前筛选档位。只有一种来路：
               用户在检索页上**主动**打开「筛选：…」挑了档位（见 showList 那条注释）。
--]]
function Favorites:runSearch(query, book_fp, opts)
    --[[--
    **检索不套筛选**（真机新 bug：切过筛选之后搜不到确实存在的收藏）。

    望仔的原话：把筛选切到「仅已收藏」，再去搜一条**未收藏**的条目，搜不到——
    命中其实取回来了，只是被当前档位挡在门外。搜索问的是"全书里有没有这个词"，
    不是"当前筛选档位下有没有这个词"，所以默认一档都不套（`ignore_filter`）。

    档位本身**不动**：`self.filter` 一个键都不写，搜完用户回到收藏列表还是他原来
    那一档（"搜索结束时筛选档位保持原样"）。
    --]]
    local ignore_filter = not (type(opts) == "table" and opts.ignore_filter == false)
    -- 重跑时保持"这一屏套不套筛选"不变：在检索页里取消一条收藏之后，
    -- 结果页不该突然被筛选切掉一半。
    local function again(ignore)
        return function() self:runSearch(query, book_fp, { ignore_filter = ignore }) end
    end
    --[[--
    命中只按**关键词**取，筛选不在这里做（真机 P0-2）。

    以前这里传 `self:filterOpts(true)`，把 time / style / tag 一起送进 `Store:search`。
    后果是：筛选条件在 search 内部就把命中筛光了，`#incoming == 0`，
    showList 只能显示"没有找到包含「X」的问答"——用户以为书里没这个词，
    而真实原因只是筛选还开着。**"搜不到"这句话是假的**，真机上就是这么表现出来的。

    改成只传 `favorite = nil`（见下），筛选统一交给 `showList` 的 `applyFilter`
    做一次。那时 `#incoming > 0`，提示会变成"当前筛选（…）下一条都没有。
    改一下筛选条件就能看到其余 N 条"——说的是实话，而且给了出口。
    不是"先取回全部再在内存里筛"那种浪费盘的做法：筛选仍然只做一次，只是换了个层。

    **收藏状态这一档必须显式丢掉**（`favorite = nil`）：

    检索是唯一能把"取消掉的收藏"再捞回来的通路：用户记着某段话，搜出来、点进去、
    按「恢复收藏」。要是让它跟着默认的 `favorite = true` 走，取消过的条目在检索里
    也搜不到，这条通路当场断掉——而那正是这次要保住的落脚点。
    --]]
    local hits = Store:search(query, book_fp, { favorite = nil }) or {}
    local rows = {}
    local seen = {}

    for _i, hit in ipairs(hits) do
        local row = hit
        if hit.role == "user" and type(hit.turn_id) == "string" and hit.turn_id ~= "" then
            local idx = Store:indexOfTurn(hit.book_fp, hit.turn_id, "assistant")
            if idx then row = { book_fp = hit.book_fp, index = idx } end
        end
        -- 补齐展示需要的字段：定位之后重新读一遍，行是真身，不是投影
        local entry = Store:list(row.book_fp)[row.index]
        if type(entry) == "table" then
            local key = tostring(row.book_fp) .. ":" .. tostring(row.index)
            if not seen[key] then
                seen[key] = true
                local full = {
                    book_fp = row.book_fp, index = row.index,
                    ts = entry.ts, role = entry.role, kind = entry.kind,
                    content = entry.content, selection = entry.selection,
                    question = entry.question, favorite = (entry.favorite == true),
                    unfavorited_at = entry.unfavorited_at,
                    turn_id = entry.turn_id, book_title = entry.book_title,
                    chapter_title = entry.chapter_title, chapter_index = entry.chapter_index,
                    page = entry.page, style = entry.style,
                    note = entry.note, tags = entry.tags,
                }
                rows[#rows + 1] = full
            end
        end
    end

    local title = T(_("搜索「%1」"), query) -- luacheck: ignore
    -- rebuild 传"再搜一次"而不是 nil：搜索结果页里也能取消收藏，
    -- 传 nil 的话 refresh 会把列表关掉却不重建，用户会觉得"点了就没了"。
    -- ignore_favorite：检索页不认「收藏状态」这一档（见 runSearch 开头），
    -- 所以列表不再按它筛、筛选菜单里也不出这一组、标签里也不写它。
    -- expand_all：检索结果**直接展开到条目**（真机 B）——用户是奔着某个词来的，
    -- 命中就是条目本身，再垫一层"有哪几本书"只是让他多点一下。
    self:showList(title, rows, again(ignore_filter), (book_fp == nil),
        T(_("没有找到包含「%1」的问答。"), query), -- luacheck: ignore
        { show_filter = true, ignore_favorite = true, ignore_filter = ignore_filter,
          scope_fp = book_fp, expand_all = true,
          -- 用户在这一屏主动动了筛选 → 改成"套筛选"重跑（空转的入口等于坏了）
          on_filter_changed = again(false) })
end

--[[--
导出一批收藏成 Markdown。

只写在插件 data/ 之内，并且**把落盘路径明确告诉用户**：
导出物是给他自己连电脑拷走的，不给路径等于让他满硬盘找文件。

@param rows    table 行数组
@param opts    table|nil { title, name }
@return bool, string|nil
--]]
function Favorites:export(rows, opts)
    -- Export:write 的返回值是 (path, err)：路径在第一位，失败时第一个是 nil。
    -- 不要写成 (ok, path)——那样 `local p = Export:write(...)` 会拿到 true，
    -- 而 true 是 truthy，if p then 照样通过、然后拿 true 当路径用。
    local path, err = Export:write(rows, opts)
    if not path then
        UIManager:show(InfoMessage:new{
            text = T(_("导出失败：%1"), tostring(err)), -- luacheck: ignore
        })
        return false, nil
    end
    UIManager:show(InfoMessage:new{
        text = T(_("已导出 %1 条，文件在：%2\n连上电脑后从这里拷走。"),
            tostring(#(rows or {})), tostring(path)), -- luacheck: ignore
    })
    return true, path
end

--[[--
导出本书收藏。
@return bool, string|nil
--]]
function Favorites:exportBook(book_fp)
    if not book_fp then
        UIManager:show(InfoMessage:new{ text = _("当前没有打开的书。") })
        return false, nil
    end
    local rows = Store:listFavorites(book_fp)
    if #rows == 0 then
        UIManager:show(InfoMessage:new{ text = _("这本书还没有收藏，没有可导出的内容。") })
        return false, nil
    end
    return self:export(rows, { title = T(_("《%1》的收藏"), Store:bookTitle(book_fp)) }) -- luacheck: ignore
end

--[[--
导出全部收藏（跨书，按书分组）。
@return bool, string|nil
--]]
function Favorites:exportAll()
    local rows = Store:listFavorites(nil)
    if #rows == 0 then
        UIManager:show(InfoMessage:new{ text = _("还没有任何收藏，没有可导出的内容。") })
        return false, nil
    end
    return self:export(rows, { title = _("远望书友 · 全部收藏") })
end

return Favorites
