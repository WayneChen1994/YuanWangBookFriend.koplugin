-- 探针：只用真源码，验证 normalizeVersion / compareVersions 的当前真实行为
io.stdout:setvbuf("line")
local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR") or "/mnt/us/koreader/plugins/yuanwangbookfriend.koplugin"
package.path = PLUGIN_DIR .. "/?.lua;" .. PLUGIN_DIR .. "/ywbf/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. (package.cpath or "")
pcall(require, "ffi/loadlib")
package.loaded["gettext"] = function(s) return s end
package.loaded["logger"] = { info = function() end, warn = function() end, err = function() end, dbg = function() end }

local ok, Ota = pcall(require, "ywbf/ota")
if not ok then
    print("REQUIRE_FAIL " .. tostring(Ota))
    os.exit(1)
end

local function dump(t)
    if type(t) ~= "table" then return tostring(t) end
    local parts = {}
    for _i = 1, #t do parts[#parts + 1] = tostring(t[_i]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

local samples = { "v0.2", "1.10.0", "0.10.0", "0.9.0", "0.2.0", "v1.2.3", "1.2.3.4",
                  "0.x.1", "1..2", "", "abc", "0.2.0-beta", "  0.3.0  ", "nope1", nil }
for _i = 1, #samples do
    local s = samples[_i]
    print(string.format("normalizeVersion(%q) -> %s", tostring(s), dump(Ota:normalizeVersion(s))))
end

local pairs_cmp = { { "0.10.0", "0.9.0" }, { "0.2.0", "0.2.0" }, { "1.0", "1.0.1" },
                    { "0.x.1", "1.0.0" }, { "abc", "1.0.0" }, { "v1.0.0", "1.0.0" } }
for _i = 1, #pairs_cmp do
    local a, b = pairs_cmp[_i][1], pairs_cmp[_i][2]
    print(string.format("compareVersions(%q,%q) -> %s", a, b, tostring(Ota:compareVersions(a, b))))
end

print("VERSION_IN_CONFIG=" .. tostring(require("ywbf/config").VERSION))
