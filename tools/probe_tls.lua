-- T1.5 探针：验证 KPW4 上 KOReader Lua 运行时能否 HTTPS 访问 api.deepseek.com
-- 运行在设备 /mnt/us/koreader 目录下，luajit 解释器
package.path = "common/?.lua;frontend/?.lua;/mnt/us/koreader/common/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath

local function p(...) print(...) end

local ok, https = pcall(require, "ssl.https")
p("require ssl.https:", ok)
if not ok then
    p("FATAL: luasec not loadable ->", tostring(https))
    os.exit(1)
end

local ok2, ltn12 = pcall(require, "ltn12")
p("require ltn12:", ok2)
local socket = require("socket")
p("dns api.deepseek.com:", tostring(socket.dns.toip("api.deepseek.com")))

local CANDIDATES = {
    { name = "default(no cafile)",        opts = {} },
    { name = "/etc/ssl/certs/ca-certificates.crt", opts = { cafile = "/etc/ssl/certs/ca-certificates.crt" } },
    { name = "cafile + tlsv1_2",          opts = { cafile = "/etc/ssl/certs/ca-certificates.crt", protocol = "tlsv1_2" } },
    { name = "cafile + tlsv1_2 + verify none", opts = { cafile = "/etc/ssl/certs/ca-certificates.crt", protocol = "tlsv1_2", verify = "none" } },
}

for _, c in ipairs(CANDIDATES) do
    local body = {}
    local req = {
        url = "https://api.deepseek.com/models",
        method = "GET",
        sink = ltn12.sink.table(body),
    }
    for k, v in pairs(c.opts) do req[k] = v end
    p("---- try:", c.name)
    local t0 = os.time()
    local ok3, res, code, headers, status = pcall(https.request, req)
    p("   elapsed(s):", os.time() - t0)
    if not ok3 then
        p("   ERROR:", tostring(res))
    else
        p("   code:", tostring(code), " status:", tostring(status))
        local b = table.concat(body)
        if #b > 300 then b = b:sub(1, 300) .. "..." end
        p("   body:", b)
    end
end
p("PROBE DONE")
