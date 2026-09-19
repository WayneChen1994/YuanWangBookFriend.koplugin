--[[--
Token 粗估与用量统计（PRD §4.3：用量透明）。
不做精确分词，按字节数粗估即可，误差可控在 ±20%。
--]]--

local Config = require("ywbf/config")

local Tokens = {}

-- 中文 UTF-8 约 3 字节/字，DeepSeek 中文约 0.6~0.7 token/字；
-- 英文约 4 字符/token。统一折算：每 3.8 字节 ≈ 1 token。
local BYTES_PER_TOKEN = 3.8

function Tokens.estimate(text)
    if type(text) ~= "string" or text == "" then return 0 end
    return math.ceil(#text / BYTES_PER_TOKEN)
end

function Tokens.estimateMessages(messages)
    if type(messages) ~= "table" then return 0 end
    local total = 0
    for _, m in ipairs(messages) do
        total = total + Tokens.estimate(m.content or "")
        total = total + 4  -- role/结构开销
    end
    return total
end

function Tokens.usage()
    local u = Config:get("usage") or {}
    return {
        requests = u.requests or 0,
        prompt_tokens = u.prompt_tokens or 0,
        completion_tokens = u.completion_tokens or 0,
        total_tokens = (u.prompt_tokens or 0) + (u.completion_tokens or 0),
    }
end

-- 按公开价目粗算费用（人民币），价格可在设置里随官方调整
local PRICE_PER_MILLION_CACHE_HIT = 0.5   -- 命中缓存的输入（元/百万 token）
local PRICE_PER_MILLION_CACHE_MISS = 2.0  -- 未命中输入
local PRICE_PER_MILLION_OUTPUT = 8.0      -- 输出

function Tokens.estimateCostCNY()
    local u = Tokens.usage()
    local cost = (u.prompt_tokens / 1000000) * PRICE_PER_MILLION_CACHE_MISS
               + (u.completion_tokens / 1000000) * PRICE_PER_MILLION_OUTPUT
    return cost, u
end

function Tokens.formatUsage()
    local u = Tokens.usage()
    local cost = Tokens.estimateCostCNY()
    return string.format(
        "请求 %d 次\n输入 %d tokens\n输出 %d tokens\n合计 %d tokens\n预估费用 ¥%.3f",
        u.requests, u.prompt_tokens, u.completion_tokens, u.total_tokens, cost)
end

return Tokens
