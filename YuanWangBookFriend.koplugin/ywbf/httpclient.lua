--[[--
极简 HTTPS 客户端：只依赖 KOReader 自带的 LuaSec/LuaSocket。

约束（PRD F8.6）：本模块只允许访问 api.deepseek.com，调用方负责校验 URL。
--]]--

local https = require("ssl.https")
local ltn12 = require("ltn12")
local socket_ok, socket = pcall(require, "socket")

local HttpClient = {}

HttpClient.ALLOWED_HOSTS = {
    ["api.deepseek.com"] = true,
}

-- 出站白名单校验，防止误把数据发到别的域名。
-- 只认 https：http 会明文出站，这里不存在需要明文调用的场景。
function HttpClient.isHostAllowed(url)
    if type(url) ~= "string" then return false end
    local host = url:match("^https://([^/:]+)")
    return host ~= nil and HttpClient.ALLOWED_HOSTS[host] == true
end

local DEFAULT_TIMEOUT = 60

function HttpClient.setTimeout(seconds)
    DEFAULT_TIMEOUT = seconds or DEFAULT_TIMEOUT
    if socket_ok then
        socket.http.TIMEOUT = DEFAULT_TIMEOUT
        local ok_http = pcall(function() require("socket.http").TIMEOUT = DEFAULT_TIMEOUT end)
        if not ok_http then -- luacheck: ignore
        end
    end
    https.TIMEOUT = DEFAULT_TIMEOUT
end

--[[--
发起一次 HTTPS 请求（内部共用）。

@param method "POST" / "GET"
@return body, code, status, err
--]]
local function request(method, url, headers, body, timeout)
    if not HttpClient.isHostAllowed(url) then
        return nil, nil, nil, "host not allowed: " .. tostring(url)
    end
    HttpClient.setTimeout(timeout or DEFAULT_TIMEOUT)

    local sink = {}
    local payload = {
        url = url,
        method = method,
        headers = headers,
        sink = ltn12.sink.table(sink),
        protocol = "tlsv1_2",
    }
    -- 只有 POST 带请求体；GET 不传 source（LuaSocket 会自动用空 source）
    if body ~= nil then
        payload.source = ltn12.source.string(body)
    end

    local ok, res, code, _, status = pcall(https.request, payload)
    if not ok then
        return nil, nil, nil, tostring(res)
    end
    return table.concat(sink), code, status, nil
end

--[[--
POST JSON。
@return body, code, status, err
--]]
function HttpClient.post(url, headers, body, timeout)
    return request("POST", url, headers, body or "", timeout)
end

--[[--
GET（无请求体）。账户余额这类只读查询用。

注意：GET 同样过白名单校验，不会因为有"只读"接口就放开出站限制。
@return body, code, status, err
--]]
function HttpClient.get(url, headers, timeout)
    return request("GET", url, headers, nil, timeout)
end

return HttpClient
