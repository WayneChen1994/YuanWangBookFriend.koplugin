--[[--
回复缓存（PRD F7.3）：命中缓存零 API 请求，断网也能看历史。
索引以 JSON 存在插件目录内，按 LRU 淘汰，容量可配。
--]]--

local Config = require("ywbf/config")
local Util = require("ywbf/util")
local json = require("json")

local Cache = {}

Cache.index = nil          -- { [key] = { v = value, t = timestamp, n = bytes } }
Cache.index_file = nil

function Cache:init()
    self.index = nil
    if not Config.paths.cache then return false end
    self.index_file = Config.paths.cache .. "/index.json"
    local raw = Config._read_file(self.index_file)
    if raw and #raw > 0 then
        local ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == "table" then
            self.index = decoded
        end
    end
    if type(self.index) ~= "table" then self.index = {} end
    return true
end

--[[--
缓存键：书籍指纹 + 选中内容 + 功能类型 + 模型
（同一本书、同一段文字、同一种问法 → 命中）
--]]
function Cache:keyFor(book_fp, selected, kind, model)
    local raw = string.format("%s|%s|%s|%s",
        tostring(book_fp or ""), Util.collapseWhitespace(selected or ""),
        tostring(kind or ""), tostring(model or ""))
    return Util.md5(raw)
end

function Cache:save()
    if not self.index_file then return false end
    local ok, encoded = pcall(json.encode, self.index)
    if not ok then return false end
    return Config._write_file(self.index_file, encoded)
end

function Cache:get(key)
    if type(self.index) ~= "table" then return nil end
    local entry = self.index[key]
    if not entry then return nil end
    entry.t = os.time()  -- 命中即刷新热度
    return entry.v
end

function Cache:set(key, value)
    if type(self.index) ~= "table" then self:init() end
    if value == nil then return false end
    local size = #tostring(value)
    self.index[key] = { v = value, t = os.time(), n = size }
    self:evictIfNeeded()
    return self:save()
end

function Cache:totalBytes()
    local total = 0
    for _, e in pairs(self.index or {}) do
        total = total + (e and tonumber(e.n) or 0)
    end
    return total
end

function Cache:count()
    local n = 0
    for _ in pairs(self.index or {}) do n = n + 1 end
    return n
end

-- 超出容量上限时，按时间淘汰最旧的（Lua 5.1 无 table.sort 稳定保证，手动选最小）
function Cache:evictIfNeeded()
    local max_bytes = Config:get("cache_max_bytes") or (50 * 1024 * 1024)
    if not Config:get("cache_enabled") then
        -- 缓存关闭时不清空已有数据，只是不再写入
    end
    local guard = 0
    while self:totalBytes() > max_bytes and guard < 10000 do
        guard = guard + 1
        local oldest_key, oldest_t = nil, nil
        for k, e in pairs(self.index) do
            if e and (oldest_t == nil or (e.t or 0) < oldest_t) then
                oldest_key, oldest_t = k, (e.t or 0)
            end
        end
        if not oldest_key then break end
        self.index[oldest_key] = nil
    end
end

function Cache:clear()
    self.index = {}
    return self:save()
end

function Cache:stats()
    return {
        entries = self:count(),
        bytes = self:totalBytes(),
        enabled = Config:get("cache_enabled") == true,
    }
end

return Cache
