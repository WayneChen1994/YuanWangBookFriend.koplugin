--[[--
开发期工具：把 DeepSeek API Key 加密写入插件配置。
在设备上用 KOReader 自带的 luajit 执行（设备盐与 KOReader 进程一致，可正常解密）。

用法：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
    YWBF_KEY=sk-xxxx ./luajit /mnt/us/ywbf_dev/set_key.lua
--]]
package.path = "./?.lua;common/?.lua;frontend/?.lua;plugins/YuanWangBookFriend.koplugin/?.lua;" .. package.path
package.cpath = "./?.so;common/?.so;" .. package.cpath

local PLUGIN_DIR = "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"

local Config = require("ywbf/config")
local Crypto = require("ywbf/crypto")
local DeepSeek = require("ywbf/deepseek")

local key = os.getenv("YWBF_KEY")
if (not key or key == "") then
    -- 环境变量传不进来时（多数 sshd 默认禁用 PermitUserEnvironment），从文件读
    local f = io.open("/mnt/us/ywbf_dev/api_key_dev.txt", "r")
    if f then
        key = (f:read("*l") or "")
        f:close()
    end
end
if not key or key == "" then
    print("ERROR: 未拿到 Key（YWBF_KEY 为空且无 /mnt/us/ywbf_dev/api_key_dev.txt）")
    os.exit(1)
end
key = key:gsub("^%s+", ""):gsub("%s+$", "")

local ok_init, algo = Crypto:init()
print("crypto:", tostring(ok_init), tostring(algo), "salt_len:", #Crypto:deviceSalt())

Config:init(PLUGIN_DIR)
print("settings path:", Config.paths.settings)

if not DeepSeek:setApiKey(key) then
    print("ERROR: 保存失败")
    os.exit(1)
end

-- 回读校验：解密结果必须与原文一致
local got, err = DeepSeek:getApiKey()
if got ~= key then
    print("ERROR: 回读校验失败:", tostring(err), "got=", tostring(got))
    os.exit(1)
end

print("OK: API Key 已加密保存并回读校验通过")
print("hasApiKey:", tostring(DeepSeek:hasApiKey()))
