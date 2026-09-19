--[[--
探针：在 KPW4 上用真实 API Key 走一遍 HttpClient.get → /user/balance。

单测里 stub 掉了 ssl.https.request，只能证明"解析逻辑对"；
这个探针走真实网络，用来证明"GET 在真机上真的能通"。

在设备上执行：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     ./luajit /mnt/us/ywbf_dev/probe_balance.lua
--]]

local PLUGIN_DIR = "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"

package.path = "./?.lua;common/?.lua;frontend/?.lua;" .. PLUGIN_DIR .. "/?.lua;" .. package.path
package.cpath = "./?.so;common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

local Config = require("ywbf/config")
local Crypto = require("ywbf/crypto")
local DeepSeek = require("ywbf/deepseek")

Config:init(PLUGIN_DIR)
Crypto:init()

print("endpoint:", DeepSeek.BALANCE_ENDPOINT)

local t0 = os.time()
local res, err = DeepSeek:balance()
if not res then
    print("BALANCE FAIL:", tostring(err))
    os.exit(1)
end

print("elapsed(s):", os.time() - t0)
print("is_available:", tostring(res.is_available))
print("balance_infos count:", tostring(#res.balances))
for _, b in ipairs(res.balances) do
    print(string.format("  currency=%s total=%s granted=%s topped_up=%s",
        tostring(b.currency), tostring(b.total_balance),
        tostring(b.granted_balance), tostring(b.topped_up_balance)))
end

-- 顺带看一眼无头环境里能不能拿到屏幕信息（决定分隔线走动态计算还是兜底）
local ok_dev, Device = pcall(require, "device")
if ok_dev and Device then
    print("Device.screen:", tostring(Device.screen))
    if Device.screen and Device.screen.getWidth then
        print("screen w x h:", Device.screen:getWidth(), Device.screen:getHeight())
    end
else
    print("Device 不可用（无头环境）：分隔线会走兜底长度，GUI 内才动态计算")
end

print("PROBE_BALANCE DONE")
