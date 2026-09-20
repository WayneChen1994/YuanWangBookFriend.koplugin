--[[--
OTA 自更新（M4）的定向自测。

三条原则：

1. **不发网络**。HttpClient 换成记录仪 + 回预制答案的替身；
   GitHub 查询是免费的，但"跑一次测试敲一次 GitHub"迟早会被当成滥用，
   而且测下来的东西还会随远端变化——测试要可重复就必须把自己输入的那一头钉死。
2. **一切 IO 只写在 /mnt/us/ywbf_dev 之下的临时目录**，绝不碰真插件目录。
   设备上的 /tmp、/var 是 32M 的 tmpfs 常年接近满，别去挤。
3. **"等于 X" 的用例一律配对照组**：没有对照组，断言就退化成"绿着就行"。

在 KPW4 上跑：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     YWBF_PLUGIN_DIR=/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin \
     YWBF_TEST_DIR=/mnt/us/ywbf_dev/ota_test_data \
     ./luajit /mnt/us/ywbf_dev/tools/eng_check_ota.lua

LuaJIT = Lua 5.1 语义：无位运算符；循环变量一律 `_i`。
--]]--

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR")
    or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"
local TEST_ROOT = os.getenv("YWBF_TEST_DIR") or "/mnt/us/ywbf_dev/ota_test_data"

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

--[[--
先把**真** HttpClient 拿到手，再装替身。

顺序不能反：`ywbf/ota` 里写死 `require("ywbf/httpclient")`，装了替身以后再去
require 拿到的就是替身，第 3 节测白名单就变成"替身说放行就放行"——全绿，但什么也没测。
--]]
local RealHttpClient = require("ywbf/httpclient")

-- ---------- ① 替身 ----------
package.loaded["gettext"] = function(s) return s end
package.loaded["logger"] = {
    info = function() end, warn = function() end,
    dbg = function() end, err = function() end,
}

