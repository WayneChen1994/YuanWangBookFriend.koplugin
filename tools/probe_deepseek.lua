-- T1.5 探针 B：用真实 Key 在 KPW4 上完成一次 DeepSeek chat/completions 调用
package.path = "common/?.lua;frontend/?.lua;/mnt/us/koreader/common/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath

local https = require("ssl.https")
local ltn12 = require("ltn12")
local json = require("json")

local API_KEY = "sk-REPLACE_WITH_YOUR_DEEPSEEK_KEY"
local URL = "https://api.deepseek.com/chat/completions"

local payload = {
    model = "deepseek-chat",
    messages = {
        { role = "system", content = "你是阅读助手，回答务必简短。" },
        { role = "user",   content = "用一句话说明《红楼梦》的作者是谁。" },
    },
    temperature = 0.3,
    max_tokens = 128,
    stream = false,
}

local ok, body_str = pcall(json.encode, payload)
print("json.encode ok:", ok)
if not ok then
    print("encode error:", tostring(body_str))
    os.exit(1)
end

local resp = {}
local t0 = os.time()
local ok2, res, code, headers, status = pcall(https.request, {
    url = URL,
    method = "POST",
    headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. API_KEY,
        ["Content-Length"] = tostring(#body_str),
    },
    source = ltn12.source.string(body_str),
    sink = ltn12.sink.table(resp),
})
print("elapsed(s):", os.time() - t0)
if not ok2 then
    print("REQUEST ERROR:", tostring(res))
    os.exit(1)
end
print("code:", tostring(code), "status:", tostring(status))
local raw = table.concat(resp)
print("raw len:", #raw)

local ok3, decoded = pcall(json.decode, raw)
if not ok3 then
    print("decode failed, raw head:", raw:sub(1, 500))
    os.exit(1)
end
if decoded.choices and decoded.choices[1] and decoded.choices[1].message then
    print("REPLY:", decoded.choices[1].message.content)
else
    print("unexpected structure:", raw:sub(1, 500))
end
if decoded.usage then
    print("usage: prompt=", tostring(decoded.usage.prompt_tokens),
          " completion=", tostring(decoded.usage.completion_tokens),
          " total=", tostring(decoded.usage.total_tokens))
end
print("PROBE_B DONE")
