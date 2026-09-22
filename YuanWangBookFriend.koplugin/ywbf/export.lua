--[[--
把收藏导出成 Markdown（阶段二）。

**这个文件不碰网络、不碰 UI**：`render` 是纯函数（同样的行 -> 同样的字符串），
`write` 只负责挑路径、建目录、落盘。可单测是硬要求：导出错了用户看不出来，
他那本书里半年攒的笔记就那么没了。

**只写在插件 data/ 之内**（PRD §1.3：卸载即删目录即净）。导出物本来就是"给用户
自己拷走"的，写到别处等于把用户的私人文件藏在系统的角落里。

**正文不截断**：这是"回顾"，不是"摘要"。selection / content 一律全文写出，
只有那些注定单行显示的字段（比如标题行里的提问）才会收短。
中文必须走 Util.utf8sub / Util.preview，裸 string.sub 会切在汉字中间。
--]]

local Config = require("ywbf/config")
local Prompts = require("ywbf/prompts")
local Store = require("ywbf/store")
local Util = require("ywbf/util")
local _ = require("gettext")
local T = require("ffi/util").template

local Export = {}

-- 导出目录（插件 data/ 之下）
Export.DIR_NAME = "export"

-- 标题行里"提问"最多显示多少字符（正文不在此限）
Export.TITLE_CHARS = 40

--[[--
可读时间。
为什么不用裸时间戳：导出物是给人看的，1718451234 这种数字在半年后自己都认不出。
@return string
--]]
local function timeText(ts)
    if type(ts) ~= "number" or ts <= 0 then return _("未知时间") end
    local ok, text = pcall(os.date, "%Y-%m-%d %H:%M", ts)
    if ok and type(text) == "string" then return text end
    return _("未知时间")
end

--[[--
给 Markdown 用的正文：净化（保留换行）但不截断。
sanitizeUtf8 而不是 sanitizeForDisplay：后者会连 \n 一起吃掉，
段落结构没了，导出来的东西读起来是一坨。
--]]
local function bodyText(s)
    if type(s) ~= "string" then return "" end
    return Util.sanitizeUtf8(s)
end

--[[--
单行文本（标题里用）：折叠空白 + 按字符边界截断。
--]]
local function oneLine(s, max_chars)
    if Util.isEmpty(s) then return "" end
    local txt, _total, truncated = Util.preview(s, max_chars or Export.TITLE_CHARS)
    return truncated and (txt .. "…") or txt
end

--[[--
导出目录的绝对路径。
@return string|nil nil 表示 Config 还没 init（此时不该尝试落盘）
--]]
function Export:dir()
    local data = Config.paths and Config.paths.data
    if type(data) ~= "string" or data == "" then return nil end
    return data .. "/" .. Export.DIR_NAME
end

--[[--
确保导出目录存在。

lfs 的 mkdir 不会递归建父目录，data/ 是 Config:init 建的（通常已经在了），
这里补的是最后一级 export/。两条路都留着：有 lfs 就用 lfs（不 fork 进程），
没有就退回 `mkdir -p`（HOME 环境下没有 lfs，别让导出功能直接死掉）。

@return bool
--]]
local function ensureDir(path)
    if type(path) ~= "string" or path == "" then return false end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and type(lfs.attributes) == "function" and type(lfs.mkdir) == "function" then
        if lfs.attributes(path, "mode") == "directory" then return true end
        local ok = pcall(lfs.mkdir, path)
        if ok and lfs.attributes(path, "mode") == "directory" then return true end
    end
    local cmd = string.format("mkdir -p '%s'", path)
    local ok_exec = os.execute(cmd)
    -- Lua 5.1 返回整数状态码，5.2+ 返回 true/数字，两种都要认
    if ok_exec == 0 or ok_exec == true then return true end
    local f = io.open(path .. "/.ywbf_probe", "w")
    if f then
        f:write("")
        f:close()
        os.remove(path .. "/.ywbf_probe")
        return true
    end
    return false