local infos = {}
package.loaded["ui/widget/infomessage"] = {
    new = function(_cls, o)
        --[[--
        `timeout` 必须留给断言看：进度提示"1 秒后自己消失"这件事，
        在真机上表现为"用户干等好几秒、然后结果突然蹦出来"，
        光看它 show 过是发现不了的。
        --]]
        local w = {
            info_text = (type(o) == "table" and o.text) or "",
            timeout = (type(o) == "table") and o.timeout or nil,
        }
        infos[#infos + 1] = w
        return w
    end,
}
local last_confirm = nil
package.loaded["ui/widget/confirmbox"] = {
    new = function(_cls, o)
        last_confirm = o or {}
        return o or {}
    end,
}
package.loaded["ui/widget/inputdialog"] = {
    new = function(_cls, o) return { buttons = type(o) == "table" and o.buttons or {}, _text = "" } end,
}
package.loaded["ui/widget/menu"] = {
    new = function(_cls, o) return { title = type(o) == "table" and o.title or "",
        item_table = type(o) == "table" and o.item_table or {} } end,
}
package.loaded["ui/widget/textviewer"] = { new = function() return {} end }
package.loaded["ui/widget/notification"] = { SOURCE_ALWAYS_SHOW = 1, notify = function() end }
package.loaded["ui/widget/buttondialog"] = { new = function() return { buttons = {} } end }
package.loaded["ui/trapper"] = { wrap = function(_self, fn) return fn() end }
--[[--
UIManager 记一条**完整的 show / close 事件流**。

只记 show 不够：要看"结果弹窗 show 之前、进度提示已经被 close"，
就得知道两者的先后顺序。光断言"屏幕上最多一个弹层"也挡不住
"进度提示 1 秒后自己消失"——那种情况下峰值也是 1，但用户看到的是空白。
--]]
local ui_events = {}
package.loaded["ui/uimanager"] = {
    show = function(_self, w)
        ui_events[#ui_events + 1] = { op = "show", w = w }
    end,
    close = function(_self, w)
        ui_events[#ui_events + 1] = { op = "close", w = w }
    end,
    scheduleIn = function(_self, _sec, fn) if type(fn) == "function" then fn() end end,
}

-- 当前挂在屏幕上的弹层数（show +1 / close -1，按弹层同一性记账）
local function peakConcurrent(events)
    local live, peak = {}, 0
    for _i, ev in ipairs(events or {}) do
        if ev.op == "show" then
            live[#live + 1] = ev.w
        elseif ev.op == "close" then
            for _j = #live, 1, -1 do
                if live[_j] == ev.w then
                    table.remove(live, _j)
                    break
                end
            end
        end
        if #live > peak then peak = #live end
    end
    return peak
end

--[[--
HttpClient 记录仪。装在 require 真模块**之前**：
`ywbf/ota` 里写死 `require("ywbf/httpclient")`，晚一步装就 replace 不掉了，
而那种"替身没生效"的表现是全绿——因为真家伙会把请求真的发出去。
--]]
local http_gets = {}
local NEXT_GET = { body = "", code = 200, status = "OK", err = nil }
package.loaded["ywbf/httpclient"] = {
    get = function(url, headers, timeout, opts)
        http_gets[#http_gets + 1] = {
            url = url, headers = headers, timeout = timeout,
            opts = (type(opts) == "table") and opts or nil,
        }
        return NEXT_GET.body, NEXT_GET.code, NEXT_GET.status, NEXT_GET.err
    end,
    post = function() return nil, 0, "", "eng_check_ota: stub" end,
    isHostAllowed = function() return true end,
}

io.stdout:setvbuf("line")

local passed, failed = 0, 0
local function ok(cond, name, extra)
    if cond then
        passed = passed + 1
        print("  PASS  " .. name)
    else
        failed = failed + 1
        print("  FAIL  " .. name .. (extra and ("  -> " .. tostring(extra)) or ""))
    end
end
local function eq(a, b, name)
    ok(a == b, name, string.format("got=%s want=%s", tostring(a), tostring(b)))
end

-- ---------- ② 环境：一切 IO 都写测试目录 ----------
local Config = require("ywbf/config")
local Util = require("ywbf/util")
local Ota = require("ywbf/ota")
local Queue = require("ywbf/queue")
local _ = require("gettext")

os.execute("rm -rf '" .. TEST_ROOT .. "'")
Config:init(TEST_ROOT)

local function ensureDir(path)
    os.execute(string.format("mkdir -p '%s'", path))
end
local function writefile(path, content)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end
local function readfile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end
local function exists(path)
    return readfile(path) ~= nil
end

-- ---------- ③ 离线造 zip：Thumbnail ----------
--[[--
为什么自己写 zip：设备上只有 `unzip` 没有 `zip`（busybox 也没带），
而"能不能剥掉外面那一层 GitHub 自动生成的根目录""顶层有两个目录时要拒绝"
这些都**必须**用真实结构才能测。现造一个假的 `tar.gz` 冒充压缩包，
测的不是 apply 而是别的东西。

这里实现的是**仅 Deflate=? 不，是仅 Stored（不压缩）**的最小 zip：
unzip 认就够了，压缩率在这个场景里毫无意义（我们要的是结构，不是体积）。
CRC32 手算（Lua 5.1 没有位运算符），正确性由下面那条"造完之后自己 unzip 一遍"
的用例兜底——如果 CRC 表写错，那条会先红。
--]]
local function bxor(a, b)
    local r, bit = 0, 1
    while a > 0 or b > 0 do
        if (a % 2) ~= (b % 2) then r = r + bit end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bit = bit * 2
    end
    return r
end

local CRC_TABLE = {}
do
    for i = 0, 255 do
        local c = i
        for _j = 1, 8 do
            if c % 2 == 1 then
                c = bxor(math.floor(c / 2), 0xEDB88320)
            else
                c = math.floor(c / 2)
            end
        end
        CRC_TABLE[i + 1] = c
    end
end

local function crc32(s)
    local crc = 0xFFFFFFFF
    for i = 1, #s do
        crc = bxor(math.floor(crc / 256), CRC_TABLE[(bxor(crc % 256, s:byte(i))) + 1])
    end
    return bxor(crc, 0xFFFFFFFF)
end

local function le(n, bytes)
    local out = ""
    for _i = 1, bytes do
        out = out .. string.char(n % 256)
        n = math.floor(n / 256)
    end
    return out
end

--[[--
造一个 Stored 方式的 zip。
@param entries array of { name = "root/sub/x.lua", data = "…" }
@return bool
--]]
local function makeZip(path, entries)
    local body_parts, central = {}, {}
    local offset = 0
    for _i, e in ipairs(entries) do
        local name, data = e.name, e.data or ""
        local crc = crc32(data)
        local lh = string.char(0x50, 0x4B, 0x03, 0x04) .. le(20, 2) .. le(0, 2) .. le(0, 2)
            .. le(0, 2) .. le(0x2100, 2) .. le(crc, 4) .. le(#data, 4) .. le(#data, 4)
            .. le(#name, 2) .. le(0, 2) .. name
        body_parts[#body_parts + 1] = lh
        body_parts[#body_parts + 1] = data
        central[#central + 1] = string.char(0x50, 0x4B, 0x01, 0x02) .. le(20, 2) .. le(20, 2)
            .. le(0, 2) .. le(0, 2) .. le(0, 2) .. le(0x2100, 2) .. le(crc, 4) .. le(#data, 4)
            .. le(#data, 4) .. le(#name, 2) .. le(0, 2) .. le(0, 2) .. le(0, 2) .. le(0, 2)
            .. le(0, 4) .. le(offset, 4) .. name
        offset = offset + #lh + #data
    end
    local cd = table.concat(central)
    local eocd = string.char(0x50, 0x4B, 0x05, 0x06) .. le(0, 2) .. le(0, 2)
        .. le(#central, 2) .. le(#central, 2) .. le(#cd, 4) .. le(offset, 4) .. le(0, 2)
    return writefile(path, table.concat(body_parts) .. cd .. eocd)
end

local ZIP_DIR = TEST_ROOT .. "/zips"
ensureDir(ZIP_DIR)

-- ============================================================ 1. 造 zip 的工具本身对不对
print("=== 1. 自校验：手写的 zip 与 CRC32 是可信的 ===")
-- CRC32 先跟公认值对一次：这一步错了，后面所有"apply 成功"都是假绿
eq(crc32("The quick brown fox jumps over the lazy dog"), 0x414FA339,
    "1a CRC32 实现与公认校验值一致（做错了下面的 unzip 全过不了）")
local self_zip = ZIP_DIR .. "/self.zip"
ok(makeZip(self_zip, {
    { name = "rootdir/main.lua", data = "print('self test')\n" },
    { name = "rootdir/sub/other.lua", data = "return 42\n" },
}), "1b（前置）测试用的 zip 造出来了")
ensureDir(ZIP_DIR .. "/self_out")
os.execute(string.format("unzip -qq -o '%s' -d '%s'", self_zip, ZIP_DIR .. "/self_out"))
eq(readfile(ZIP_DIR .. "/self_out/rootdir/main.lua"), "print('self test')\n",
    "1c unzip 认这个手写 zip，内容一个字节不差（否则后面所有 apply 用例都不作数）")
eq(readfile(ZIP_DIR .. "/self_out/rootdir/sub/other.lua"), "return 42\n",
    "1d 子目录也能解开（GitHub 的包是带子目录的）")

-- ============================================================ 2. 版本：数字分段
print("=== 2. 版本号必须按数字分段比较 ===")
local function vt(s)
    local t = Ota:normalizeVersion(s)
    if not t then return nil end
    return table.concat(t, ".")
end
eq(vt("v0.2"), "0.2.0", "2a 「v0.2」归一化成三段（缺位补 0）")
eq(vt("0.2.0"), "0.2.0", "2b 已经三段的原样")
eq(vt("0.2.0-beta"), "0.2.0", "2c 后缀不影响版本段")
eq(vt("V1.2.3"), "1.2.3", "2d 大写 V 前缀也认")
eq(vt(""), nil, "2e 空串不是版本号")
eq(vt("abc"), nil, "2f 纯字母不是版本号")
eq(vt(nil), nil, "2g nil 不是版本号")
eq(vt({ 1, 2 }), nil, "2h 表不是版本号")
-- 头号坑：0.9 与 0.10 按字符串比会得出反了的结论
eq(Ota:compareVersions("0.9.0", "0.10.0"), -1,
    "2i 《头号坑》0.9.0 比 0.10.0 旧（字符串比较会得出 -1 反过来，年限就是这么丢的）")
eq(Ota:compareVersions("0.10.0", "0.9.0"), 1, "2j 反过来：0.10.0 比 0.9.0 新")
eq(Ota:compareVersions("0.2", "0.2.0"), 0, "2k 缺的那一位当 0：0.2 与 0.2.0 同一个版本")
eq(Ota:compareVersions("1.0.1", "1.0.0"), 1, "2l 最后一段不同也能比出来")
eq(Ota:compareVersions("v1.0", "v1.0"), 0, "2m 带前缀也能比")
eq(Ota:compareVersions("x", "1.0"), nil, "2n 一边认不出来就返回 nil（不许猜）")
eq(Ota:compareVersions("1.0", "y"), nil, "2o 另一边认不出来同样返回 nil")

-- ============================================================ 3. 白名单
print("=== 3. HttpClient 白名单（真的不会随便放行） ===")
eq(RealHttpClient.isHostAllowed("https://api.deepseek.com/chat/completions"), true,
    "3a DeepSeek 仍然放行（OTA 不该碰掉原有那一条路）")
eq(RealHttpClient.isHostAllowed("https://api.github.com/repos/x/releases/latest"), true,
    "3b GitHub API 放行（查 Release 用）")
eq(RealHttpClient.isHostAllowed("https://codeload.github.com/x/y/zip"), false,
    "3c 下载域**不在**常驻白名单里（只在跟随跳转时按次放行）")
eq(RealHttpClient.isHostAllowed("https://codeload.github.com/x/y/zip", RealHttpClient.REDIRECT_HOSTS),
    true, "3d 跟着跳转走时才对下载域放行")
eq(RealHttpClient.isHostAllowed("https://evil.example.com/steal", RealHttpClient.REDIRECT_HOSTS),
    false, "3e（对照组）传了 REDIRECT_HOSTS 也不是什么都放行")
eq(RealHttpClient.isHostAllowed("https://objects.githubusercontent.com/x"), false,
    "3f 另一个下载域同样不在常驻白名单")
eq(RealHttpClient.isHostAllowed("https://objects.githubusercontent.com/x",
    RealHttpClient.REDIRECT_HOSTS), true, "3g 跟随跳转时放行")
eq(RealHttpClient.isHostAllowed("http://api.github.com/x"), false,
    "3h 明文 http 一律不放行（会泄露）")
eq(RealHttpClient.isHostAllowed(nil), false, "3i nil 不放行")
eq(RealHttpClient.ALLOWED_HOSTS["codeload.github.com"], nil,
    "3j 常驻表里确实没有下载域（这条守的是「临时放行」没有变成「永久放行」）")
eq(type(RealHttpClient.MAX_REDIRECTS), "number", "3k 跳转上限是个数字（防止无限跟随）")

-- ============================================================ 4. latestRelease
print("=== 4. latestRelease：解析与三条失败分支 ===")
local RELEASE_JSON = [[{
  "tag_name": "v0.3.0",
  "name": "远望书友 v0.3.0",
  "zipball_url": "https://api.github.com/repos/x/y/zipball/v0.3.0",
  "html_url": "https://github.com/x/y/releases/tag/v0.3.0",
  "body": "更新说明正文",
  "published_at": "2026-09-20T00:00:00Z",
  "prerelease": false
}]]
http_gets = {}
NEXT_GET = { body = RELEASE_JSON, code = 200, status = "OK", err = nil }
local rel, err = Ota:latestRelease()
ok(type(rel) == "table", "4a 拿到 Release 信息")
eq(rel and rel.tag or nil, "v0.3.0", "4b tag 解析正确")
eq(rel and rel.name or nil, "远望书友 v0.3.0", "4c 名称解析正确")
eq(rel and rel.zipball_url or nil, "https://api.github.com/repos/x/y/zipball/v0.3.0",
    "4d 源码包地址解析正确")
eq(rel and rel.html_url or nil, "https://github.com/x/y/releases/tag/v0.3.0", "4e Release 页面地址")
eq(rel and rel.notes or nil, "更新说明正文", "4f 更新说明带出来了（要给用户看）")
eq(rel and rel.prerelease, false, "4g 预发布标记")
-- 请求发给了谁：不许是别的域，也不许带跳转跟随（查 Release 不需要跟随）
eq(http_gets[1] and http_gets[1].url or nil,
    "https://api.github.com/repos/WayneChen1994/YuanWangBookFriend.koplugin/releases/latest",
    "4h 请求的是自己仓库的 latest（不是别的仓库、不是通配地址）")
ok(type(http_gets[1]) == "table" and type(http_gets[1].headers) == "table"
    and type(http_gets[1].headers["User-Agent"]) == "string",
    "4i 带了 User-Agent（GitHub 没有它会直接 403）")

NEXT_GET = { body = RELEASE_JSON, code = 404, status = "Not Found", err = nil }
local rel404, err404 = Ota:latestRelease()
eq(rel404, nil, "4j 404（还没有 Release）时不返回半个表")
ok(type(err404) == "string" and err404:find("还没有发布", 1, true) ~= nil,
    "4k 404 给的是人话提示（不是 status code 本身）", tostring(err404))

NEXT_GET = { body = "", code = 500, status = "Server Error", err = nil }
local rel500, err500 = Ota:latestRelease()
eq(rel500, nil, "4l 服务端出错时不返回半个表")
ok(type(err500) == "string" and err500:find("500", 1, true) ~= nil,
    "4m 服务端出错时把状态码说给用户", tostring(err500))

NEXT_GET = { body = "<html>不是 JSON</html>", code = 200, status = "OK", err = nil }
local relbad, errbad = Ota:latestRelease()
eq(relbad, nil, "4n 返回不是 JSON 时不返回半个表")
ok(type(errbad) == "string", "4o 解析失败有原因（不是静默 nil）", tostring(errbad))

NEXT_GET = { body = "{}", code = 200, status = "OK", err = nil }
local relnozip, errnozip = Ota:latestRelease()
eq(relnozip, nil, "4p 没有 zipball 地址的 Release 不算可用（下载会变成瞎猜）")
ok(type(errnozip) == "string", "4q 缺 zipball 时有原因", tostring(errnozip))

NEXT_GET = { body = RELEASE_JSON, code = 200, status = "OK", err = "network down" }
local relnet, errnet = Ota:latestRelease()
eq(relnet, nil, "4r 网络失败时不返回半个表")
ok(type(errnet) == "string" and errnet:find("network down", 1, true) ~= nil,
    "4s 网络失败时把原因带出来（用户要能判断是自己没网还是别的）", tostring(errnet))

-- ============================================================ 5. checkForUpdate 的语义
print("=== 5. checkForUpdate：到底要不要更新 ===")
local REAL_VERSION = Config.VERSION
eq(type(REAL_VERSION), "string", "5a（前置）Config.VERSION 是个字符串")

NEXT_GET = { body = RELEASE_JSON, code = 200, status = "OK", err = nil }   -- 最新 v0.3.0
local info, ierr = Ota:checkForUpdate()
ok(type(info) == "table", "5b 拿到更新信息", tostring(ierr))
eq(info and info.available, true, "5c 0.2.0 对上 v0.3.0：需要更新")
eq(info and info.current or nil, REAL_VERSION, "5d current 取自 Config.VERSION（唯一来源）")
eq(info and info.latest or nil, "v0.3.0", "5e latest 取自 Release 的 tag")
eq(info and info.url or nil, "https://api.github.com/repos/x/y/zipball/v0.3.0",
    "5f 下载地址带出来了（UI 下一步要用）")

-- 同一版本：不许报"有更新"
local SAME_JSON = RELEASE_JSON:gsub("v0%.3%.0", REAL_VERSION)
NEXT_GET = { body = SAME_JSON, code = 200, status = "OK", err = nil }
local info2 = Ota:checkForUpdate()
eq(info2 and info2.available, false, "5g 版本相同时报「没有更新」（多刷一次界面不算更新）")

-- 《头号坑》：当前 0.2.0，最新 v0.10.0，必须判成"有更新"
NEXT_GET = { body = RELEASE_JSON:gsub("v0%.3%.0", "v0.10.0"), code = 200, status = "OK", err = nil }
local info3 = Ota:checkForUpdate()
eq(info3 and info3.available, true,
    "5h《头号坑》0.2.0 对 v0.10.0 必须判成有更新（按字符串比会得出「0.10 比 0.2 旧」的反论）")
eq(info3 and info3.latest or nil, "v0.10.0", "5i 最新版本号原样带出来")

-- 老版本比新版本还新（用户手装了更新的包）：不许报"有更新"
Config.VERSION = "9.9.9"
NEXT_GET = { body = RELEASE_JSON, code = 200, status = "OK", err = nil }
local info4 = Ota:checkForUpdate()
eq(info4 and info4.available, false, "5j 本地比远端新时不报更新（不许降级）")
Config.VERSION = REAL_VERSION

-- Config.VERSION 缺失：必须报错，不许静默当成"没更新"
Config.VERSION = nil
NEXT_GET = { body = RELEASE_JSON, code = 200, status = "OK", err = nil }
local info5, ierr5 = Ota:checkForUpdate()
eq(info5, nil, "5k 版本号丢了时不返回更新信息")
ok(type(ierr5) == "string", "5l 版本号丢了时有原因（静默会让人以为「查过了，没有」）", tostring(ierr5))
Config.VERSION = REAL_VERSION

-- 认不出的 tag：同样要报错
NEXT_GET = { body = RELEASE_JSON:gsub("v0%.3%.0", "not-a-version"), code = 200, status = "OK", err = nil }
local info6, ierr6 = Ota:checkForUpdate()
eq(info6, nil, "5m tag 认不出来时不返回更新信息")
ok(type(ierr6) == "string", "5n tag 认不出来时有原因", tostring(ierr6))

-- ============================================================ 6. download
print("=== 6. download：只写该写的，认不出就停 ===")
-- 一个够真的假 zip：头四个字节必须是 zip 的 magic
local FAKE_ZIP = string.char(0x50, 0x4B, 0x03, 0x04) .. ("0123456789"):rep(20)
local down_path = TEST_ROOT .. "/download/update.zip"
http_gets = {}
NEXT_GET = { body = FAKE_ZIP, code = 200, status = "OK", err = nil }
local ok_dl, err_dl = Ota:download("https://api.github.com/repos/x/y/zipball/v0.3.0", down_path)
eq(ok_dl, true, "6a 下载成功", tostring(err_dl))
eq(readfile(down_path), FAKE_ZIP, "6b 落盘的内容与拿到的一致（一个字节不差）")
-- 接线的一部分：GitHub 的 zipball 一定 302，不跟随跳转根本下不下来
eq(type(http_gets[1]) == "table" and type(http_gets[1].opts) == "table"
    and http_gets[1].opts.follow_redirects, true,
    "6c《接线》下载必须显式开启跳转跟随（GitHub 的 zipball 会 302 到 codeload）")

NEXT_GET = { body = "", code = 200, status = "OK", err = nil }
local ok_dl2, err_dl2 = Ota:download("https://api.github.com/x", down_path .. "2")
eq(ok_dl2, false, "6d 下载下来是空的不算成功")
ok(type(err_dl2) == "string", "6e 空内容有原因", tostring(err_dl2))

NEXT_GET = { body = "<html>404</html>", code = 200, status = "OK", err = nil }
eq(Ota:download("https://api.github.com/x", down_path .. "3"), false, "6f 不是 zip 的不算成功")

NEXT_GET = { body = FAKE_ZIP, code = 302, status = "Found", err = nil }
local ok_dl4, err_dl4 = Ota:download("https://api.github.com/x", down_path .. "4")
eq(ok_dl4, false, "6g 最终状态码不是 200 的不算成功")
ok(type(err_dl4) == "string" and err_dl4:find("302", 1, true) ~= nil,
    "6h 状态码不对时把状态说出来", tostring(err_dl4))

NEXT_GET = { body = FAKE_ZIP, code = 200, status = "OK", err = "timeout" }
local ok_dl5, err_dl5 = Ota:download("https://api.github.com/x", down_path .. "5")
eq(ok_dl5, false, "6i 网络失败不算成功")
ok(type(err_dl5) == "string" and err_dl5:find("timeout", 1, true) ~= nil,
    "6j 网络失败时把原因带出来", tostring(err_dl5))

-- 超大文件：不许傻乎乎地写下去（设备空间有限，且那多半不是更新包）
local BIG = string.char(0x50, 0x4B, 0x03, 0x04) .. string.rep("z", Ota.MAX_DOWNLOAD_BYTES)
NEXT_GET = { body = BIG, code = 200, status = "OK", err = nil }
eq(Ota:download("https://api.github.com/x", down_path .. "6"), false,
    "6k 超过大小上限的包直接拒收（不像一个插件更新包）")

eq(Ota:download(nil, down_path .. "7"), false, "6l 没有地址时拒绝")
eq(Ota:download("https://api.github.com/x", nil), false, "6m 没有落盘路径时拒绝")

-- ============================================================ 7. backup
print("=== 7. backup：只打代码文件，落在 data 之内 ===")
local TARGET = TEST_ROOT .. "/plugin"
ensureDir(TARGET .. "/ui")
ensureDir(TARGET .. "/ywbf")
ensureDir(TARGET .. "/data/history")
writefile(TARGET .. "/main.lua", "print('old')\n")
writefile(TARGET .. "/ui/settings.lua", "print('old ui')\n")
writefile(TARGET .. "/ywbf/ota.lua", "print('old ota')\n")
writefile(TARGET .. "/data/key.enc", "SECRET-KEY-DO-NOT-BACKUP")
writefile(TARGET .. "/data/history/h.json", "{\"entries\":[]}")
-- 这段在 2026-09-20 被**整体反向**过一次，理由写在这里，免得以后当成笔误改回去：
-- 原先断言"备份里没有 data/"（多一份明文副本就多一处风险），现改为"备份里必须有 data/"。
-- **备份的定位是回滚点，不是代码快照**。`apply` 靠 `--exclude=data` 保证不动用户数据，
-- 但那只是一行参数，今天兜着、明天被人动一下就没人兜了；备份是这条链路的第二道防线，
-- 两道防线不能共用同一个开关。代价只是插件目录里多一份 tarball（Key 本来就以明文
-- 存在 data/settings.json 里），收益是"最坏情况能全量还原"。
local backup_path, err_bk = Ota:backup(TARGET)
ok(type(backup_path) == "string", "7a 备份成功", tostring(err_bk))
ok(type(backup_path) == "string" and backup_path:find("/data/ota_backup/", 1, true) ~= nil,
    "7b 备份落在 data/ota_backup 之下（零污染：卸载删目录即净）", tostring(backup_path))
eq(exists(backup_path), true, "7c 备份文件真的在磁盘上")

-- 把备份解开看里面到底有什么：这是唯一能证明"用户的东西确实在包里"的办法
-- 注意：`exists()` 是 `readfile(path) ~= nil`，**对目录永远返回 false**
-- （目录读不出内容）。原来那条 `7h 备份里连 data 目录都没有` 就是这么恒绿的——
-- 不管备份里到底有没有 data，它都过。判断目录必须单独用 `test -d`。
local function isDir(path)
    if type(path) ~= "string" or path == "" then return false end
    local rc = os.execute(string.format("test -d '%s'", path))
    return rc == 0 or rc == true
end

local BK_OUT = TEST_ROOT .. "/backup_out"
ensureDir(BK_OUT)
os.execute(string.format("tar -xzf '%s' -C '%s'", backup_path, BK_OUT))
eq(readfile(BK_OUT .. "/main.lua"), "print('old')\n", "7d 备份里有 main.lua")
eq(readfile(BK_OUT .. "/ui/settings.lua"), "print('old ui')\n", "7e 备份里有子目录里的代码文件")
eq(exists(BK_OUT .. "/data/key.enc"), true,
    "7f《硬约束》备份里有 data/ 下的 Key（备份是回滚点，不是代码快照）")
eq(exists(BK_OUT .. "/data/history/h.json"), true, "7g 备份里也有历史记录")
eq(isDir(BK_OUT .. "/data"), true, "7h 备份里有 data 目录")
-- 对照组：7f/7g 得是"真的打进去了"，而不是"整包打空了还恰好都 exists"
eq(readfile(BK_OUT .. "/ui/settings.lua"), "print('old ui')\n",
    "7h'（对照组）备份包里代码文件也还在（否则 7f/7g 是空包上的假绿）")

--[[--
自我递归防护：备份目录自己就躺在 `data/ota_backup` 下面，不排除的话
第二次备份会把第一次的包整个吞进去，第三次再吞一次，体积指数膨胀，
很快就把设备上那点空间吃光。
--]]
eq(isDir(BK_OUT .. "/data/ota_backup"), false,
    "7j《硬约束》备份包不含 ota_backup 自身（用 isDir，exists() 对目录恒为 false 会假绿）")
eq(isDir(BK_OUT .. "/data/ota_stage"), false, "7k 备份包也不含 ota_stage 中转目录")
-- 对照组：7j/7k 得是"排除规则在起作用"，而不是"压根没建过这两个目录"
ok(isDir(TARGET .. "/data/ota_backup"),
    "7j'（对照组）插件目录里确实存在 ota_backup 目录（否则 7j 是'没这东西'的假绿）")

-- 体积不暴涨（吞了第一次的话会翻倍）
local function sizeOf(p)
    local fh = type(p) == "string" and io.open(p, "rb") or nil
    if not fh then return 0 end
    local n = fh:seek("end")
    fh:close()
    return n or 0
end
local backup_path2 = Ota:backup(TARGET)
local sz1, sz2 = sizeOf(backup_path), sizeOf(backup_path2)
ok(sz2 > 0 and sz2 < sz1 * 3 + 256,
    "7l 第二次备份体积没有暴涨（吞了第一次的话会翻倍）",
    tostring(sz1) .. " -> " .. tostring(sz2))

eq(Ota:backup(nil), nil, "7i 没有目录时拒绝")

-- ============================================================ 8. apply
print("=== 8. apply：铺新版本，但绝不碰 data/ ===")
-- 新版本：GitHub 那种"外面套一层根目录"的结构
local NEW_ZIP = ZIP_DIR .. "/new.zip"
ok(makeZip(NEW_ZIP, {
    { name = "WayneChen1994-YuanWangBookFriend.koplugin-abc123/main.lua", data = "print('NEW')\n" },
    { name = "WayneChen1994-YuanWangBookFriend.koplugin-abc123/_meta.lua", data = "return {}\n" },
    { name = "WayneChen1994-YuanWangBookFriend.koplugin-abc123/ui/settings.lua", data = "print('NEW ui')\n" },
    { name = "WayneChen1994-YuanWangBookFriend.koplugin-abc123/data/key.enc", data = "HACKED" },
}), "8a（前置）新版本的包造好了（里面刻意带了一个 data/，看它能不能守住）")

-- target 里预先放好"用户的东西"和"本地独有的文件"
writefile(TARGET .. "/data/key.enc", "SECRET-KEY-DO-NOT-BACKUP")
writefile(TARGET .. "/local_only.lua", "print('only in target')\n")
local ok_apply, err_apply = Ota:apply(NEW_ZIP, TARGET)
eq(ok_apply, true, "8b apply 成功", tostring(err_apply))
eq(readfile(TARGET .. "/main.lua"), "print('NEW')\n", "8c main.lua 被换成了新版本")
eq(readfile(TARGET .. "/ui/settings.lua"), "print('NEW ui')\n", "8d 子目录里的文件也换了")
-- 这两条是整个 OTA 的命门
eq(readfile(TARGET .. "/data/key.enc"), "SECRET-KEY-DO-NOT-BACKUP",
    "8e《第一条命门》包里的 data/key.enc 没有盖掉用户真正的 Key")
eq(exists(TARGET .. "/local_only.lua"), true,
    "8f《零删除》target 里独有的文件还在（apply 只覆盖，不删任何东西）")
eq(exists(TARGET .. "/data/history/h.json"), true, "8g 历史记录也还在")

-- 卸载检查：包里那层 GitHub 根目录不许被铺进 target
eq(exists(TARGET .. "/WayneChen1994-YuanWangBookFriend.koplugin-abc123"), false,
    "8h 包外层那层自动生成的根目录被剥掉了（不会在插件目录里留下一堆嵌套）")

--[[--
《真实形状》GitHub 的源码包是**两层套娃**：外层 `<owner>-<repo>-<sha>/`，
里面还有一层仓库目录（`YuanWangBookFriend.koplugin/`），插件文件在更里面一层。

这一条是拿真包对过之后补的：原来只剥一层，真包进来会停在一句
"包里没有 main.lua"上——而包是好的，是假设错了。用例现在按真实形状来造。
--]]
local REALZIP = ZIP_DIR .. "/realshape.zip"
ok(makeZip(REALZIP, {
    { name = "WayneChen1994-YuanWangBookFriend.koplugin-a5a2489/README.md", data = "# readme\n" },
    { name = "WayneChen1994-YuanWangBookFriend.koplugin-a5a2489/tools/check.lua", data = "print('tool')\n" },
    { name = "WayneChen1994-YuanWangBookFriend.koplugin-a5a2489/YuanWangBookFriend.koplugin/_meta.lua",
      data = "return {}\n" },
    { name = "WayneChen1994-YuanWangBookFriend.koplugin-a5a2489/YuanWangBookFriend.koplugin/main.lua",
      data = "print('REAL SHAPE')\n" },
    { name = "WayneChen1994-YuanWangBookFriend.koplugin-a5a2489/YuanWangBookFriend.koplugin/ui/settings.lua",
      data = "print('REAL ui')\n" },
    { name = "WayneChen1994-YuanWangBookFriend.koplugin-a5a2489/YuanWangBookFriend.koplugin/data/key.enc",
      data = "HACKED" },
}), "8i（前置）按真实形状造的包做好了")
local ok_real, err_real = Ota:apply(REALZIP, TARGET)
eq(ok_real, true, "8j《真实形状》两层套娃的包能装进去", tostring(err_real))
eq(readfile(TARGET .. "/main.lua"), "print('REAL SHAPE')\n",
    "8k 装进去的是内层的插件本体（不是外层那个 README）")
eq(readfile(TARGET .. "/data/key.enc"), "SECRET-KEY-DO-NOT-BACKUP",
    "8l《真实形状》包里那份假的 data/key.enc 也没盖掉真 Key")
eq(exists(TARGET .. "/README.md"), false, "8m 仓库里的 README 没被铺进插件目录")
eq(exists(TARGET .. "/tools"), false, "8n 仓库里的 tools/ 也没被铺进来")

-- 各种拒绝路径
writefile(ZIP_DIR .. "/notzip.zip", "这不是一个 zip")
local ok_bad, err_bad = Ota:apply(ZIP_DIR .. "/notzip.zip", TARGET)
eq(ok_bad, false, "8o 不是 zip 的包直接拒收")
ok(type(err_bad) == "string", "8p 拒收时有原因", tostring(err_bad))
eq(readfile(TARGET .. "/main.lua"), "print('REAL SHAPE')\n",
    "8q 拒收之后 target 一点没动（不许「先破坏再报错」）")

local TWOROOT = ZIP_DIR .. "/tworoot.zip"
ok(makeZip(TWOROOT, {
    { name = "rootA/main.lua", data = "print('a')\n" },
    { name = "rootA/_meta.lua", data = "return {}\n" },
    { name = "rootB/main.lua", data = "print('b')\n" },
    { name = "rootB/_meta.lua", data = "return {}\n" },
}), "8r（前置）包里有两处都像插件本体的包造好了")
local ok_two, err_two = Ota:apply(TWOROOT, TARGET)
eq(ok_two, false, "8s 两处都像插件本体时拒收（装错一个更糟）")
ok(type(err_two) == "string", "8t 拒收时有原因", tostring(err_two))
--[[--
对照组：8s 只比"返回了 false"，而"因为找不到插件本体才失败"同样返回 false。
去掉"多处就拒收"那个判断之后，流程会继续往下找、最后以"找不到本体"收尾，
8s 依旧是绿的——**红的原因和绿的原因混在了一起**。
所以这里把"拒收的理由"也钉住：必须是"多处都像本体"，不是碰巧失败在别处。
（这条是被变异试出来的：L11 打掉 `#hits > 1` 之后 8s 竟然还是绿的。）
--]]
ok(type(err_two) == "string" and err_two:find("都像是插件本体", 1, true) ~= nil,
    "8s'（对照组）拒收理由是「多处都像插件本体」，不是碰巧失败在别处", tostring(err_two))

local NOMAIN = ZIP_DIR .. "/nomain.zip"
ok(makeZip(NOMAIN, {
    { name = "someroot/README.md", data = "hello\n" },
}), "8u（前置）没有插件本体的包造好了")
local ok_nm, err_nm = Ota:apply(NOMAIN, TARGET)
eq(ok_nm, false, "8v 包里找不到插件本体时拒收（多半是拿错了包）")
ok(type(err_nm) == "string", "8w 拒收时有原因", tostring(err_nm))
ok(type(err_nm) == "string" and err_nm:find("找不到插件本体", 1, true) ~= nil,
    "8v'（对照组）拒收理由是「找不到插件本体」，和「多处都像本体」是两种原因",
    tostring(err_nm))
eq(readfile(TARGET .. "/main.lua"), "print('REAL SHAPE')\n",
    "8x 这些拒收之后 target 同样没动")

eq(Ota:apply(nil, TARGET), false, "8y 没有包路径时拒绝")
eq(Ota:apply(NEW_ZIP, nil), false, "8z 没有目标目录时拒绝")
eq(Ota:apply(ZIP_DIR .. "/does_not_exist.zip", TARGET), false, "8aa 包不在时拒绝")

-- ============================================================ 9. rollback
print("=== 9. rollback：装坏了能回去 ===")
local ok_rb, err_rb = Ota:rollback(backup_path, TARGET)
eq(ok_rb, true, "9a 回滚成功", tostring(err_rb))
eq(readfile(TARGET .. "/main.lua"), "print('old')\n",
    "9b 回滚之后 main.lua 回到了备份时的内容（不是「新版本还在」）")
eq(readfile(TARGET .. "/ui/settings.lua"), "print('old ui')\n", "9c 子目录里的文件也回去了")
eq(readfile(TARGET .. "/data/key.enc"), "SECRET-KEY-DO-NOT-BACKUP",
    "9d 回滚没有动用户的 Key")
eq(exists(TARGET .. "/local_only.lua"), true, "9e 回滚也没有删掉本地独有的文件")
eq(Ota:rollback(nil, TARGET), false, "9f 没有备份路径时拒绝")
eq(Ota:rollback(backup_path, nil), false, "9g 没有目标目录时拒绝")

-- ============================================================ 10. UI 接线
print("=== 10. UI：关于菜单与检查更新 ===")
local SettingsUI = require("ui/settings")
local about = SettingsUI:buildAboutMenu()
ok(type(about) == "table", "10a 关于菜单是个表")
eq(#about, 4, "10b 四项：插件名 / 版本 / 数据目录 / 检查更新")
local about_texts = {}
for _i, it in ipairs(about or {}) do about_texts[#about_texts + 1] = tostring(it.text) end
local joined = table.concat(about_texts, "\n")
ok(joined:find(tostring(Config.VERSION), 1, true) ~= nil,
    "10c 版本号写出来了，而且就是 Config.VERSION 那一个数", joined)
ok(joined:find(tostring(Config.paths.data), 1, true) ~= nil,
    "10d 数据目录位置写出来了（用户要连电脑去拷东西）", joined)
local has_check = false
for _i, it in ipairs(about or {}) do
    if it.text == _("检查更新") and type(it.callback) == "function" then has_check = true end
end
ok(has_check, "10e 有「检查更新」这一项且能点")

-- 主菜单里也得有入口
local menu = SettingsUI:buildMenu({})
local has_about = false
for _i, it in ipairs(menu or {}) do
    if type(it.text) == "string" and it.text:find("关于", 1, true) then has_about = true end
end
ok(has_about, "10f 主菜单里有「关于」入口（找不到入口等于没有这个功能）")

-- 真的点一次"检查更新"：已是最新 -> 明确告诉用户
NEXT_GET = { body = SAME_JSON, code = 200, status = "OK", err = nil }
infos = {}
SettingsUI:checkUpdate()
local msg_up = infos[#infos] and infos[#infos].info_text or ""
ok(msg_up:find("已经是最新版本", 1, true) ~= nil,
    "10g 已是最新时明确说「已经是最新版本」（什么都不说等于让人猜）", msg_up)
ok(msg_up:find(tostring(Config.VERSION), 1, true) ~= nil,
    "10h 提示里带着当前版本号（用户核对用）", msg_up)

-- 查不到时必须说清原因，不许静默
NEXT_GET = { body = "", code = 200, status = "OK", err = "network down" }
infos = {}
SettingsUI:checkUpdate()
local msg_err = infos[#infos] and infos[#infos].info_text or ""
ok(msg_err:find("network down", 1, true) ~= nil,
    "10i 查不到时把原因说出来（静默会让人以为「查过了，没有」）", msg_err)

-- 有新版本 -> 弹二次确认，且**不**在确认前动任何文件
NEXT_GET = { body = RELEASE_JSON, code = 200, status = "OK", err = nil }
infos = {}
last_confirm = nil
SettingsUI:checkUpdate()
ok(type(last_confirm) == "table", "10j 有新版本时弹的是确认框（下载安装不该一个误触就跑起来）")
ok(type(last_confirm) == "table" and type(last_confirm.ok_callback) == "function",
    "10k 确认框有确认回调")
--[[--
确认之前不许动任何文件：弹个框就顺手备份一遍的话，点了「以后再说」的用户
会白白多出一份备份，而且他会以为"我还没确认，怎么已经开始了"。
这一条特意写成"数一下备份包有没有变多"，而不是"备份目录存不存在"——
后者在第一次跑和第二次跑的答案不一样，是典型的假绿。
--]]
--[[--
计数用的临时文件**不能落在被数的目录里**：备份目录在第一次跑时还不存在，
`sh: can't create .../ota_backup/.ywbf_count` 会把计数静默变成 0，
于是 10l 就退化成"0 等于 0"——一条永远绿、什么也没守住的断言。
（这条是被 shell 的那句报错咬出来的，不是推想出来的。）
--]]
local COUNT_TMP = (ZIP_DIR or ".") .. "/.ywbf_count"
local function countBackups(dir)
    local tmp = COUNT_TMP
    os.execute(string.format("ls -1 '%s' 2>/dev/null | grep -c '\\.tar\\.gz$' > '%s'", dir, tmp))
    local raw = readfile(tmp)
    os.remove(tmp)
    --[[--
    gsub 返回**两个**值（新串 + 替换次数），直接塞进 tonumber 就变成了
    `tonumber(s, 次数)` —— 次数不在 2..36 之内时 Lua 会报
    "base out of range"，看着像 tonumber 坏了，实际是自己多传了一位。
    这个坑（`or` 短路也是同一个性质）在 Lua 里踩一次要查半天。
    --]]
    local cleaned = string.gsub(raw or "", "%s", "")
    local n = tonumber(cleaned)
    return n or 0
end
local bk_dir = Config.paths.data .. "/ota_backup"
local before_count = countBackups(bk_dir)
-- 走一次"有新版本"的检查（只弹确认，不点确认）
infos = {}
last_confirm = nil
SettingsUI:checkUpdate()
eq(countBackups(bk_dir), before_count,
    "10l 只是弹确认框时没有真的开始备份（点了「以后再说」不该留下痕迹）")
--[[--
对照组：10l 比的是"两个数字相等"，而"计数函数坏了、永远返回 0"同样能让两个数字相等
——那就是一条永远绿、什么也没守住的断言（上一版正是这样：临时文件写进了还不存在
的备份目录，`sh: can't create` 让计数静默变 0）。
所以这里真的造一份备份包，确认计数会 +1，再删掉，
保证 10l 比的是"确实没变"，而不是"两边都数错了"。
--]]
ensureDir(bk_dir)
local probe_bk = bk_dir .. "/backup-probe-19700101-000000.tar.gz"
writefile(probe_bk, "probe\n")
local probe_count = countBackups(bk_dir)
os.remove(probe_bk)
eq(probe_count, before_count + 1,
    "10l'（对照组）计数函数真的能数出多出来的那一份（否则 10l 是「0 等于 0」的假绿）")

-- ============================================================ 弹层纪律（QA 的 C13）
--[[--
下面这几条是 C13 判据在我这边的一份**独立实现**。

同一件事两边各写一遍断言，比"我照着 QA 的判据改完、然后他说绿了"更可信：
他的桩和我的桩是两套，两边都绿才算真绿。三件事分别验：
  · 进度提示不带 timeout（1 秒后自己消失 = 用户干等好几秒）；
  · 结果弹窗 show 之前进度提示已经被 close（不许并排挂着）；
  · 安装的三段（备份/下载/安装）复用同一个弹层，全程峰值 ≤ 1。
--]]
local function wtext(w)
    if type(w) ~= "table" then return "" end
    return tostring(w.text or w.info_text or "")
end

NEXT_GET = { body = RELEASE_JSON, code = 200, status = "OK", err = nil }
infos = {}
ui_events = {}
SettingsUI:checkUpdate()

local shown = {}
for _i, ev in ipairs(ui_events) do
    if ev.op == "show" then shown[#shown + 1] = ev.w end
end
local progress, result = shown[1], (#shown >= 2) and shown[#shown] or nil

ok(#shown >= 1,
    "10m（前置）检查更新过程中确实弹了东西（一个都没弹的话，下面几条全是空转）",
    "shown=" .. #shown)
ok(type(progress) == "table" and type(result) == "table" and progress ~= result,
    "10m'（对照）进度提示与结果弹窗是**两个不同的**弹层（同一个的话下面两条在自言自语）",
    string.format("progress=%q result=%q",
        tostring(wtext(progress)), tostring(wtext(result))))
if type(progress) == "table" and type(result) == "table" and progress ~= result then
    ok(progress.timeout == nil or progress.timeout == 0,
        "10n 进度提示**不带 timeout**（查询是异步的、要跑好几秒；"
        .. "1 秒后自己消失等于让用户干等）",
        "timeout=" .. tostring(progress.timeout) .. " text=" .. tostring(wtext(progress)))

    local i_close, i_show_result = nil, nil
    for _i, ev in ipairs(ui_events) do
        if ev.op == "close" and ev.w == progress and not i_close then i_close = _i end
        if ev.op == "show" and ev.w == result then i_show_result = _i end
    end
    ok(i_close ~= nil,
        "10o（前置）进度提示**真的被 close 过**（没 close 过就谈不上先后）",
        "events=" .. #ui_events)
    if i_close ~= nil and i_show_result ~= nil then
        ok(i_close < i_show_result,
            "10o'【顺序】结果弹窗 show 之前，进度提示**已经被 close**（不许两个并排挂着）",
            string.format("close(进度)=#%d show(结果)=#%d", i_close, i_show_result))
    end
end
ok(peakConcurrent(ui_events) <= 1,
    "10p 检查更新全程，同时挂着的弹层最多 1 个",
    "peak=" .. peakConcurrent(ui_events))

--[[--
安装那条链路是**同步**串起来的（备份 → 下载 → 安装，主循环被堵住），
所以三段提示如果各自 show 一层，等循环转过来就是好几层摞在一起。
这里真跑一遍 installUpdate（下载用本地造的真 zip 喂进去），数峰值。
--]]
local zip_bytes = readfile(NEW_ZIP)
NEXT_GET = { body = zip_bytes, code = 200, status = "OK", err = nil }
Config.paths.plugin = TARGET
ui_events = {}
SettingsUI:installUpdate({
    url = "https://api.github.com/repos/x/y/zipball/v9.9.9",
    current = Config.VERSION,
    latest = "v9.9.9",
})
local inst_peak = peakConcurrent(ui_events)
ok(#ui_events > 0,
    "10q（前置）安装过程确实弹过东西（一个都没弹的话下一条是空转）",
    "events=" .. #ui_events)
ok(inst_peak <= 1,
    "10q' 安装全程同时挂着的弹层最多 1 个（三段换成同一层的文案，先关再换）",
    "peak=" .. inst_peak)

-- ============================================================ 11. 单一版本源（静态）
print("=== 11. 版本号只有一处 ===")
local function src_of(rel)
    return readfile(PLUGIN_DIR .. "/" .. rel)
end
local config_src = src_of("ywbf/config.lua")
local settings_src = src_of("ui/settings.lua")
local meta_src = src_of("_meta.lua")
ok(type(config_src) == "string" and config_src:find('Config.VERSION = "', 1, true) ~= nil,
    "11a Config.VERSION 定义在 config.lua 里")
ok(type(settings_src) == "string" and settings_src:find("Config.VERSION", 1, true) ~= nil,
    "11b 设置页取的是 Config.VERSION（不是抄一份）")
ok(type(meta_src) == "string" and meta_src:find("VERSION", 1, true) == nil,
    "11c _meta.lua 里没有第二份版本号（两份迟早漂移）")
--[[--
对照组：除了 config.lua，**别处的代码里**不许再出现那个版本号字面量。

要先把注释剥掉再搜：直接搜源码的话，注释里写个例子也会命中，
那条断言就变成了"不许在注释里提到版本号"，而真正要防的是第二份定义。
（剥注释这个事本身有风险——字符串里的 `--` 会被误剥——所以下面还配了
一条更硬的、不依赖剥注释的断言：不许有第二处 `…VERSION = "…"` 的赋值。）
--]]
local function stripComments(src)
    local out, in_long = {}, false
    for line in (src or ""):gmatch("[^\n]*\n?") do
        if in_long then
            if line:find("]]", 1, true) then in_long = false end
        else
            local start_long = line:find("--%[%[", 1)
            if start_long then
                in_long = true
                local after = line:sub(start_long + 4)
                if after:find("]]", 1, true) then in_long = false end
                line = line:sub(1, start_long - 1)
            end
            local cut = line:find("--", 1, true)
            if cut then line = line:sub(1, cut - 1) end
            out[#out + 1] = line
        end
    end
    return table.concat(out, "\n")
end
local others = {}
for _i, rel in ipairs({ "main.lua", "ui/settings.lua", "ui/favorites.lua", "ui/asker.lua",
    "ui/chatdialog.lua", "ui/toastcard.lua", "ui/suggestpicker.lua", "ywbf/ota.lua",
    "ywbf/store.lua", "ywbf/export.lua", "_meta.lua", "ywbf/prompts.lua" }) do
    local s = src_of(rel)
    if type(s) == "string" and stripComments(s):find(tostring(Config.VERSION), 1, true) ~= nil then
        others[#others + 1] = rel
    end
end
ok(#others == 0, "11d（对照组）除 config.lua 之外的**代码**里没有第二个版本号",
    table.concat(others, ","))
-- 更硬的一条：只要别处再写一次 `VERSION = "…"`，就是第二份定义（不依赖剥注释）
local dup_defs = {}
for _i, rel in ipairs({ "main.lua", "ui/settings.lua", "ywbf/ota.lua", "_meta.lua" }) do
    local s = src_of(rel)
    if type(s) == "string" and s:find("VERSION%s*=%s*\"", 1) ~= nil then
        dup_defs[#dup_defs + 1] = rel
    end
end
ok(#dup_defs == 0, "11e（对照组）别处没有第二处 VERSION 赋值（第二份版本号迟早漂移）",
    table.concat(dup_defs, ","))

-- ============================================================ 12. 目标目录护栏
--[[--
`isSafeTargetDir` 是后面加上的，加的时候**没有一条断言守着它**——
那种状态等于没加：下一个人顺手删掉那三行，测试照样全绿。

这一节专守两件事：
  · 带 `..` 的目标目录必须被拒（不拒的话 tar 会把文件铺到插件目录之外）；
  · 路径里的 shell 元字符必须被拒（`os.execute` 是把路径拼进 shell 串的）。
第二条特意写成"看那条注入的命令有没有真的被执行"，而不是"有没有报错"——
报错谁都会，真正要验的是**没被打穿**。
--]]
print("=== 12. 目标目录护栏（不许写到插件目录之外） ===")
-- 先清场：这个路径在 TEST_ROOT 之外，不清的话第二次跑会带着上一次的残留，
-- 于是"两次跑结果一致"这件事本身就不可信了。
local evil_dir = TEST_ROOT .. "/../../evil_out"
os.execute("rm -rf '" .. evil_dir .. "'")
--[[--
`pwned` 必须放在**不含 `..`** 的路径上。

第一版我把它放在 `TEST_ROOT/../../pwned`，于是那条注入串里自带 `..`，
被 `isSafeTargetDir` 的另一条规则（拒 `..`）挡了下来——12f 绿了，
但绿的原因是"另一条护栏替它挡的"，shell 元字符那条根本没被验到。
（这是变异 L16 变绿逼出来的：删掉元字符判断之后 12f 照样绿。）
--]]
local pwned = TEST_ROOT .. "/pwned"
os.remove(pwned)

local ok_e1, err_e1 = Ota:apply(NEW_ZIP, TARGET .. "/../../evil_out")
eq(ok_e1, false, "12a apply 拒绝带 `..` 的目标目录（会把文件铺到插件目录之外）")
ok(type(err_e1) == "string", "12b 拒收时有原因", tostring(err_e1))
eq(isDir(evil_dir), false, "12c 拒收之后别处没有真的被建出来")

eq(Ota:rollback(backup_path, TARGET .. "/../../evil_out"), false,
    "12d rollback 同样拒绝（同一个风险面）")
local bk_evil, err_bk_evil = Ota:backup(TARGET .. "/../../evil_out")
eq(bk_evil, nil, "12e backup 同样拒绝", tostring(err_bk_evil))

--[[--
注入串：路径里放一个单引号把 `tar ... -C '<path>'` 的单引号提前闭合，
后面接一条 `touch` 再重新开一个单引号把语法补回去。
挡住了的话 `/mnt/us/ywbf_dev/pwned` 就不会出现。
--]]
-- 整条路径里刻意不含 `..`：让这一条**只**验元字符护栏，不蹭别的护栏
local evil_shell = TEST_ROOT .. "/plugin'; touch '" .. pwned .. "'; echo '"
eq(Ota:apply(NEW_ZIP, evil_shell), false, "12f 拒绝带 shell 元字符的路径")
eq(exists(pwned), false, "12f' 那条注入的命令**没有被执行**（真被挡住了，不是仅仅报错）")

-- 对照组：上面五条全是"拒绝"，而"什么都拒"也能让五条全绿
eq(type(Ota:backup(TARGET)) == "string", true,
    "12g（对照组）正常路径仍然放行（否则 12a-12f 是「什么都拒」的假绿）")

print(string.format("=== 合计 %d 通过 / %d 失败 ===", passed, failed))
if failed > 0 then os.exit(1) end
os.exit(0)
