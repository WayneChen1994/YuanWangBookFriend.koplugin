--[[--
回复缓存（PRD F7.3）：命中缓存零 API 请求，断网也能看历史。
索引以 JSON 存在插件目录内，按 LRU 淘汰，容量可配。
--]]--

local Config = require("ywbf/config")
local Util = require("ywbf/util")
local logger = require("logger")
local json = require("json")

local Cache = {}

Cache.index = nil          -- { [key] = { v = value, t = timestamp, n = bytes } }
Cache.index_file = nil

-- 配置没给 / 给了非法值时的兜底，与 Config.DEFAULTS.cache_max_bytes 同一个数。
-- 两处必须一起改，否则"配置坏了"和"配置正常"会走不同的上限。
Cache.DEFAULT_MAX_BYTES = 4 * 1024 * 1024

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

--[==[
超出容量上限时，按"最旧优先"淘汰。

原来是 `while total > max and guard < 10000`：需要淘汰超过 1 万条时循环
**静默退出** —— 总量仍然超限、也没有任何日志，上限形同虚设。而每轮还要
`pairs` 全表找最小 t，是 O(n²)。

改成一次性收集 + 排序（O(n log n)），然后连着淘汰到够为止：
  · 一定能收敛（最多把所有条目淘汰完）；
  · 真的淘汰光了还超限（单条就比上限大）时**留一条日志**，不静默。
--]==]
function Cache:evictIfNeeded()
    local max_bytes = Config:get("cache_max_bytes") or Cache.DEFAULT_MAX_BYTES
    if type(max_bytes) ~= "number" or max_bytes <= 0 then return 0 end
    if type(self.index) ~= "table" then return 0 end

    local total = self:totalBytes()
    if total <= max_bytes then return 0 end

    local entries = {}
    for k, e in pairs(self.index) do
        entries[#entries + 1] = {
            k = k,
            t = (type(e) == "table" and tonumber(e.t) or 0) or 0,
            n = (type(e) == "table" and tonumber(e.n) or 0) or 0,
        }
    end
    table.sort(entries, function(a, b) return a.t < b.t end)

    local removed = 0
    for _i, it in ipairs(entries) do
        if total <= max_bytes then break end
        self.index[it.k] = nil
        total = total - it.n
        removed = removed + 1
    end

    if total > max_bytes then
        -- 淘汰光了还超限：n 记的字节数与真实占用对不上时才会走到这里。
        -- 属于防御分支（正常数据到不了），但不能让它静默。
        logger.warn("YWBF: cache still over limit after evicting ",
            tostring(removed), " entries (", tostring(total), " > ",
            tostring(max_bytes), " bytes)")
    elseif removed > 0 and removed >= #entries then
        -- 整个索引被淘汰光了：只有"单条就顶满上限 / 整体严重超限"才会这样。
        -- 这也是上限形同虚设的一种（缓存等于被清空），同样要留痕。
        logger.warn("YWBF: cache fully evicted ", tostring(removed),
            " entries (limit ", tostring(max_bytes), " bytes)")
    end
    return removed
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