end

--[[--
默认文件名：`远望书友-收藏-年月日-时分秒-<短随机>.md`

带短随机后缀是为了同一秒内连着导出两次时不互相覆盖
（第二次回头找，发现上一次的没了，那种丢失很难解释）。
@return string
--]]
function Export:defaultName()
    local stamp = os.date("%Y%m%d-%H%M%S") or tostring(os.time())
    local salt = Util.fnv(tostring(os.time()) .. "#" .. tostring(math.random(1000000))):sub(1, 6)
    return string.format("ywbf-favorites-%s-%s.md", stamp, salt)
end

--[[--
章节标题**自己带不带序号**？（「第十九回 …」「第 一 回 …」这种）

带了就别再套一层 `第 N 章`：导出里出现「第 2 章 第十九回 情切切良宵花解语」和
列表里出现一样糟。判断里**不许用 `[回章]` 字节类**（汉字 3 字节，字节类会误匹配），
一律 `find(x, 1, true)` 纯文本查找。

**已知边界（故意不做，不是漏了）**：同一本书里若有两条**回目名完全相同**的章节
（OCR 目录 / 重排本才会出现），去掉 `第 N 章` 前缀之后，这两处会**写得一模一样**。
分组不会并错——分组 key 里有 index 参与，两条仍然是两个章节；单纯是行文字相同，
看的人分不出它们是两个。要消掉它，就得让本函数知道"这本书里还有没有同名的另一章"，
那是往一个纯判定函数里塞书级上下文，代价和收益不成比例，故按已知边界留存。
**写下这条是为了不让它变成以后没人知道的暗坑**（与列表页那份同一口径，改一处要改两处）。

@return boolean
--]]
-- 量词表：只认「回/章」的话，碰上「第一篇 …」「第一卷 …」这类标题
-- 照样会拼出「第 2 章 第一篇 …」——还是自相矛盾，只是换了个量词。
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
位置标签："第 3 章 章节名" / "回目名" / "第 42 页"。与列表页同一口径
（同一段决策复制两遍迟早不一致，这里宁可多写三行）。

**细粒度优先**：导出和列表必须用同一套章节身份，否则列表显示「第十九回 …」、
导出却写成「第 1 章 红楼梦 上」，用户会当成没修好。
`export` 是纯逻辑层，不能去 require 收藏界面那个模块（会把 UI 拖进来），
所以这段口径就地实现一份——改的时候**两边都要改**，这是刻意的重复但不是无意的。
（别在注释里写出那个模块的完整路径：`tests/run_tests.lua` 有一条源码扫描断言
盯着"ywbf/ 层不许出现 UI 依赖"，注释里的字面量一样会被它抓到。）

@return string
--]]
local function locationText(row)
    if type(row) ~= "table" then return "" end
    local title = type(row.chapter_fine_title) == "string" and row.chapter_fine_title ~= ""
        and row.chapter_fine_title or nil
    local index = type(row.chapter_fine_index) == "number" and row.chapter_fine_index or nil
    -- 细粒度两个都缺才回落粗粒度（老数据）
    if title == nil and index == nil then
        title = type(row.chapter_title) == "string" and row.chapter_title ~= ""
            and row.chapter_title or nil
        index = type(row.chapter_index) == "number" and row.chapter_index or nil
    end
    if title and titleHasOwnOrdinal(title) then return title end
    if title and index then return T(_("第 %1 章 %2"), tostring(index), title) end
    if title then return title end
    if type(row.page) == "number" then return T(_("第 %1 页"), tostring(row.page)) end
    return ""
end

