-- 探针：验证 backup 全量含 data/、临时目录不自我递归、三个入口都拒 `..`
io.stdout:setvbuf("line")
local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR") or "/mnt/us/ywbf_dev/leadplugin"
local ROOT = os.getenv("YWBF_TEST_DIR") or "/mnt/us/ywbf_dev/lead_ota_test"

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. (package.cpath or "")
pcall(require, "ffi/loadlib")
package.loaded["gettext"] = function(s) return s end
package.loaded["logger"] = { info = function() end, warn = function() end, err = function() end, dbg = function() end }

local ok_r, Ota = pcall(require, "ywbf/ota")
if not ok_r then print("REQUIRE_FAIL " .. tostring(Ota)); os.exit(1) end

os.execute("rm -rf '" .. ROOT .. "'")
os.execute("mkdir -p '" .. ROOT .. "/p/ywbf'")
os.execute("mkdir -p '" .. ROOT .. "/p/data'")
os.execute("mkdir -p '" .. ROOT .. "/p/ui'")
local f = io.open(ROOT .. "/p/main.lua", "w"); f:write("-- main\n"); f:close()
f = io.open(ROOT .. "/p/data/settings.json", "w"); f:write('{"api_key":"SECRET-DO-NOT-LOSE"}\n'); f:close()
f = io.open(ROOT .. "/p/data/history.json", "w"); f:write('{"rows":[]}\n'); f:close()
local P = ROOT .. "/p"

local fail = 0
local function ck(cond, msg, extra)
    if cond then print("PASS " .. msg)
    else fail = fail + 1; print("FAIL " .. msg .. "  << " .. tostring(extra)) end
end

-- 1) 备份
local bp, err = Ota:backup(P)
ck(type(bp) == "string", "backup 成功", tostring(err))
if type(bp) == "string" then
    local list = io.popen("tar -tzf '" .. bp .. "' 2>/dev/null")
    local txt = list:read("*a"); list:close()
    ck(txt:find("data/settings.json", 1, true) ~= nil, "备份包含 data/settings.json", txt)
    ck(txt:find("data/history.json", 1, true) ~= nil, "备份包含 data/history.json", txt)
    ck(txt:find("main.lua", 1, true) ~= nil, "备份包含 main.lua（对照组：不是打包打空了）", txt)
    ck(txt:find("ota_backup", 1, true) == nil, "备份包不含 ota_backup 自身（防递归膨胀）", txt)
    print("---- 备份包内容 ----"); print(txt); print("--------------------")
end

-- 2) 第二次备份：体积不该因为吞了第一次而暴涨
local bp2 = Ota:backup(P)
local s1 = bp and (io.open(bp, "rb"):seek("end")) or 0
local s2 = bp2 and (io.open(bp2, "rb"):seek("end")) or 0
ck(s2 < s1 * 3 + 200, "第二次备份体积没有指数膨胀（" .. tostring(s1) .. " -> " .. tostring(s2) .. "）", tostring(s2))

-- 3) 三个入口都拒绝带 .. 的目标目录
local evil = ROOT .. "/p/../escape_target"
local b3, e3 = Ota:backup(evil)
ck(b3 == nil and e3 ~= nil, "backup 拒绝含 .. 的目标目录", tostring(b3))
local a3, ea3 = Ota:apply("/nonexistent.zip", evil)
ck(a3 == false and ea3 ~= nil, "apply 拒绝含 .. 的目标目录", tostring(a3))
local r3, er3 = Ota:rollback("/nonexistent.tar.gz", evil)
ck(r3 == false and er3 ~= nil, "rollback 拒绝含 .. 的目标目录", tostring(r3))

-- 4) 对照组：正常目录不该被误伤
local b4, e4 = Ota:backup(P)
ck(type(b4) == "string", "backup 对正常目录仍然可用（对照组）", tostring(e4))

-- 5) 转义目录没有被真的创建出来
local esc = io.open(ROOT .. "/escape_target", "r")
ck(esc == nil, "escape_target 目录没有被创建", "exists")

print(string.format("LEAD_OTA_PROBE FAIL=%d", fail))
