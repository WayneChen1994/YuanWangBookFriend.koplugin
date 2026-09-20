--[[--
「我的收藏」：按书回顾收藏过的问答，并支持跨书检索。

设计上的三条硬约束：

1. **收藏不是一份新文件**。它就是 history 条目上的一个 `favorite` 字段
   （理由写在 ywbf/store.lua 开头）。所以本文件不持有任何数据，全部现读 Store。
2. **问答成对展示**。收藏的是 assistant 那一条，提问由 Store:questionFor 带出来
   （先读条目自带的 question 字段，读不到再按 turn_id 回查同轮 user 条目）。
   列表里一个问答只出现一次——把 user 那一条也列进来只会显得重复。
3. **列表项摘要必须按字符截**（Util.preview / Util.utf8sub）：中文 3 字节，
   裸 string.sub 会切在汉字中间变乱码。

列表用 KOReader 的 Menu：分页、滚动、返回手势都是现成的，自己拼一个反而要重新踩一遍。
分组靠 select_enabled = false 的"标题行"实现（Menu 对这种行不做任何响应）。
--]]--

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
Favorites.filter = { time = "all", style = nil, tag = nil }

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
位置标签：「第 3 章 章节名」/「章节名」/「第 42 页」/ 都没有就给空串。
老数据没有章节字段，也不要硬凑一个"未知位置"占位——没有就是没有。
--]]
local function chapterLabel(row)
    if type(row) ~= "table" then return "" end
    local title = type(row.chapter_title) == "string" and row.chapter_title ~= "" and row.chapter_title or nil
    local index = type(row.chapter_index) == "number" and row.chapter_index or nil
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
列表项的一行摘要。
跨书列表已经在分组标题里写过书名了，这里不重复写（show_group_title = false）。
--]]
function Favorites:rowText(row, show_group_title)
    if type(row) ~= "table" then return "" end
    local book = show_group_title and (Store:bookTitle(row.book_fp)) or nil
    local loc = chapterLabel(row)
    local q = Store:questionFor(row.book_fp, row.index)
    local head = q ~= "" and brief(q) or brief(row.content)
    local parts = {}
    if book then parts[#parts + 1] = book end
    if loc ~= "" then parts[#parts + 1] = loc end
    local prefix = table.concat(parts, " · ")
    local marks = rowMarks(row)
    local core = (prefix ~= "") and (prefix .. " — " .. head) or head
    if marks ~= "" then return core .. "  [" .. marks .. "]" end
    return core
end

--[[--
一条收藏的完整文本（给 TextViewer）。

顺序按"回想一段问答时的自然顺序"：先说这是哪一本书、哪一章（定位），
再给当时引用的段落（上下文），然后是提问，最后是回答。
--]]
function Favorites:entryText(row)
    if type(row) ~= "table" then return "" end
    local lines = {}

    local loc = chapterLabel(row)
    local head = loc ~= "" and (Store:bookTitle(row.book_fp) .. " · " .. loc) or Store:bookTitle(row.book_fp)
    lines[#lines + 1] = T(_("【%1】"), head) -- luacheck: ignore

    if type(row.note) == "string" and Util.trim(row.note) ~= "" then
        lines[#lines + 1] = _("【我的备注】")
        lines[#lines + 1] = row.note
    end

    if type(row.tags) == "table" and #row.tags > 0 then
        lines[#lines + 1] = T(_("【标签】%1"), table.concat(row.tags, "、")) -- luacheck: ignore
    end

    if type(row.selection) == "string" and row.selection ~= "" then
        lines[#lines + 1] = _("【引用的段落】")
        lines[#lines + 1] = row.selection
    end

    local q = Store:questionFor(row.book_fp, row.index)
    if q ~= "" then
        lines[#lines + 1] = _("【你的提问】")
        lines[#lines + 1] = q
    end

    lines[#lines + 1] = T(_("【%1的回复】"), Prompts.PERSONA_NAME) -- luacheck: ignore
    lines[#lines + 1] = row.content or ""

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
--]]
function Favorites:askNote(row, on_changed)
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
                        self:showEntry(row, on_changed)
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
function Favorites:askTags(row, on_changed)
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
                        self:showEntry(row, on_changed)
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
--]]
function Favorites:showEntry(row, on_changed)
    if type(row) ~= "table" then return end
    local viewer

    local fav_id = "ywbf_fav_toggle"
    local function refreshButtons()
        local btn = viewer and viewer.button_table and viewer.button_table:getButtonById(fav_id)
        if btn and btn.setText then
            btn:setText(Store:isFavorite(row.book_fp, row.index) and _("取消收藏") or _("收藏"))
        end
    end

    viewer = TextViewer:new{
        title = _("收藏的问答"),
        text = self:entryText(row),
        buttons_table = {
            {
                {
                    id = fav_id,
                    text = Store:isFavorite(row.book_fp, row.index) and _("取消收藏") or _("收藏"),
                    callback = function()
                        local now = Store:setFavorite(row.book_fp, row.index,
                            not Store:isFavorite(row.book_fp, row.index))
                        if now == nil then
                            UIManager:show(InfoMessage:new{
                                text = _("这条记录已经不在历史里了"),
                            })
                            return
                        end
                        refreshButtons()
                        UIManager:show(InfoMessage:new{
                            text = now and _("已收藏") or _("已取消收藏"),
                        })
                        if on_changed then on_changed() end
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
                        self:askNote(row, on_changed)
                    end,
                },
                {
                    id = "ywbf_fav_tags",
                    text = _("标签"),
                    callback = function()
                        UIManager:close(viewer)
                        self:askTags(row, on_changed)
                    end,
                },
            },
            {
                {
                    -- 删除是唯一不可撤销的动作，必须二次确认：
                    -- 一条收藏往往翻了好几页才找到，误删就没了。
                    text = _("删除"),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = _("删除这条问答记录？删除后无法恢复。"),
                            ok_text = _("删除"),
                            cancel_text = _("取消"),
                            ok_callback = function()
                                local ok = Store:delete(row.book_fp, { row.index })
                                UIManager:close(viewer)
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
                    callback = function() UIManager:close(viewer) end,
                },
            },
        },
    }
    UIManager:show(viewer)
end

--[[--
当前筛选条件翻译成 Store 的 opts。

`since` 当场现算：不存时间戳快照，否则"最近 7 天"会随着快照一天天变宽，
用户第二天看到的就不是他要的那 7 天了。

@return table { since, style, tag }
--]]
function Favorites:filterOpts()
    local since = nil
    for _i, p in ipairs(Favorites.TIME_PRESETS) do
        if p.key == self.filter.time and type(p.days) == "number" then
            since = os.time() - p.days * 86400
        end
    end
    return { since = since, style = self.filter.style, tag = self.filter.tag }
end

--[[--
在一批行上应用当前筛选。
@return table 新数组
--]]
function Favorites:applyFilter(rows)
    return Store:filterRows(rows, self:filterOpts())
end

--[[--
筛选条件的单行说明（放在列表第一行的入口上）。
--]]
function Favorites:filterLabel()
    return timePresetText(self.filter.time) .. " · " .. styleFilterText(self.filter.style)
end

--[[--
筛选菜单：时间预设 + 风格。**不做日期选择器**（理由见 TIME_PRESETS 的注释）。

选中之后关掉自己、回调让调用方重画列表：菜单+菜单叠在一起时上面那层点不动，
和输入框叠弹层是同一个坑。

@param on_done function 选完调用（调用方在这里重建列表）
--]]
function Favorites:showFilterMenu(on_done)
    local menu = nil
    local function pick(apply)
        apply()
        if menu then UIManager:close(menu) end
        if on_done then on_done() end
    end

    local items = {}
    items[#items + 1] = { text = _("时间范围"), select_enabled = false }
    for _i, preset in ipairs(Favorites.TIME_PRESETS) do
        local key = preset.key
        local mark = (self.filter.time == key) and "✓ " or ""
        items[#items + 1] = {
            text = mark .. _(preset.text),
            callback = function() pick(function() self.filter.time = key end) end,
        }
    end

    items[#items + 1] = { text = _("回复风格"), select_enabled = false }
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
    UIManager:show(menu)
    return menu
end

--[[--
把若干行画成一个 Menu。

@param title    string
@param rows     table 行数组（Store 的行格式）
@param rebuild  function 需要重画时调用它（删/取消收藏/改完筛选之后要重新读一遍数据）
@param group    bool 是否按书名分组（跨书列表用）
@param empty_text string 一条都没有时的提示
@param opts     table|nil { show_filter = bool } 给不给"筛选"入口
--]]
function Favorites:showList(title, rows, rebuild, group, empty_text, opts)
    local incoming = (type(rows) == "table") and rows or {}
    local use_filter = type(opts) == "table" and opts.show_filter == true
    local shown = use_filter and self:applyFilter(incoming) or incoming

    if #shown == 0 then
        -- 筛没了和本来就没有是两回事：前者要提示"改条件"，后者才是"还没有收藏"
        local text = empty_text or _("还没有收藏。")
        if use_filter and #incoming > 0 then
            text = T(_("当前筛选（%1）下一条都没有。改一下筛选条件就能看到其余 %2 条。"),
                self:filterLabel(), tostring(#incoming)) -- luacheck: ignore
        end
        UIManager:show(InfoMessage:new{ text = text })
        return nil
    end

    local items = {}
    -- 删掉/取消收藏之后要重画列表。重画前**必须先关掉当前这一层**：
    -- Menu 不会自己重新读数据（改 item_table 也不会重排分页），重建是唯一办法，
    -- 而两层列表叠在一起时，上面那层会挡住下面那层的点击（真机踩过同样的坑）。
    local current_menu = nil
    local function refresh()
        if current_menu then UIManager:close(current_menu) end
        if rebuild then rebuild() end
    end

    -- 筛选入口放最上面：它是"这一屏有哪些行"的开关，藏在下面等于没有。
    -- 点了之后先关掉当前列表再开筛选菜单（菜单叠菜单点不动，真机踩过）。
    if use_filter then
        items[#items + 1] = {
            text = T(_("筛选：%1"), self:filterLabel()), -- luacheck: ignore
            callback = function()
                if current_menu then UIManager:close(current_menu) end
                self:showFilterMenu(function() if rebuild then rebuild() end end)
            end,
        }
    end

    -- 分组：按书名的字典序，组内按时间倒序（rows 已经是倒序传入的，
    -- 排序时保持相对次序即可）。
    if group then
        local by_book = {}
        local order = {}
        for _i, row in ipairs(shown) do
            local key = Store:bookTitle(row.book_fp)
            if not by_book[key] then
                by_book[key] = {}
                order[#order + 1] = key
            end
            table.insert(by_book[key], row)
        end
        table.sort(order, function(a, b) return a < b end)
        for _b, key in ipairs(order) do
            -- select_enabled = false：Menu 对这种行不做任何响应（纯标题）
            items[#items + 1] = { text = key, select_enabled = false }
            for _r, row in ipairs(by_book[key]) do
                items[#items + 1] = {
                    text = self:rowText(row, false),
                    callback = function()
                        self:showEntry(row, refresh)
                    end,
                }
            end
        end
    else
        for _i, row in ipairs(shown) do
            items[#items + 1] = {
                text = self:rowText(row, true),
                callback = function()
                    self:showEntry(row, refresh)
                end,
            }
        end
    end

    current_menu = Menu:new{
        title = title,
        item_table = items,
    }
    UIManager:show(current_menu)
    logger.info(string.format("YWBF: favorites list shown, rows=%d shown=%d grouped=%s",
        #incoming, #shown, tostring(group == true)))
    return current_menu
end

--[[--
本书收藏。
@param book_fp string|nil 当前书指纹
@param book_title string|nil 书名（没有时由 Store 回退）
--]]
function Favorites:showBookFavorites(book_fp, book_title)
    if not book_fp then
        UIManager:show(InfoMessage:new{ text = _("当前没有打开的书。") })
        return
    end
    if book_title and book_title ~= "" then Store:noteBook(book_fp, book_title) end

    local function open()
        local rows = Store:listFavorites(book_fp)
        self:showList(T(_("《%1》的收藏"), Store:bookTitle(book_fp)), rows, open, false,
            _("这本书还没有收藏。看到好的回答，在结果卡片上点「收藏」就会存到这里。"),
            { show_filter = true })
    end
    open()
end

--[[--
全部收藏（跨书，按书名分组）。
--]]
function Favorites:showAllFavorites()
    local function open()
        local rows = Store:listFavorites(nil)
        self:showList(_("全部收藏"), rows, open, true,
            _("还没有任何收藏。看到好的回答，在结果卡片上点「收藏」就会存到这里。"),
            { show_filter = true })
    end
    open()
end

--[[--
跨书检索。

命中范围：**提问 / 引用的段落 / 回答**三处都搜（理由见 Store:search）。

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
        description = _("搜索提问、引用的段落和小望的回复。"),
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

function Favorites:runSearch(query, book_fp)
    -- 筛选条件直接传给 Store:search（第三个参数）：检索和筛选是同一件事的两半，
    -- 先取回全部再在内存里筛，结果一样但白读一遍盘。
    local hits = Store:search(query, book_fp, self:filterOpts()) or {}
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
    self:showList(title, rows, function() self:runSearch(query, book_fp) end, (book_fp == nil),
        T(_("没有找到包含「%1」的问答。"), query), -- luacheck: ignore
        { show_filter = true })
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
