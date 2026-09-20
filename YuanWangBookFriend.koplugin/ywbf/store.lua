--[[--
对话记录与 X-Ray 数据持久化（PRD F8.1/F8.3：全部本地，按书分文件）。
目录：data/history/<书籍指纹>.json 与 data/xray/<书籍指纹>.json

收藏与回顾（阶段一）：

**收藏为什么不是一份新文件**：收藏就是 history 条目上的一个 `favorite` 字段。
另建 data/favorites.json 看着更"干净"，但两份数据迟早不同步——用户从列表里删掉一条问答、
或者历史的书整体清掉了，收藏列表里还会留着一条指向空处的记录。
一条数据只有一个真身，收藏只是它的一个属性。

**一轮问答为什么用 turn_id 绑起来**：历史上 user / assistant 是两条独立 entry，
收藏时以 **assistant 条目**为准（用户收藏的是"回答"），但列表里必须显示"当时问的是什么"。
靠相邻位置猜不可靠（中间可能插入别的轮），所以写入时给同一轮的两条发同一个 turn_id。

**老数据（没有这些字段）要能读**：新字段一律按"缺失即默认"处理，不做读取时的自动迁移——
迁移要写用户的存量文件，风险大于收益；用到时回退即可。
--]]--

local Config = require("ywbf/config")
local Util = require("ywbf/util")
local json = require("json")

local Store = {}

-- 风格未知的占位 key：老数据（阶段一之前写入的条目）没有 style 字段。
-- 筛选用它把"没风格"单独拎出来——缺字段不等于不该被筛到。
Store.UNKNOWN_STYLE = "unknown"

-- 书名回退：老数据没有 book_title，展示时统一用它
Store.UNKNOWN_BOOK = "未知书"

local function file_for(dir, book_fp)
    if not dir or not book_fp then return nil end
    return string.format("%s/%s.json", dir, tostring(book_fp))
end

-- 书名索引（fp -> { title, last_ts }）。放在 data/ 下，与历史同级。
local function books_path()
    if not Config.paths or not Config.paths.data then return nil end
    return Config.paths.data .. "/books.json"
end

local function load_table(path)
    local raw = path and Config._read_file(path)
    if raw and #raw > 0 then
        local ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == "table" then return decoded end
    end
    return {}
end

local function save_table(path, t)
    if not path then return false end
    local ok, encoded = pcall(json.encode, t)
    if not ok then return false end
    return Config._write_file(path, encoded)
end

--[[--
生成一轮问答的唯一 id。

为什么不用纯时间戳：同一秒里完全可以连着问两个问题（轻问是提交即返回，更容易撞）。
再拼一个进程内自增序号和一个随机分量，重复概率压到可忽略。
--]]
local turn_seq = 0
function Store:newTurnId()
    turn_seq = turn_seq + 1
    return string.format("t%d-%d-%s", os.time(), turn_seq,
        Util.fnv(tostring(os.time()) .. "#" .. tostring(turn_seq) .. "#" .. tostring(math.random(1000000))))
end

-- ---------- 书名索引 ----------

--[[--
记下"这本书叫什么"。打开书或写入历史时调用。

为什么需要它：跨书列表要按书名分组，而 history 文件按 fp 命名，
书名只在**有问答记录**的条目里才有。没有索引的话，一本刚开始读、
还没有问答的书在跨书列表里连"未知书"都撑不起来（连 fp 都没有）。

已知书名不会被 nil 覆盖：信息只能被更具体的信息替换。

@return bool 是否落盘成功
--]]
function Store:noteBook(book_fp, book_title)
    if not book_fp then return false end
    local path = books_path()
    if not path then return false end
    local idx = load_table(path)
    local rec = type(idx[book_fp]) == "table" and idx[book_fp] or {}

    if type(book_title) == "string" and book_title ~= "" then
        rec.title = book_title
    end
    rec.last_ts = os.time()
    idx[book_fp] = rec
    return save_table(path, idx)
end

--[[--
书名索引信息。
@return table|nil { title, last_ts }
--]]
function Store:bookInfo(book_fp)
    if not book_fp then return nil end
    local idx = load_table(books_path())
    local rec = idx[book_fp]
    if type(rec) ~= "table" then return nil end
    return rec
end

--[[--
书名（展示用）。
@return string 一定有值：取不到时回退 Store.UNKNOWN_BOOK
--]]
function Store:bookTitle(book_fp)
    local rec = self:bookInfo(book_fp)
    if rec and type(rec.title) == "string" and rec.title ~= "" then return rec.title end
    return Store.UNKNOWN_BOOK
