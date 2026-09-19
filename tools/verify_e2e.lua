--[[--
M2 端到端验证（不含 UI）：用真实插件代码跑一遍
「读加密 Key → 构造上下文 → 组装 prompt → 请求 DeepSeek → 写缓存与历史」。

在设备上执行（Key 必须已经写入插件配置）：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     ./luajit /mnt/us/ywbf_dev/verify_e2e.lua
--]]

local PLUGIN_DIR = "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"

package.path = "./?.lua;common/?.lua;frontend/?.lua;" .. PLUGIN_DIR .. "/?.lua;" .. package.path
package.cpath = "./?.so;common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

local Config = require("ywbf/config")
local Crypto = require("ywbf/crypto")
local DeepSeek = require("ywbf/deepseek")
local Cache = require("ywbf/cache")
local Store = require("ywbf/store")
local Context = require("ywbf/context")
local Prompts = require("ywbf/prompts")

local function step(name, cond, extra)
    print(string.format("[%s] %s%s", cond and " OK " or "FAIL", name,
        extra and ("  -> " .. tostring(extra)) or ""))
    if not cond then os.exit(1) end
end

Config:init(PLUGIN_DIR)
Crypto:init()
Cache:init()

-- 1. 从加密存储读到 Key（不靠环境变量，走真机链路）
local key, kerr = DeepSeek:getApiKey()
step("从加密存储读取 API Key", key ~= nil, kerr or (key and (key:sub(1, 3) .. "***" .. key:sub(-4))))

-- 2. 模拟一次「AI 解释」：选中一段文本 + 所在页上下文
local page_text = [[他猛地转过身，面对着乔治。
"我说，乔治，你记得我们那个地方吗？"
"记得，当然记得。那地方不怎么好。"
"我们要去的地方才叫好。"莱尼说。
"我们要有一小块地，种苜蓿。"
"种苜蓿。"乔治重复着，几乎是在自言自语。
"我们要养兔子。"]]
local selected = "我们要有一小块地，种苜蓿。"

local win = Context.fromSelection(page_text, selected, Config:get("context_chars"))
step("上下文窗口定位选中位置", win ~= nil and win.selected == selected,
    win and string.format("before=%d after=%d", #(win.before or ""), #(win.after or "")))

local ctx = Prompts.contextFromWindow(win)
step("上下文片段非空", ctx ~= nil and #ctx > #selected, string.format("ctx_len=%d", #ctx))

local messages = Prompts.build("explain", {
    context = ctx,
    selected = selected,
})

-- 3. 真实请求
local t0 = os.time()
local res, err = DeepSeek:chat(messages, {
    model = Config:get("model"),
    temperature = Config:get("temperature_fact"),
    max_tokens = Config:get("max_tokens_explain"),
})
step("DeepSeek 请求成功", res ~= nil, err or string.format("%ds, %d tokens",
    os.time() - t0, (res.usage and res.usage.total_tokens) or 0))

print("---- AI 回复 ----")
print((res.content or ""):sub(1, 400))
print("-----------------")

-- 4. 缓存与历史落盘
local cache_key = Cache:keyFor("verify-book", selected, "explain", Config:get("model"))
Cache:set(cache_key, res.content)
step("缓存写入并可读回", Cache:get(cache_key) == res.content)

Store:append("verify-book", { role = "assistant", content = res.content, kind = "explain", selection = selected })
local hist = Store:list("verify-book")
step("历史写入并可读回", type(hist) == "table" and #hist >= 1, "条数=" .. tostring(hist and #hist))

-- 5. 用量统计
local u = Config:get("usage")
print(string.format("累计用量：requests=%d prompt=%d completion=%d",
    u.requests or 0, u.prompt_tokens or 0, u.completion_tokens or 0))

print("E2E OK")
