--[[--
一次性的真实验证：拿 GitHub 上**真实**的 Release 源码包跑一遍 Ota:apply。

为什么单独写这个而不进自测脚本：自测必须可重复、不联网，
而"真实 zip 的外层结构到底长什么样"这件事只能靠真货来验一次——
自测里的包是我手写的，手写包通过只能证明"我猜对了结构"。

只发**一次**网络请求（GitHub 查询免费，但也不该每次跑测试都敲一遍）。
--]]--

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR")
    or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"
local WORK = os.getenv("YWBF_TEST_DIR") or "/mnt/us/ywbf_dev/ota_real_check"

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")
package.loaded["gettext"] = function(s) return s end
package.loaded["logger"] = { info = function() end, warn = function() end,
    dbg = function() end, err = function() end }

local Config = require("ywbf/config")
local HttpClient = require("ywbf/httpclient")
local Ota = require("ywbf/ota")

os.execute("rm -rf '" .. WORK .. "'")
os.execute("mkdir -p '" .. WORK .. "'")
Config:init(WORK)

print("=== 1. 真的去 GitHub 查一次最新 Release ===")
local rel, err = Ota:latestRelease()
if not rel then
    print("FAIL 查不到 Release: " .. tostring(err))
    os.exit(1)
end
print("tag=" .. tostring(rel.tag))
print("name=" .. tostring(rel.name))
print("zipball=" .. tostring(rel.zipball_url))
print("html=" .. tostring(rel.html_url))

print("=== 2. 真的下载一次（跟随跳转） ===")
local zip_path = WORK .. "/real.zip"
local ok_dl, err_dl = Ota:download(rel.zipball_url, zip_path)
if not ok_dl then
    print("FAIL 下载失败: " .. tostring(err_dl))
    os.exit(1)
end
local sz = 0
do
    local f = io.open(zip_path, "rb")
    if f then sz = f:seek("end") or 0; f:close() end
end
print("下载成功，字节数=" .. tostring(sz))

print("=== 3. 真实包解压后的结构 ===")
local peek = WORK .. "/peek"
os.execute("mkdir -p '" .. peek .. "'")
os.execute(string.format("unzip -qq -o '%s' -d '%s'", zip_path, peek))
os.execute("ls -1 '" .. peek .. "' | head -5")

print("=== 4. 拿真包跑一次 apply（目标目录里预先放了「用户的东西」）===")
local target = WORK .. "/plugin"
os.execute("mkdir -p '" .. target .. "/data'")
local function w(p, s)
    local f = io.open(p, "wb"); if f then f:write(s); f:close() end
end
w(target .. "/main.lua", "print('OLD VERSION')\n")
w(target .. "/data/key.enc", "REAL-USER-KEY")
w(target .. "/data/settings.json", "{\"model\":\"deepseek-chat\"}")

local ok_apply, err_apply = Ota:apply(zip_path, target)
print("apply=" .. tostring(ok_apply) .. " err=" .. tostring(err_apply))
if not ok_apply then os.exit(1) end

local function r(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end
print("main.lua 前 60 字节: " .. tostring((r(target .. "/main.lua") or ""):sub(1, 60)))
print("data/key.enc = " .. tostring(r(target .. "/data/key.enc")))
print("data/settings.json = " .. tostring(r(target .. "/data/settings.json")))
local has_new_main = (r(target .. "/main.lua") or ""):find("OLD VERSION", 1, true) == nil
print("main.lua 被换掉了=" .. tostring(has_new_main))
print("Key 原样保留=" .. tostring(r(target .. "/data/key.enc") == "REAL-USER-KEY"))
print("settings 原样保留=" .. tostring(r(target .. "/data/settings.json") == "{\"model\":\"deepseek-chat\"}"))

print("=== 5. 备份与回滚 ===")
local bp, berr = Ota:backup(target)
print("backup=" .. tostring(bp) .. " err=" .. tostring(berr))
if bp then
    w(target .. "/main.lua", "print('BROKEN')\n")
    local ok_rb, err_rb = Ota:rollback(bp, target)
    print("rollback=" .. tostring(ok_rb) .. " err=" .. tostring(err_rb))
    print("回滚后 main.lua 前 60 字节: " .. tostring((r(target .. "/main.lua") or ""):sub(1, 60)))
end
print("=== 完成 ===")
os.exit(0)