--[[--
风格显示名：一律从 Prompts.STYLES 现取，**不在这里抄一份 key -> 中文 的映射表**。
抄一份的代价是以后改风格名要改两处、迟早不同步（这个故障本项目已经发生过），
而且验收里有一条源码级断言专门盯着"export.lua 里出现风格显示名字面量"。

缺 style（老数据）或 key 已不存在时给「未知风格」，不留空、也**不输出内部 key**——
导出是给人看的文档，写 `professional` 用户看不懂（设置菜单里写的是「专业严谨」）。
@return string
--]]
local function styleText(key)
    local k = type(key) == "string" and key ~= "" and key or Store.UNKNOWN_STYLE
    if k ~= Store.UNKNOWN_STYLE then
        for _s, s in ipairs(Prompts.STYLES or {}) do
            if s and s.key == k and type(s.text) == "string" and s.text ~= "" then
                return s.text
            end
        end
    end
    return _("未知风格")
end

--[[--
按书分组：书名 -> 行数组（组内保持传入顺序，调用方已按时间倒序传进来）。
@return array of { title, rows }, count
--]]
local function groupByBook(rows)
    local by_book, order = {}, {}
    for _i, row in ipairs(rows or {}) do
        local key = Store:bookTitle(row.book_fp)
        if not by_book[key] then
            by_book[key] = {}
            order[#order + 1] = key
        end
        table.insert(by_book[key], row)
    end
    table.sort(order, function(a, b) return a < b end)
    local groups = {}
    for _g, key in ipairs(order) do
        groups[#groups + 1] = { title = key, rows = by_book[key] }
    end
    return groups
end

--[[--
渲染一篇 Markdown。纯函数：不碰磁盘，方便直接断言字符串内容。

每条收藏必须带齐八要素：书名（分组标题）/ 章节名 / 引用段落 / 我的提问 /
%1 的回复 / 备注 / 标签 / 时间。少一样都不是"完整回顾"。

@param rows table Store 的行数组
@param opts table|nil { title = string, empty_text = string }
@return string
--]]
function Export:render(rows, opts)
    opts = (type(opts) == "table") and opts or {}
    local persona = Prompts.PERSONA_NAME
    local lines = {}

    local heading = type(opts.title) == "string" and opts.title ~= "" and opts.title
        or _("远望书友 · 收藏与回顾")
    lines[#lines + 1] = "# " .. heading
    lines[#lines + 1] = T(_("导出时间：%1"), timeText(os.time())) -- luacheck: ignore

    local groups = groupByBook(rows)
    if #(rows or {}) == 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = type(opts.empty_text) == "string" and opts.empty_text
            or _("这一批没有可导出的收藏。")
        return table.concat(lines, "\n") .. "\n"
    end

    lines[#lines + 1] = T(_("共 %1 条，来自 %2 本书"), tostring(#rows), tostring(#groups)) -- luacheck: ignore

    for _g, group in ipairs(groups) do
        lines[#lines + 1] = ""
        lines[#lines + 1] = "## " .. T(_("《%1》"), group.title) -- luacheck: ignore

        for _r, row in ipairs(group.rows) do
            local question = Store:questionFor(row.book_fp, row.index)
            local head = oneLine(question ~= "" and question or row.content)
            local loc = locationText(row)
            local tags = type(row.tags) == "table" and #row.tags > 0
                and table.concat(row.tags, "、") or nil

            lines[#lines + 1] = ""
            lines[#lines + 1] = "### " .. (head ~= "" and head or _("（没有提问）"))
            if loc ~= "" then
                lines[#lines + 1] = T(_("- 位置：%1"), loc) -- luacheck: ignore
            end
            lines[#lines + 1] = T(_("- 时间：%1"), timeText(row.ts)) -- luacheck: ignore
            lines[#lines + 1] = T(_("- 风格：%1"), styleText(row.style)) -- luacheck: ignore
            if tags then
                lines[#lines + 1] = T(_("- 标签：%1"), tags) -- luacheck: ignore
            end
            if type(row.note) == "string" and Util.trim(row.note) ~= "" then
                lines[#lines + 1] = ""
                lines[#lines + 1] = _("【我的备注】")
                lines[#lines + 1] = bodyText(row.note)
            end

            --[[--
            引文先 `keepParagraphs` 再导出：与收藏详情页同一口径
            （`ui/favorites.lua` 的 entryText），导出物里也要是原文的段落结构。
            顺序不能反：`sanitizeUtf8` 只管非法码点，压不掉 epub 那一串空行；
            `keepParagraphs` 会先做过一遍控制字符净化（保留 \n / \t）。
            --]]
            if type(row.selection) == "string" and Util.trim(row.selection) ~= "" then
                lines[#lines + 1] = ""
                lines[#lines + 1] = Prompts.QUOTE_LABEL
                lines[#lines + 1] = Util.sanitizeUtf8(Util.keepParagraphs(row.selection))
            end

            if question ~= "" then
                lines[#lines + 1] = ""
                lines[#lines + 1] = _("【我的提问】")
                lines[#lines + 1] = bodyText(question)
            end

            lines[#lines + 1] = ""
            lines[#lines + 1] = T(_("【%1的回复】"), persona) -- luacheck: ignore
            lines[#lines + 1] = bodyText(row.content)

            lines[#lines + 1] = ""
            lines[#lines + 1] = "---"
        end
    end

    return table.concat(lines, "\n") .. "\n"
end

--[[--
把外部传来的文件名收成"只剩文件名"：去掉目录分隔符与 `..`。

`path = dir .. "/" .. name` 是原样拼接，name 里带 `../../` 就能写到插件目录之外，
直接绕过"零污染"这条约束（PRD §1.3）。今天 UI 不传 `name`，所以不可达——
但这是**输入校验**，不该押在"调用方不会传"上（阶段三若要开放自定义文件名，
一接上就是个越界写）。
@return string|nil 非法输入返回 nil（调用方退回默认名）
--]]
local function safeName(name)
    if type(name) ~= "string" then return nil end
    local base = name:gsub("^.*[/\\]", "")
    base = base:gsub("%.%.", "")
    -- 控制字符也必须清掉（含 NUL）：C 层会把 `probe\0.md` 截断成 `probe` 落盘，
    -- 而我们返回的路径里仍带 NUL——**返回的路径与真实落点不一致**，
    -- 谁拿这个返回值去读就会读不到。宁可退回默认名，也不给一个对不上的路径。
    base = base:gsub("%c", "")
    base = Util.trim(base)
    -- 只剩点号的名字（"." 或 ".." 去掉上跳后的残骸）当作非法：
    -- 写是写不进去的，与其靠 io.open 失败兜住，不如在护栏里判干净。
    if base == "" or base == "." then return nil end
    return base
end

--[[--
写盘。只写在插件 data/ 之内一处，别处一概不碰。
**每个返回值的位置**：**路径在第一位**（成功 `path, nil` / 失败 `nil, 原因`）。
不放 `(ok, path)` 是因为照规格写 `local p = Export:write(...)` 会拿到 `true`——
而 `true` 是 truthy，`if p then` 照样通过、然后拿 `true` 当路径用，会静默出错。

@param rows table 行数组
@param opts table|nil { name = string, title = string, empty_text = string }
@return string|nil, string|nil 成功时第一个是落盘路径；失败时第一个是 nil、第二个是原因
--]]
function Export:write(rows, opts)
    opts = (type(opts) == "table") and opts or {}
    local dir = self:dir()
    if not dir then return nil, _("插件数据目录还没有准备好") end
    if not ensureDir(dir) then return nil, T(_("建不了导出目录：%1"), dir) end

    local name = safeName(opts.name) or self:defaultName()
    local path = dir .. "/" .. name
    local text = self:render(rows, opts)
    local ok_write = Config._write_file(path, text)
    if not ok_write then return nil, T(_("写文件失败：%1"), path) end
    return path, nil
end

return Export
