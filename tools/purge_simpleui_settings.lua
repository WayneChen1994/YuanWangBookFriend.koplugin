-- 卸载 SimpleUI 后清理 KOReader 全局设置里的残留键。
-- 关键：start_with = "homescreen_simpleui" 必须改掉，否则插件删掉后
-- KOReader 启动时会去加载一个不存在的首页，可能起不来或行为异常。
package.path = "common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

local LuaSettings = require("luasettings")

local path = "/mnt/us/koreader/settings.reader.lua"
local s = LuaSettings:open(path)

local function report(tag)
    print(tag,
        " start_with=", tostring(s:readSetting("start_with")),
        " migrated=", tostring(s:readSetting("simpleui_userdata_migrated_v1")),
        " dl_url=", (s:readSetting("sui_upd_dl_url") ~= nil))
end

report("BEFORE:")

if s:readSetting("start_with") == "homescreen_simpleui" then
    s:saveSetting("start_with", "filemanager")
end
if s:readSetting("simpleui_userdata_migrated_v1") ~= nil then
    s:delSetting("simpleui_userdata_migrated_v1")
end
if s:readSetting("sui_upd_dl_url") ~= nil then
    s:delSetting("sui_upd_dl_url")
end

s:flush()
report("AFTER: ")
print("DONE")