end

-- ---------- 对话历史 ----------

-- ---------- 备注与标签 ----------

--[[--
把外部传来的 tags 收成统一的数组形式：只留非空字符串、去空白、去重。
空结果一律返回 nil（不写空数组进文件：空数组对"有没有标签"这个问题的答案是含糊的）。

@param tags table|string 数组，或逗号分隔的字符串
@return table|nil
--]]
local function normalizeTagList(tags)
    local source = tags
    if type(source) == "string" then source = Store.parseTags(source) end
    if type(source) ~= "table" then return nil end
    local out, seen = {}, {}
    for _i, raw in ipairs(source) do
        local t = (type(raw) == "string") and Util.trim(raw) or nil
        if t and t ~= "" and not seen[t] then
            seen[t] = true
            out[#out + 1] = t
        end
    end
    if #out == 0 then return nil end
    return out
end

--[[--
把用户输入的标签串切成数组。

必须同时认**中文逗号和英文逗号**：墨水屏上的中文输入法默认给的是「，」
（用户不会为了填标签特意切输入法），只认半角的话等于让一半用户填不进去。

@gsub input string
@return table 可能为空表（表示"一个标签都没留下"），不返回 nil
--]]
function Store.parseTags(input)
    local out = {}
    if type(input) ~= "string" then return out end
    --[[--
    先把全角逗号换成半角，再用 `[^,]` 切。

    为什么不直接写 `[^,，]+`：**Lua 的模式是字节级的**，那个方括号类实际等于
    "不是 0x2C、不是 0xEF、不是 0xBC、不是 0x8C 的字节"。全角逗号" ，"的
    三个字节都被排除了（这部分碰巧对了），但任何**包含** 0xBC / 0x8C 的汉字
    也会被切开——"伏"是 E4 BC 8F，正好含 0xBC，于是被切成一个残缺的字节。
    （这个坑和之前 `[^？?]` 那个是同一个：字节类不等于字符类。）

    换成半角之后 `[^,]` 就是安全的：UTF-8 的续字节是 0x80–0xBF、首字节 ≥ 0xC2，
    没有任何一个字节会等于 0x2C。
    --]]
    local normalized = input:gsub("，", ",")
    local seen = {}
    for raw in normalized:gmatch("[^,]+") do
        local t = Util.trim(raw)
        -- 去重必须在 trim 之后：不 trim 的话「甲」和「甲 」是两个不同字符串，去重会失效。
        -- parseTags 是**公开**方法，必须自己给出完整结果（切分+去空白+丢空串+去重），
        -- 不能把正确性押在"调用方记得再走一遍 normalizeTagList"。
        if t ~= "" and not seen[t] then
            seen[t] = true
            out[#out + 1] = t
        end
    end
    return out
end

--[[--
写备注。
@param book_fp string
@param index number 1-based
@param text string|nil 空串或 nil 表示**清空**备注
@return bool 是否落盘成功（条目不存在返回 false，与 setFavorite 的口径不同：
       这里没有"返回新值"的意义，成功/失败就是 bool）
--]]
function Store:setNote(book_fp, index, text)
    if not book_fp or type(index) ~= "number" then return false end
    local path = file_for(Config.paths.history, book_fp)
    local data = load_table(path)
    local entries = data.entries or {}
    local e = entries[index]
    if type(e) ~= "table" then return false end
    if type(text) == "string" and Util.trim(text) ~= "" then
        e.note = text
    else
        e.note = nil
    end
    -- 只动这一个键：其余字段（question / tags / favorite...）原样写回，
    -- 否则"改备注会把别的字段冲掉"就是标准的数据损坏。
    return save_table(path, data)
end

--[[--
写标签。
@param book_fp string
@param index number 1-based
@param tags table|string 逗号分隔的串，或字符串数组；空则清空
@return bool 是否落盘成功
--]]
function Store:setTags(book_fp, index, tags)
    if not book_fp or type(index) ~= "number" then return false end
    local path = file_for(Config.paths.history, book_fp)
    local data = load_table(path)
    local entries = data.entries or {}
    local e = entries[index]
    if type(e) ~= "table" then return false end
    e.tags = normalizeTagList(tags)
    return save_table(path, data)
end

--[[--
读备注（没有就返回 nil，不返回空串：UI 用它区分"有备注"和"没备注"）。
--]]
function Store:noteOf(book_fp, index)
    if not book_fp or type(index) ~= "number" then return nil end
    local e = self:list(book_fp)[index]
    if type(e) ~= "table" then return nil end
    return type(e.note) == "string" and e.note or nil
end

--[[--
读标签（没有就返回空表：遍历长度比判 nil 省一层，也不许返回 nil 让调用方去 pcall）。
--]]
function Store:tagsOf(book_fp, index)
    if not book_fp or type(index) ~= "number" then return {} end
    local e = self:list(book_fp)[index]
    if type(e) ~= "table" then return {} end
    if type(e.tags) ~= "table" then return {} end
    local out = {}
    for _i, t in ipairs(e.tags) do
        if type(t) == "string" and t ~= "" then out[#out + 1] = t end
    end
    return out
end

-- ---------- 按时间与风格筛选 ----------

--[[--
条目是否命中筛选条件。

时间语义：**两端都含**（`since <= ts <= until`）。选"最近 7 天"时用户脑子里是
"包含此刻在内的这 7 天"，端点开关差一天都会在边界那一天给用户错误的惊喜。

风格：缺 `style` 字段的老数据按 `UNKNOWN_STYLE` 参与比较，所以它既不会被随便算成
某个具体风格，也能被"未知风格"这一项单独筛出来。

@return bool
--]]
local function matchesFilters(e, opts)
    if type(opts) ~= "table" then return true end
    if type(e) ~= "table" then return false end

    local ts = type(e.ts) == "number" and e.ts or 0
    local since = opts.since
    if type(since) == "number" and ts < since then return false end
    -- opts["until"] 而不是 opts.until：until 是 Lua 5.1 的关键字，点号取字段会语法报错
    local until_ts = opts["until"]
    if type(until_ts) == "number" and ts > until_ts then return false end

    local want_style = opts.style
    if type(want_style) == "string" and want_style ~= "" then
        local key = (type(e.style) == "string" and e.style ~= "") and e.style or Store.UNKNOWN_STYLE
        if key ~= want_style then return false end
    end

    local want_tag = opts.tag
    if type(want_tag) == "string" and want_tag ~= "" then
        local found = false
        if type(e.tags) == "table" then
            for _i, t in ipairs(e.tags) do
                if t == want_tag then found = true end
            end
        end
        if not found then return false end
    end

    return true
end

--[[--
在一批行上应用筛选（给列表页用：收藏列表 / 检索结果的对象都是行）。

@param rows table Store 的行数组
@param opts table|nil { since, until, style, tag }
@return table 新数组（不改动传入的数组）
--]]
function Store:filterRows(rows, opts)
    local out = {}
    for _i, row in ipairs(rows or {}) do
        if matchesFilters(row, opts) then out[#out + 1] = row end
    end
    return out
end

--[[--
把外部传来的 entry 收成内部记录格式。缺字段一律补默认值（老数据兼容的落点就在这里）。

note / tags 也是"缺失即没有"：老条目本来就没有这两个键，读进来仍是 nil，
绝不在这里给它们补 "" 或 {} —— 补了以后"用户从来没写过备注"和"用户写了又删了"
在数据上就没区别了。
--]]
local function makeRecord(entry)
    local e = entry or {}
    return {
        ts = os.time(),
        role = e.role or "user",
        kind = e.kind or "chat",
        content = e.content or "",
        selection = e.selection or "",
        turn_id = type(e.turn_id) == "string" and e.turn_id or nil,
        favorite = (e.favorite == true),
        book_fp = type(e.book_fp) == "string" and e.book_fp or nil,
        book_title = type(e.book_title) == "string" and e.book_title or nil,
        chapter_title = type(e.chapter_title) == "string" and e.chapter_title or nil,
        chapter_index = type(e.chapter_index) == "number" and e.chapter_index or nil,
        page = type(e.page) == "number" and e.page or nil,
        question = type(e.question) == "string" and e.question or nil,
        style = type(e.style) == "string" and e.style or nil,
        note = type(e.note) == "string" and e.note ~= "" and e.note or nil,
        tags = normalizeTagList(e.tags),
    }
end

--[[--
把一条记录投影成给 UI 用的行（带上定位需要的 book_fp / index）。
所有列表类接口的返回形状统一用它，调用方不必自己拼字段。
--]]
local function toRow(book_fp, index, e)
    return {
        book_fp = book_fp,
        index = index,
        ts = e.ts,
        role = e.role,
        kind = e.kind,
        content = e.content,
        selection = e.selection,
        question = e.question,
        favorite = (e.favorite == true),
        turn_id = e.turn_id,
        book_title = e.book_title,
        chapter_title = e.chapter_title,
        chapter_index = e.chapter_index,
        page = e.page,
        style = e.style,
        note = e.note,
        tags = e.tags,
    }
end

--[[--
追加一条记录。

@param book_fp string
@param entry table 见 makeRecord
@return bool 是否写入成功
--]]
function Store:append(book_fp, entry)
    if not book_fp then return false end
    local path = file_for(Config.paths.history, book_fp)
    local data = load_table(path)
    data.entries = data.entries or {}
    table.insert(data.entries, makeRecord(entry))
    if entry and type(entry.book_title) == "string" and entry.book_title ~= "" then
        self:noteBook(book_fp, entry.book_title)
    end
    return save_table(path, data)
end

function Store:list(book_fp)
    if not book_fp then return {} end
    local data = load_table(file_for(Config.paths.history, book_fp))
    return data.entries or {}
end

--[[--
按 turn_id 定位条目。
@param role string|nil 传了就只认这个角色
@return number|nil index（1-based）
--]]
function Store:indexOfTurn(book_fp, turn_id, role)
    if not book_fp or type(turn_id) ~= "string" or turn_id == "" then return nil end
    local entries = self:list(book_fp)
    for idx, e in ipairs(entries) do
        if e.turn_id == turn_id and (role == nil or e.role == role) then
            return idx
        end
    end
    return nil
end

--[[--
倒序找最后一条 content 完全相同的条目。

用在哪儿：命中缓存的那一轮**不会再写历史**（否则同一个问题反复提问会不断堆叠），
但用户照样看得到结果卡片、也照样想收藏它。这时用回答原文把之前那条找回来。
只在本书范围内找，且必须匹配角色——不要把 user 的提问当成 assistant 的回答。

**顺带跳过 ideas**：收藏池已经保证 ideas 永不入选，回查是收藏按钮的另一条入口
（缓存命中时 locateStoredTurn 走的就是这里），两条路必须收同样的口径，
否则"列表里没有它、但按原文能把它找回来"，收藏池就漏了。

@return number|nil index
--]]
function Store:indexOfContent(book_fp, content, role)
    if not book_fp or type(content) ~= "string" or content == "" then return nil end
    local entries = self:list(book_fp)
    for idx = #entries, 1, -1 do
        local e = entries[idx]
        if e.content == content and (role == nil or e.role == role) and e.kind ~= "ideas" then
            return idx
        end
    end
    -- ideas 永远不当作"找回来了"：它是 AI 生成的候选项，不是一轮问答
    return nil
end

--[[--
某本书里最后一条助理回答。用于"查看最近回复"在内存字段失效时回退。
@return number|nil, table|nil index 与行
--]]
function Store:lastAssistant(book_fp)
    if not book_fp then return nil, nil end
    local entries = self:list(book_fp)
    for idx = #entries, 1, -1 do
        if entries[idx].role == "assistant" then
            return idx, toRow(book_fp, idx, entries[idx])
        end
    end
    return nil, nil
end

--[[--
取一条收藏/回答对应的**提问**。

顺序：① 条目自带的 question 字段 → ② 同 turn_id 的 user 条目 → ③ 空字符串。
② 主要给"整段没有提问句"的场景兜底（长按直接释义时 question 可能为空，
但 user 条目仍然记着当时的上下文行）。

@return string 取不到时返回 ""（不是 nil：UI 拼接字符串时更安全）
--]]
function Store:questionFor(book_fp, index)
    if not book_fp or type(index) ~= "number" then return "" end
    local entries = self:list(book_fp)
    local e = entries[index]
    if type(e) ~= "table" then return "" end
    if type(e.question) == "string" and e.question ~= "" then return e.question end

    if type(e.turn_id) == "string" and e.turn_id ~= "" then
        for _i, other in ipairs(entries) do
            if other.turn_id == e.turn_id and other.role == "user" then
                return other.content or ""
            end
        end
    end
    return ""
end

--[[--
设置收藏标记。
@param book_fp string
@param index number 1-based
@param value bool true = 收藏，false = 取消
@return bool|nil 成功返回新的收藏状态；书或条目不存在时返回 nil
--]]
function Store:setFavorite(book_fp, index, value)
    if not book_fp or type(index) ~= "number" then return nil end
    local path = file_for(Config.paths.history, book_fp)
    local data = load_table(path)
    local entries = data.entries or {}
    local e = entries[index]
    if type(e) ~= "table" then return nil end
    e.favorite = (value == true)
    if save_table(path, data) then return e.favorite end
    return nil
end

function Store:isFavorite(book_fp, index)
    if not book_fp or type(index) ~= "number" then return false end
    local e = self:list(book_fp)[index]
    if type(e) ~= "table" then return false end
    return e.favorite == true
end

--[[--
收藏列表。

**只收 assistant 条目**：用户收藏的是"这段回答"，提问由 questionFor 带出来；
把 user 那一条也列进来只会让同一个问答在列表里出现两次。

**永不收 ideas**：收藏的是"我问过小望的一轮问答"，而 ideas 是 AI 生成的候选项，
从来不是一轮问答。今天唯一会写历史的入口（asker.lua 的 recordTurn）已经挡住了 ideas，
所以这条过滤在当前是防不住任何真实数据的；留着它是为了不把这条语义押在那一个调用点上——
阶段二要做导入 / 批量整理，append 的入口一多，单点迟早漏。

@param book_fp string|nil nil = 跨书
@return table 按时间倒序的行数组
--]]
function Store:listFavorites(book_fp)
    local rows = {}
    local targets = {}
    if book_fp then
        targets = { book_fp }
    else
        targets = Store:books()
    end
    for _b, fp in ipairs(targets) do
        local entries = Store:list(fp)
        for idx, e in ipairs(entries) do
            if e.favorite == true and e.role == "assistant" and e.kind ~= "ideas" then
                rows[#rows + 1] = toRow(fp, idx, e)
            end
        end
    end
    table.sort(rows, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
    return rows
end

--[[--
全文搜索。

    为什么三条字段都要搜：回想一段问答时，人脑子里可能只有书中那句话（selection）、
只有自己当时问的话（question），或只记得回答里的一个词（content）。
只搜 content 的话，"我记得我引过那段XXX"——最常见的那种找法——全部落空。

第三个参数 opts 是可选的筛选项，**老调用方不传就跟以前完全一样**——
这也是"加一个尾部参数"而不是另开一个接口的原因：加在队尾不会改变任何既有调用方的行为。

@param query string 关键词（plain 匹配：用户输入问号/点号不该被当成正则）
@param book_fp string|nil nil = 跨书
@param opts table|nil { since, until, style, tag }
@return table 按时间倒序的行数组
--]]
function Store:search(query, book_fp, opts)
    local results = {}
    if Util.isEmpty(query) then return results end
    local targets = {}
    if book_fp then
        targets = { book_fp }
    else
        targets = Store:books()
    end
    for _b, fp in ipairs(targets) do
        local entries = Store:list(fp)
        for idx, e in ipairs(entries) do
            local in_content = type(e.content) == "string" and e.content:find(query, 1, true)
            local in_selection = type(e.selection) == "string" and e.selection:find(query, 1, true)
            local in_question = type(e.question) == "string" and e.question:find(query, 1, true)
            if in_content or in_selection or in_question then
                if matchesFilters(e, opts) then
                    results[#results + 1] = toRow(fp, idx, e)
                end
            end
        end
    end
    table.sort(results, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
    return results
end

-- 删除指定书的指定条目（indices 为 1-based 数组）
function Store:delete(book_fp, indices)
    if not book_fp or type(indices) ~= "table" then return false end
    local path = file_for(Config.paths.history, book_fp)
    local data = load_table(path)
    local entries = data.entries or {}
    local drop = {}
    for _i, i in ipairs(indices) do drop[tonumber(i)] = true end
    local kept = {}
    for i, e in ipairs(entries) do
        if not drop[i] then table.insert(kept, e) end
    end
    data.entries = kept
    return save_table(path, data)
end

function Store:clear(book_fp)
    if not book_fp then return false end
    return save_table(file_for(Config.paths.history, book_fp), { entries = {} })
end

-- 列出有历史的书籍指纹
function Store:books()
    local out = {}
    if not Config.paths.history then return out end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs then
        for f in lfs.dir(Config.paths.history) do
            local fp = f:match("^(.+)%.json$")
            if fp then table.insert(out, fp) end
        end
    end
    return out
end

-- ---------- X-Ray 数据（M4 使用） ----------

function Store:saveXRay(book_fp, data)
    if not book_fp then return false end
    return save_table(file_for(Config.paths.xray, book_fp), data or {})
end

function Store:loadXRay(book_fp)
    if not book_fp then return {} end
    return load_table(file_for(Config.paths.xray, book_fp))
end

return Store
