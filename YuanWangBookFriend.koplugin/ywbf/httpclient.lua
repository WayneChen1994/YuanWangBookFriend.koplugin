--[[--
极简 HTTPS 客户端：只依赖 KOReader 自带的 LuaSec/LuaSocket。

约束（PRD F8.6）：本模块是所有出站的唯一出口，调用方负责校验 URL。
默认只允许访问 api.deepseek.com；OTA 用到了 api.github.com（查 Releases）。
--]]--

local https = require("ssl.https")
local ltn12 = require("ltn12")
local socket_ok, socket = pcall(require, "socket")

local HttpClient = {}

HttpClient.ALLOWED_HOSTS = {
    ["api.deepseek.com"] = true,
    ["api.github.com"] = true,      -- OTA：查最新 Release 走这里（只读、免费）
}

--[[--
跟随跳转时才临时放行的下载域。

GitHub 的 Release 源码包地址（`zipball_url`）一定会 302 到 `codeload.github.com`，
再跳到真正的文件 CDN。**这两个域刻意不放进 ALLOWED_HOSTS**：
常驻白名单每多一个域，这个"唯一出站口"就多一道后门；
而它们只在"上一次跳转的目标是它"这个前提下才有意义。
所以由 `isHostAllowed(url, HttpClient.REDIRECT_HOSTS)` 在**每一跳**按次放行。
--]]
HttpClient.REDIRECT_HOSTS = {
    ["codeload.github.com"] = true,
    ["objects.githubusercontent.com"] = true,
}

-- 最多跟几跳。3 跳够 GitHub 走到 CDN；再多通常是有人在拿跳转做文章。
HttpClient.MAX_REDIRECTS = 3

-- 认这几种重定向状态码（含 307/308：method 保持语义的两种）
local REDIRECT_CODES = {
    [301] = true, [302] = true, [303] = true, [307] = true, [308] = true,
}

--[[--
出站白名单校验，防止误把数据发到别的域名。
只认 https：http 会明文出站，这里不存在需要明文调用的场景。

@param url string
@param extra_hosts table|nil 此次调用临时放行的域（跟随跳转时传 REDIRECT_HOSTS）
@return bool
--]]
function HttpClient.isHostAllowed(url, extra_hosts)
    if type(url) ~= "string" then return false end
    local host = url:match("^https://([^/:]+)")
    if host == nil then return false end
    if HttpClient.ALLOWED_HOSTS[host] == true then return true end
    if type(extra_hosts) == "table" and extra_hosts[host] == true then return true end
    return false
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
取出 Location 响应头。

必须大小写不敏感地找：LuaSocket 的响应表键名 retain 的大小写取决于服务端怎么写
（`location` / `Location` 都见过），直接索引 `headers.location` 会在某些服务端上
取不到、表现成"地址告诉我们了但我们不知道"，那种失败最难查。
@return string|nil
--]]
local function locationOf(headers)
    if type(headers) ~= "table" then return nil end
    local loc = headers["location"] or headers["Location"]
    if type(loc) == "string" then return loc end
    for k, v in pairs(headers) do
        if type(k) == "string" and k:lower() == "location" and type(v) == "string" then
            return v
        end
    end
    return nil
end

--[[--
把可能是相对路径的 Location 拼回绝对 URL（RFC 要求绝对，但真实服务端常有相对路径）。
@return string
--]]
local function resolveUrl(base_url, location)
    if type(location) ~= "string" or location == "" then return base_url end
    if location:match("^https?://") then return location end
    local scheme_host = base_url:match("^(https://[^/]+)")
    if not scheme_host then return location end
    if location:sub(1, 1) == "/" then return scheme_host .. location end
    local dir = base_url:match("^(https://[^/]+/.-/)")
    if not dir then return scheme_host .. "/" .. location end
    return dir .. location
end

--[[--
发起一次 HTTPS 请求（内部共用）。

@param method "POST" / "GET"
@param opts table|nil { follow_redirects = bool, max_redirects = number }
@return body, code, status, err
--]]
local function request(method, url, headers, body, timeout, opts)
    opts = (type(opts) == "table") and opts or {}
    local follow = (opts.follow_redirects == true)
    local max_hops = type(opts.max_redirects) == "number" and opts.max_redirects
        or HttpClient.MAX_REDIRECTS
    if max_hops < 0 then max_hops = 0 end

    local current_url = url
    local hops = 0

    while true do
        -- 每一跳都重新过白名单：只在跟随跳转时额外放行下载域。
        -- 不在首跳就放行、也不只在首跳校验——只在首跳校验等于给跳转目标开了后门。
        local extra = (hops > 0) and HttpClient.REDIRECT_HOSTS or nil
        if not HttpClient.isHostAllowed(current_url, extra) then
            return nil, nil, nil, "host not allowed: " .. tostring(current_url)
        end

        HttpClient.setTimeout(timeout or DEFAULT_TIMEOUT)

        local sink = {}
        local payload = {
            url = current_url,
            method = method,
            headers = headers,
            sink = ltn12.sink.table(sink),
            protocol = "tlsv1_2",
        }
        -- 只有 POST 带请求体；GET 不传 source（LuaSocket 会自动用空 source）
        if body ~= nil and hops == 0 then
            payload.source = ltn12.source.string(body)
        end

        -- 返回值结构（已在 KPW4 上实测确认）：ok, 1, code, headers, status
        local ok, res, code, res_headers, status = pcall(https.request, payload)
        if not ok then
            return nil, nil, nil, tostring(res)
        end

        if follow and REDIRECT_CODES[code] ~= nil then
            local next_url = resolveUrl(current_url, locationOf(res_headers))
            if type(next_url) == "string" and next_url ~= "" then
                hops = hops + 1
                if hops > max_hops then
                    return nil, code, status, "too many redirects: " .. tostring(current_url)
                end
                current_url = next_url
                -- 继续下一跳
            else
                return table.concat(sink), code, status, nil
            end
        else
            return table.concat(sink), code, status, nil
        end
    end
end

--[[--
POST JSON。
@return body, code, status, err
--]]
function HttpClient.post(url, headers, body, timeout, opts)
    return request("POST", url, headers, body or "", timeout, opts)
end

--[[--
GET（无请求体）。账户余额这类只读查询用。

注意：GET 同样过白名单校验，不会因为有"只读"接口就放开出站限制。
默认**不跟随跳转**（DeepSeek 的行为与 OTA 之前完全一致）；
要跟随必须显式传 `opts.follow_redirects = true`，而且每一跳都会重新过白名单。
@return body, code, status, err
--]]
function HttpClient.get(url, headers, timeout, opts)
    return request("GET", url, headers, nil, timeout, opts)
end

return HttpClient
