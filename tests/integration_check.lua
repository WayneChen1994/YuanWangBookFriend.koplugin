--[[--
M1 端到端集成自检：用真实插件代码跑一遍 配置→加密→白名单→HTTP→DeepSeek→用量统计。
在 KPW4 上执行（需要传 YWBF_KEY 环境变量）：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     YWBF_KEY=sk-xxx ./luajit /mnt/us/ywbf_dev/tests/integration_check.lua
--]]--

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR") or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

local Config = require("ywbf/config")
local Crypto = require("ywbf/crypto")
local DeepSeek = require("ywbf/deepseek")
local Tokens = require("ywbf/tokens")

local function step(name, cond, extra)
    print(string.format("[%s] %s%s", cond and " OK " or "FAIL", name,
        extra and ("  -> " .. tostring(extra)) or ""))
    if not cond then os.exit(1) end
end

Config:init(PLUGIN_DIR)
local ok_crypto, algo = Crypto:init()
step("crypto 初始化", ok_crypto, algo)

local KEY = os.getenv("YWBF_KEY")
if KEY and KEY ~= "" then
    step("写入 API Key（加密）", DeepSeek:setApiKey(KEY))
end
step("已配置 API Key", DeepSeek:hasApiKey() == true)

-- 明文检查
local raw = Config._read_file(Config.paths.settings)
step("设置文件不含明文 Key", (not raw) or (not raw:find(KEY or "\000", 1, true)))

local res, err = DeepSeek:chat({
    { role = "system", content = "你是阅读助手，回答务必简短。" },
    { role = "user",   content = "用一句话说明《红楼梦》的作者是谁。" },
}, { max_tokens = 128, temperature = 0.3 })

step("DeepSeek 调用成功", res ~= nil, err)
print("  回复: " .. tostring(res and res.content))
print("  用量: " .. tostring(res and res.usage and res.usage.total_tokens))

local u = Tokens.usage()
print(string.format("  累计: requests=%d prompt=%d completion=%d 预估费用=%.4f 元",
    u.requests, u.prompt_tokens, u.completion_tokens, Tokens.estimateCostCNY()))
step("用量已累计", u.requests >= 1)

-- 白名单必须拦住非 DeepSeek 域名
local HttpClient = require("ywbf/httpclient")
local b, c, s, e = HttpClient.post("https://example.com/x", {}, "{}", 5)
step("非白名单域名被拦截", b == nil and e ~= nil, e)

-- 设置菜单构建冒烟测试：默认关闭。
-- 原因：加载 KOReader UI 模块会初始化 framebuffer/输入设备，与正在运行的 KOReader 抢资源。
-- 真实 KOReader 中插件已成功加载（crash.log 有 "YWBF: plugin initialized"），
-- 即 UI 依赖已验证；需要额外验证时：YWBF_UI_TEST=1
if os.getenv("YWBF_UI_TEST") == "1" then
    if not rawget(_G, "G_reader_settings") then
    _G.G_reader_settings = {
        readSetting = function() return nil end,
        saveSetting = function() return true end,
        has = function() return false end,
        isTrue = function() return false end,
        nilOrFalse = function() return true end,
        flipFalse = function() end,
        flipNilOrFalse = function() end,
        makeFalse = function() end,
        makeTrue = function() end,
        delSetting = function() end,
    }
end
    local ok_ui, SettingsUI = pcall(require, "ui/settings")
    if ok_ui then
        local ok_menu, items = pcall(SettingsUI.buildMenu, SettingsUI, {})
        step("设置菜单可构建", ok_menu and type(items) == "table" and #items > 0,
            ok_menu and ("菜单项数=" .. tostring(#items)) or items)
    else
        print("[skip] 独立环境无法加载 UI 模块：" .. tostring(SettingsUI))
    end
end

print("INTEGRATION OK")
