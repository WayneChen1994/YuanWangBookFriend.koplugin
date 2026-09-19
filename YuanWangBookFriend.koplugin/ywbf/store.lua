--[[--
对话记录与 X-Ray 数据持久化（PRD F8.1/F8.3：全部本地，按书分文件）。
目录：data/history/<书籍指纹>.json 与 data/xray/<书籍指纹>.json
--]]--

local Config = require("ywbf/config")
local Util = require("ywbf/util")
local json = require("json")

local Store = {}

local function file_for(dir, book_fp)
    if not dir or not book_fp then return nil end
    return string.format("%s/%s.json", dir, tostring(book_fp))
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

-- ---------- 对话历史 ----------

--[[--
追加一条记录。
@param entry { role="user"|"assistant", content=string, kind=string, selection=string }
--]]
function Store:append(book_fp, entry)
    if not book_fp then return false end
    local path = file_for(Config.paths.history, book_fp)
    local data = load_table(path)
    data.entries = data.entries or {}
    local rec = {
        ts = os.time(),
        role = entry and entry.role or "user",
        kind = entry and entry.kind or "chat",
        content = entry and entry.content or "",
        selection = entry and entry.selection or "",
    }
    table.insert(data.entries, rec)
    return save_table(path, data)
end

function Store:list(book_fp)
    if not book_fp then return {} end
    local data = load_table(file_for(Config.paths.history, book_fp))
    return data.entries or {}
end

-- 全文搜索（跨书），返回 { { book_fp, ts, content, ... } }
function Store:search(query, book_fp)
    if Util.isEmpty(query) then return {} end
    local results = {}
    local books = {}
    if book_fp then
        books = { book_fp }
    else
        books = Store:books()
    end
    for _, fp in ipairs(books) do
        local entries = Store:list(fp)
        for idx, e in ipairs(entries) do
            if e.content and e.content:find(query, 1, true) then
                results[#results + 1] = {
                    book_fp = fp, index = idx, ts = e.ts,
                    role = e.role, kind = e.kind, content = e.content,
                }
            end
        end
    end
    return results
end

-- 删除指定书的指定条目（indices 为 1-based 数组）
function Store:delete(book_fp, indices)
    if not book_fp or type(indices) ~= "table" then return false end
    local path = file_for(Config.paths.history, book_fp)
    local data = load_table(path)
    local entries = data.entries or {}
    local drop = {}
    for _, i in ipairs(indices) do drop[tonumber(i)] = true end
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
