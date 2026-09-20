--[==[
QA 独立验收：**插件 OTA 更新 + 关于菜单**（`ywbf/ota.lua` / `Config.VERSION` / 关于对话框）。

本脚本只做验收，**不改任何实现代码**。断言按已经定死的接口签名写死：

  Config.VERSION = "0.2.0"                       -- 版本单一来源，写在 ywbf/config.lua
  Ota.REPO
  Ota:normalizeVersion(s)         -> {a,b,c} | nil
  Ota:compareVersions(a, b)       -> 1 | 0 | -1 | nil
  Ota:latestRelease()             -> {tag,name,zipball_url,html_url,notes}, nil | nil, err
  Ota:checkForUpdate()            -> {available,current,latest,url,html_url,notes}, err
  Ota:download(url, dest_path)    -> true, nil | false, err
  Ota:backup(target_dir)          -> backup_path, nil | nil, err
  Ota:apply(zip_path, target_dir) -> true, nil | false, err
  Ota:rollback(backup_path, target_dir) -> true, nil | false, err

跑法（KPW4）：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     YWBF_PLUGIN_DIR=/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin \
     YWBF_TEST_DIR=/mnt/us/ywbf_dev/ota_data \
     ./luajit /mnt/us/ywbf_dev/tools/qa_verify_ota.lua

变异跑法（**只准用副本，绝不在真插件目录上做**）：
  cp -r /mnt/us/koreader/plugins/YuanWangBookFriend.koplugin /mnt/us/ywbf_dev/mutplugin
  # 在 /mnt/us/ywbf_dev/mutplugin 上改，然后：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     YWBF_PLUGIN_DIR=/mnt/us/ywbf_dev/mutplugin \
     YWBF_TEST_DIR=/mnt/us/ywbf_dev/ota_data \
     YWBF_OTA_REGRESSION=0 \
     ./luajit /mnt/us/ywbf_dev/tools/qa_verify_ota.lua
  rm -rf /mnt/us/ywbf_dev/mutplugin

环境变量：
  YWBF_PLUGIN_DIR      被测插件目录（默认真机插件目录；变异时指向 /mnt/us/ywbf_dev 下的副本）
  YWBF_TEST_DIR        临时目录（默认 /mnt/us/ywbf_dev/ota_data；只允许落在 ywbf_dev 内）
  YWBF_OTA_REGRESSION  =0 时跳过 D 段的外挂回归（变异跑用它省时间，默认 1）
  YWBF_OTA_TOOLS_DIR   回归脚本所在目录（默认 /mnt/us/ywbf_dev/tools）

七条硬纪律（本脚本自己也在守）：
  1. 只写 tools/ 下的验收脚本，绝不改实现代码；断言与实现不符时**提申请**，不自己改实现。
  2. 变异只用副本：YWBF_PLUGIN_DIR 指向 /mnt/us/ywbf_dev 下的副本，跑完删副本。
  3. 新断言必须先证明有牙：先在没实现的源码上跑出「预期红 N 条」，落地后转绿，
     再变异（改回去）确认还能红。变异分「逻辑写错」与「接线断了」两种。
  4. 断言「某物不存在」时同时断言对照组存在（否则空扫描永远绿）。
  5. 不用静态字符串扫描当主要手段：优先 stub 掉 HttpClient 的 get/post/request，
     捕获真实请求 URL 与 body，检查产物。静态扫描只做辅助，且必须带对照组。
  6. Config:set 是同步落盘的：开局钉配置基线；临时改配置的区段用 pcall 包住，
     **还原动作放在 pcall 外面**。
  7. 连跑两次再报数字（cache_enabled 之类会造「只在首次通过」的假绿）。
--]==]

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR")
    or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"
local TEST_DIR = os.getenv("YWBF_TEST_DIR") or "/mnt/us/ywbf_dev/ota_data"
local TOOLS_DIR = os.getenv("YWBF_OTA_TOOLS_DIR") or "/mnt/us/ywbf_dev/tools"
local TESTS_DIR = "/mnt/us/ywbf_dev/tests"
local DO_REGRESSION = (os.getenv("YWBF_OTA_REGRESSION") ~= "0")

-- 行缓冲：否则 os.exit(1) 会把还没刷新的 FAIL 行一起吞掉。
io.stdout:setvbuf("line")

-- ---------- 清场（只允许在 ywbf_dev 内动手） ----------
local function under_dev(p)
    return type(p) == "string" and p:find("/mnt/us/ywbf_dev", 1, true) == 1 and #p > 20
end
if under_dev(TEST_DIR) then
    os.execute("rm -rf '" .. TEST_DIR .. "'")
    os.execute("mkdir -p '" .. TEST_DIR .. "'")
end
-- 变异轮/上一轮留下的逃逸探针：不清掉会让「没有逃逸」永远红在一份陈旧文件上。
do
    local PROBES = { "pwned_ota_probe.txt", "escape_target" }
    for _i, n in ipairs(PROBES) do
        os.execute("rm -rf '/mnt/us/ywbf_dev/" .. n .. "'")
    end
end

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

-- ================= 断言骨架 =================
local TOTAL, PASSED, FAILED, SKIPPED, EXEMPT = 0, 0, 0, 0, 0
local FAILED_NAMES = {}
local function ok(cond, name, extra)
    TOTAL = TOTAL + 1
    if cond then
        PASSED = PASSED + 1
        print("  PASS  " .. name)
    else
        FAILED = FAILED + 1
        FAILED_NAMES[#FAILED_NAMES + 1] = name
        print("  FAIL  " .. name .. (extra and (" -> " .. tostring(extra)) or ""))
    end
end
local function skip(name, why)
    SKIPPED = SKIPPED + 1
    print("  SKIP  " .. name .. " -> " .. tostring(why))
end
local function note(name, why)
    print("  NOTE  " .. name .. " -> " .. tostring(why))
end
local function exempt(name, why)
    EXEMPT = EXEMPT + 1
    print("  EXEMPT  " .. name .. " -> " .. tostring(why))
end
local function section(t)
    print("")
    print("=== " .. t .. " ===")
end
local function has(s, sub)
    return type(s) == "string" and type(sub) == "string" and sub ~= ""
        and s:find(sub, 1, true) ~= nil
end
local function hasNot(s, sub)
    return type(s) == "string" and not has(s, sub)
end
local function readFile(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*all")
    f:close()
    return s
end
local function writeFile(p, s)
    local f = io.open(p, "wb")
    if not f then return false end
    f:write(s)
    f:close()
    return true
end
local function ensureDir(p)
    if type(p) ~= "string" or p == "" then return false end
    os.execute("mkdir -p '" .. p .. "'")
    local probe = p .. "/.ywbf_ota_probe"
    local f = io.open(probe, "w")
    if not f then return false end
    f:write("")
    f:close()
    os.remove(probe)
    return true
end
local function md5_of(path)
    local f = io.popen("md5sum '" .. tostring(path) .. "' 2>/dev/null")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return type(s) == "string" and s:match("^(%x+)") or nil
end
-- 逐行扫源码并正确跳过注释（行注释 + `--[[ ... ]]` 长注释）。
--
-- **为什么必须自己维护长注释状态**：只认"行首是 --"会把长注释**内部的行**当成代码。
-- 本次就误报了一次：ota.lua 第 15 行是长注释里写的纪律说明「不许自己 os.execute("wget …")」，
-- 被当成"代码里裸调 wget"。误报比漏报更伤信任，所以块注释的开合必须显式推进。
--
-- （这段说明故意写成行注释而不是长注释：长注释正文里一旦出现闭合方括号，
--   注释会在那儿提前结束，剩下的正文就变成代码了。）
local function codeLines(src)
    local out, in_block = {}, false
    for line in (tostring(src) .. "\n"):gmatch("([^\n]*)\n") do
        local trimmed = line:gsub("^%s+", "")
        local is_comment = in_block or (trimmed:sub(1, 2) == "--")
        out[#out + 1] = { text = line, code = (not is_comment) }
        if in_block then
            if line:find("%]%=?%=?%]") then in_block = false end
        else
            local _op, ope = line:find("%-%-%[%=?%=?%[")
            if ope and not line:sub(ope + 1):find("%]%=?%=?%]") then in_block = true end
        end
    end
    return out
end
local function isDir(p)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.attributes then
        return lfs.attributes(p, "mode") == "directory"
    end
    return false
end
local function listFiles(dir)
    -- 递归列相对路径（用于「逃逸文件没有真的落在那」这类判定）
    local out = {}
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return out end
    -- 目录不存在时返回空表，不许抛：`lfs.dir` 遇到不存在的路径会直接抛异常，
    -- 而"逃逸目标目录根本不存在"正是我们**期望**的结果——把它炸成区段级异常，
    -- 会让后面 B3⑰-B3⑳ 全部变成"没跑到"，看着像实现有问题，其实是扫描器不健壮。
    -- （这条就是这么踩到的：B3⑯ 之后整段抛异常，TOTAL 少掉 8 条。）
    if type(dir) ~= "string" or dir == "" then return out end
    if type(lfs.attributes) ~= "function" then return out end
    if lfs.attributes(dir, "mode") ~= "directory" then return out end
    local function walk(d, prefix)
        for f in lfs.dir(d) do
            if f ~= "." and f ~= ".." then
                local full = d .. "/" .. f
                local attr = lfs.attributes(full)
                if attr and attr.mode == "directory" then
                    walk(full, prefix .. f .. "/")
                elseif attr and attr.mode == "file" then
                    out[#out + 1] = prefix .. f
                end
            end
        end
    end
    walk(dir, "")
    table.sort(out)
    return out
end
-- 路径规范化：把 "a/../b" 收成 "b"，用于**精确比较**。
-- 「字符串以 dir.."/" 开头」是假绿（dir.."/../../x" 照样以它开头），必须规范化后比。
local function normalize(p)
    if type(p) ~= "string" then return nil end
    local parts = {}
    for part in p:gmatch("[^/]+") do
        if part == "." then
            -- skip
        elseif part == ".." then
            parts[#parts] = nil
        else
            parts[#parts + 1] = part
        end
    end
    return "/" .. table.concat(parts, "/")
end

-- ================= 基础桩：gettext / logger / ffi/util =================
package.loaded["gettext"] = setmetatable({}, { __call = function(_s, s) return s end })
package.loaded["logger"] = {
    info = function() end, warn = function() end,
    dbg = function() end, err = function() end,
    levels = { dbg = 1, info = 2, warn = 3, err = 4 },
}
do
    local function T(s, ...)
        local args = { ... }
        return (tostring(s):gsub("%%(%d)", function(d)
            return tostring(args[tonumber(d)] or "")
        end))
    end
    local okfu, fu = pcall(require, "ffi/util")
    if not (okfu and type(fu) == "table" and type(fu.template) == "function") then
        package.loaded["ffi/util"] = { template = T }
    end
end

-- ================= KOReader UI 桩（UIManager 维护**真实栈**） =================
-- 为什么要真栈：本轮要验「点检查更新时不许在已有对话框之上再叠一层」。
-- 把 UIManager 桩成空操作（很多老脚本就是这么干的）根本测不出叠层，
-- 谁都能靠"没崩"混过去。所以这里 show 入栈、close 出栈，并记录栈深峰值。
local UI_STACK = {}
local UI_PEAK = 0
local UI_SHOWN = {}
-- 口径二：真机上 `InfoMessage{timeout=1}` 这种瞬时提示 1 秒后自己关掉，
-- 我的桩没有时钟，它会在模型里一直挂着。所以另记一个"只数非常驻对话框"的峰值，
-- 两个口径一起报，避免"桩没实现定时器"被当成"实现叠了对话框"。
local UI_PEAK_SOLID = 0
-- show / close 的**先后顺序**：C13 要验"结果弹窗 show 之前，进度提示已经被 close"，
-- 光看最终栈看不出顺序（都关干净了栈就是空的）。所以这里另记一条事件流。
local UI_EVENTS = {}
local function uiReset()
    for _i = 1, #UI_STACK do UI_STACK[_i] = nil end
    UI_PEAK = 0
    UI_PEAK_SOLID = 0
    for _i = 1, #UI_SHOWN do UI_SHOWN[_i] = nil end
    for _i = 1, #UI_EVENTS do UI_EVENTS[_i] = nil end
end
local function uiShow(_s, w, _rt)
    if type(w) == "table" then
        UI_STACK[#UI_STACK + 1] = w
        UI_SHOWN[#UI_SHOWN + 1] = w
        UI_EVENTS[#UI_EVENTS + 1] = { op = "show", w = w }
        if #UI_STACK > UI_PEAK then UI_PEAK = #UI_STACK end
        local solid = 0
        for _i, x in ipairs(UI_STACK) do
            if type(x) == "table" and x.timeout == nil then solid = solid + 1 end
        end
        if solid > UI_PEAK_SOLID then UI_PEAK_SOLID = solid end
        if type(w.onShow) == "function" then pcall(w.onShow, w) end
    end
end
local function uiClose(_s, w)
    if type(w) == "table" then
        UI_EVENTS[#UI_EVENTS + 1] = { op = "close", w = w }
        for _i = #UI_STACK, 1, -1 do
            if UI_STACK[_i] == w then
                table.remove(UI_STACK, _i)
                break
            end
        end
    else
        UI_EVENTS[#UI_EVENTS + 1] = { op = "close", w = UI_STACK[#UI_STACK] }
        UI_STACK[#UI_STACK] = nil  -- 无参 close：关掉栈顶
    end
end
package.loaded["ui/uimanager"] = {
    show = uiShow,
    close = uiClose,
    scheduleIn = function(_s, _n, fn) if type(fn) == "function" then return fn() end end,
    nextTick = function(_s, fn) if type(fn) == "function" then return fn() end end,
    quit = function() end,
    setDirty = function() end,
    refresh = function() end,
}
package.loaded["ui/widget/infomessage"] = { new = function(_s, t) return t or {} end }
package.loaded["ui/widget/confirmbox"] = {
    new = function(_s, t)
        t = t or {}
        function t:onShow() end
        function t:onClose() end
        return t
    end,
}
package.loaded["ui/widget/inputdialog"] = {
    new = function(_s, t)
        t = t or {}
        function t:getInputText() return self.input or "" end
        function t:onShowKeyboard() end
        function t:onClose() end
        return t
    end,
}
package.loaded["ui/widget/buttondialog"] = {
    new = function(_s, t)
        t = t or {}
        function t:onShow() end
        function t:onClose() end
        return t
    end,
}
package.loaded["ui/widget/buttondialogtitle"] = package.loaded["ui/widget/buttondialog"]
package.loaded["ui/widget/textviewer"] = {
    new = function(_s, t)
        t = t or {}
        function t:onShow() end
        function t:onClose() end
        return t
    end,
}
package.loaded["ui/widget/textboxwidget"] = { new = function(_s, t) return t or {} end }
package.loaded["ui/widget/scrolltextwidget"] = { new = function(_s, t) return t or {} end }
package.loaded["ui/widget/multiinputdialog"] = package.loaded["ui/widget/inputdialog"]
package.loaded["ui/widget/menu"] = { new = function(_s, t) return t or {} end }
package.loaded["ui/widget/notification"] = {
    SOURCE_ALWAYS_SHOW = 1,
    notify = function() end,
}
package.loaded["ui/trapper"] = {
    wrap = function(_s, fn) return fn() end,
    info = function() end,
    isWrapped = function() return false end,
    clear = function() end,
}
package.loaded["device"] = { screen = nil }
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/size"] = { padding = { large = 1 }, margin = { small = 1 } }
package.loaded["ui/rendertext"] = { sizeUtf8Text = function() return { x = 0 } end }
package.loaded["ui/geometry"] = { x = 0, y = 0, w = 600, h = 800 }
package.loaded["dispatcher"] = { registerAction = function() end }
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(_s, t) return t or {} end,
    new = function(_s, t) return t or {} end,
}
package.loaded["ui/widget/container/inputcontainer"] = {
    extend = function(_s, t) return t or {} end,
    new = function(_s, t) return t or {} end,
}
package.loaded["ui/widget/container/framecontainer"] = {
    extend = function(_s, t) return t or {} end,
    new = function(_s, t) return t or {} end,
}
package.loaded["ui/widget/widget"] = {
    extend = function(_s, t) return t or {} end,
    new = function(_s, t) return t or {} end,
}
package.loaded["ui/widget/verticalgroup"] = { new = function(_s, t) return t or {} end }
package.loaded["ui/widget/horizontalgroup"] = { new = function(_s, t) return t or {} end }
package.loaded["ui/widget/linewidget"] = { new = function(_s, t) return t or {} end }
package.loaded["ui/widget/closebutton"] = { new = function(_s, t) return t or {} end }
package.loaded["ui/widget/button"] = { new = function(_s, t) return t or {} end }

-- ================= 网络桩 =================
-- 先取**真的** HttpClient：白名单与 isHostAllowed 必须是实现侧的真实行为，
-- 不能用我自己写的假白名单（那样"host 在白名单里"就是自说自话）。
local RealHttp = require("ywbf/httpclient")

local NET = { calls = {}, responder = nil }
local function netCall(method, url, headers, body)
    NET.calls[#NET.calls + 1] = {
        method = method, url = tostring(url), headers = headers, body = body,
    }
    -- 真实 HttpClient 的第一道门：host 不在白名单就直接返回 err，绝不出网。
    -- 桩必须复刻这道门，否则"每一跳都重新校验"测的是我自己的桩而不是实现。
    local okh, allowed = pcall(RealHttp.isHostAllowed, url)
    if not (okh and allowed) then
        return nil, nil, nil, "host not allowed: " .. tostring(url)
    end
    if type(NET.responder) ~= "function" then
        return "", 200, "OK", nil, {}
    end
    local b, c, s, e, h = NET.responder(tostring(url), method, headers, body)
    return b, c, s, e, h
end

-- 说明：真实 HttpClient 目前只返回 (body, code, status, err)，**不带响应头**。
-- 跟随 302 必须有 Location，所以实现侧要么给 get/post 补第 5 个返回值 headers，
-- 要么新增显式 API。本桩两种通道都给（第 5 返回值 + HttpClient.last_headers），
-- 若实现两种都不认，"开 opt-in 跟随成功"那条会红——那是**真实缺口**，不是放宽断言的理由。
-- 注意：`local X = { ... }` 的表构造式里引用 X 自身会取到**全局**（Lua 的 local 作用域
-- 从声明语句之后才开始），所以这里先声明空表再逐个挂成员。这个坑上一版踩过一次。
local HttpStub = {}
HttpStub.ALLOWED_HOSTS = RealHttp.ALLOWED_HOSTS
HttpStub.isHostAllowed = RealHttp.isHostAllowed
HttpStub.setTimeout = function() end
HttpStub.last_headers = nil
-- 签名必须跟真实模块**逐位对齐**：HttpClient 的方法是**点号定义**的
-- （`function HttpClient.post(url, headers, body, timeout, opts)`，没有 self）。
-- 我第一版写成了冒号风格（前面多一个 `_s`），结果所有 URL 都取到了 headers 表，
-- B2 的"实际请求 URL"全变成 `table: 0x…`。桩写错比不写桩更危险——它会安静地全绿。
function HttpStub.get(url, headers, timeout, opts)
    local b, c, s, e, h = netCall("GET", url, headers, nil)
    HttpStub.last_headers = h
    return b, c, s, e, h
end
function HttpStub.post(url, headers, body, timeout, opts)
    local b, c, s, e, h = netCall("POST", url, headers, body)
    HttpStub.last_headers = h
    return b, c, s, e, h
end
-- 真实模块里 request 是 local，对外不可见；签名按内部那一份对齐
function HttpStub.request(method, url, headers, body, timeout, opts)
    local b, c, s, e, h = netCall(method, url, headers, body)
    HttpStub.last_headers = h
    return b, c, s, e, h
end
package.loaded["ywbf/httpclient"] = HttpStub
package.loaded["httpclient"] = HttpStub

local function netReset(responder)
    NET.calls = {}
    NET.responder = responder
end
local function netUrls()
    local t = {}
    for _i, c in ipairs(NET.calls) do t[#t + 1] = c.url end
    return t
end
-- 安全反例的核心判据：被真正发出去的 URL 里，不许出现白名单外的 host。
-- 「实现自己先校验再发」和「发下去被 HttpClient 挡住」在这条下面不等价：
-- 后者已经把请求递到门口了，白名单是这轮新开的出网面，必须钉在发之前。
local function netBadUrls()
    local bad = {}
    for _i, c in ipairs(NET.calls) do
        local okh, allowed = pcall(RealHttp.isHostAllowed, c.url)
        if not (okh and allowed) then bad[#bad + 1] = c.url end
    end
    return bad
end
local function netPlainHttpUrls()
    local bad = {}
    for _i, c in ipairs(NET.calls) do
        if c.url:sub(1, 7) == "http://" then bad[#bad + 1] = c.url end
    end
    return bad
end

-- ================= 模块加载 =================
local Config = require("ywbf/config")
local json = require("json")
local Util = require("ywbf/util")
local Ota = nil
local ota_err = nil
do
    local ok1, m1 = pcall(require, "ywbf/ota")
    if ok1 and type(m1) == "table" then
        Ota = m1
    else
        local ok2, m2 = pcall(require, "ota")
        if ok2 and type(m2) == "table" then
            Ota = m2
        else
            ota_err = tostring(m1)
        end
    end
end
local OTA_OK = (type(Ota) == "table")
local function otaMissing(name)
    ok(false, name .. "（模块未落地）", ota_err or "ywbf/ota.lua 不存在或加载失败")
end

Config:init(TEST_DIR)
-- 配置基线：Config:set 是**同步落盘**的，中途抛异常会把下一个进程毒死。
-- 开局钉下原文，全程（含异常路径）结束后整体还原。
local SETTINGS_RAW = nil
do
    local f = io.open(Config.paths.settings, "rb")
    if f then SETTINGS_RAW = f:read("*all"); f:close() end
end
local function restoreSettings()
    if not SETTINGS_RAW then return end
    local f = io.open(Config.paths.settings, "wb")
    if f then f:write(SETTINGS_RAW); f:close() end
end

local Crypto = require("ywbf/crypto")
local DeepSeek = require("ywbf/deepseek")
do
    local okc = Crypto:init()
    if okc then pcall(function() DeepSeek:setApiKey("qa-ota-key") end) end
    if not DeepSeek:hasApiKey() then
        DeepSeek.getApiKey = function() return "qa-ota-key" end
    end
end

local VERSION_NOW = Config.VERSION  -- 可能是 nil（还没落地）

-- ======================================================================
-- A. 版本单一来源
-- ======================================================================
local function secA()
    section("A. 版本单一来源（Config.VERSION / _meta.lua）")

    ok(type(VERSION_NOW) == "string" and VERSION_NOW ~= "",
        "A1：Config.VERSION 存在且是非空字符串", VERSION_NOW)
    ok(type(VERSION_NOW) == "string" and VERSION_NOW:match("^%d+%.%d+%.%d+$") ~= nil,
        "A2：Config.VERSION 形如 主.次.修订（%d+.%d+.%d+）", VERSION_NOW)

    local meta_src = readFile(PLUGIN_DIR .. "/_meta.lua")
    ok(type(meta_src) == "string" and #meta_src > 20,
        "A3：（前置）读得到 _meta.lua 全文（读不到，下面两条都是空扫描假绿）",
        meta_src and #meta_src or "<nil>")

    -- 对照组：扫得到插件名，证明确实扫的是这个文件、扫描器没坏。
    ok(has(meta_src, "远望书友"),
        "A4：（对照）_meta.lua 里含插件名「远望书友」（证明 A5 不是空扫描）",
        meta_src and Util.utf8sub(meta_src, 60) or nil)

    if type(VERSION_NOW) == "string" and VERSION_NOW ~= "" then
        ok(hasNot(meta_src, VERSION_NOW),
            "A5：_meta.lua 全文**不含**版本号硬编码（版本只能有一个来源）",
            has(meta_src, VERSION_NOW) and ("命中：" .. VERSION_NOW) or nil)
    else
        ok(false, "A5：_meta.lua 全文不含版本号硬编码", "Config.VERSION 还没有值，无从比对")
    end
    -- _meta.lua 不许 require config（它由 KOReader 独立加载时 require 子模块会出事）
    local bad_req = nil
    do
        for m in tostring(meta_src):gmatch('require%s*%(?%s*["\']([^"\']+)["\']') do
            if m == "config" or m == "ywbf/config" then bad_req = m end
        end
    end
    ok(bad_req == nil,
        "A6：_meta.lua 里**没有** require config（KOReader 独立加载 _meta.lua，不许牵子模块）",
        bad_req)
    ok(has(meta_src, 'require("gettext")'),
        "A7：（对照）同一份扫描能在 _meta.lua 里命中 require(\"gettext\")（证明 A6 的扫描器是好的）",
        nil)

    -- 加严项（QA 自己加的，若工程师有异议需说明理由）：整个插件目录里，
    -- 版本字面量只允许出现在 ywbf/config.lua 一处。多一处就迟早不同步。
    do
        local hits, others = {}, {}
        local files = {}
        local all = nil
        do
            local f = io.popen("cd '" .. PLUGIN_DIR .. "' && find . -name '*.lua' | sort")
            if f then all = f:read("*a"); f:close() end
        end
        for line in tostring(all):gmatch("([^\n]+)") do
            files[#files + 1] = line:gsub("^%./", "")
        end
        if type(VERSION_NOW) ~= "string" or VERSION_NOW == "" then
            ok(false, "A8：版本字面量只出现在 ywbf/config.lua", "Config.VERSION 无值，无法扫")
        else
            for _i, rel in ipairs(files) do
                local src = readFile(PLUGIN_DIR .. "/" .. rel) or ""
                local hit = false
                for _j, ln in ipairs(codeLines(src)) do
                    if ln.code and has(ln.text, VERSION_NOW) then hit = true; break end
                end
                if hit then
                    hits[#hits + 1] = rel
                    if rel ~= "ywbf/config.lua" then others[#others + 1] = rel end
                end
            end
            ok(#hits >= 1,
                "A8：（对照）扫描确实在 ywbf/config.lua 里命中了版本字面量（否则 A9 是空扫描）",
                table.concat(hits, ","))
            ok(#others == 0,
                "A9：除 ywbf/config.lua 外没有第二个文件在**代码里**抄了版本字面量"
                .. "（多一处就迟早不同步；注释里提到不算）",
                #others > 0 and table.concat(others, ",") or nil)
        end
    end
end

-- ======================================================================
-- B1. 纯逻辑：normalizeVersion / compareVersions
-- ======================================================================
local function secB1()
    section("B1. 纯逻辑：normalizeVersion / compareVersions")

    if not OTA_OK then
        otaMissing("B1：ywbf/ota.lua 可加载")
        skip("B1①-B1⑮ 版本比较", "模块未落地")
        return
    end

    ok(type(Ota.normalizeVersion) == "function",
        "B1：（前置）Ota:normalizeVersion 存在", type(Ota.normalizeVersion))
    ok(type(Ota.compareVersions) == "function",
        "B1：（前置）Ota:compareVersions 存在", type(Ota.compareVersions))
    if type(Ota.normalizeVersion) ~= "function" or type(Ota.compareVersions) ~= "function" then
        skip("B1①-B1⑮ 版本比较", "接口缺失")
        return
    end

    local function eqv(got, want)
        if type(want) ~= "table" then return got == nil end
        if type(got) ~= "table" then return false end
        return got[1] == want[1] and got[2] == want[2] and got[3] == want[3]
    end
    local function shown(v)
        if v == nil then return "nil" end
        if type(v) ~= "table" then return "<" .. type(v) .. ">" .. tostring(v) end
        return string.format("{%s,%s,%s}", tostring(v[1]), tostring(v[2]), tostring(v[3]))
    end
    -- 四段版本号的打印：`shown` 只看前三段，看不出"第四段被砍了"。
    local function shown4(v)
        if v == nil then return "nil" end
        if type(v) ~= "table" then return "<" .. type(v) .. ">" .. tostring(v) end
        local parts, n = {}, 0
        for _i = 1, 6 do
            if v[_i] ~= nil then n = _i; parts[_i] = tostring(v[_i]) end
        end
        return string.format("{%s}(%d 段)", table.concat(parts, ","), n)
    end

    -- normalizeVersion
    do
        local cases = {
            { inp = "v0.2",      want = { 0, 2, 0 }, why = "v 前缀 + 缺修订段补 0" },
            { inp = "1.10.0",    want = { 1, 10, 0 }, why = "两位数的次版本号" },
            { inp = "1.2",       want = { 1, 2, 0 },  why = "缺修订段补 0" },
            { inp = "v1.2.3",    want = { 1, 2, 3 },  why = "v 前缀三段" },
            { inp = "  1.2.3  ", want = { 1, 2, 3 },  why = "前后空格要 trim" },
            { inp = "",          want = nil,          why = "空串" },
            { inp = nil,         want = nil,          why = "nil" },
            { inp = "abc",       want = nil,          why = "纯字母" },
            { inp = "0.x.1",     want = nil,          why = "中间段非数字" },
            { inp = "1..2",      want = nil,          why = "空段" },
        }
        for _i, c in ipairs(cases) do
            local got = Ota:normalizeVersion(c.inp)
            ok(eqv(got, c.want),
                string.format("B1①-%d：normalizeVersion(%q) == %s（%s）",
                    _i, tostring(c.inp), shown(c.want), c.why),
                "got=" .. shown(got))
        end

        -- 四段：合法输入必须**保留四段**。这条是 B1 那 5 条修法的**反向护栏**——
        -- 把「非法 -> nil」修严了，最容易顺手把合法的四段版本号一起砍成 nil，
        -- 那是另一种过约束（0.2.0.1 这种内部版本就没人认得了）。
        local g4 = Ota:normalizeVersion("1.2.3.4")
        ok(type(g4) == "table" and g4[1] == 1 and g4[2] == 2 and g4[3] == 3 and g4[4] == 4
            and g4[5] == nil,
            "B1②：（对照）normalizeVersion(\"1.2.3.4\") 非 nil 且**保留 4 段** {1,2,3,4}"
            .. "（修 B1 那 5 条时别把合法四段一起砍了）",
            "got=" .. shown4(g4))
        -- v0.2 是**正式断言**（在 B1①-1 里），不是 NOTE：契约定死了 v 前缀 + 补 0 -> {0,2,0}。
        -- 上一版我在 NOTE 里写过 {0,2,nil}，那是旧版残留，以这里为准。
        ok(eqv(Ota:normalizeVersion("v0.2"), { 0, 2, 0 }),
            "B1②'：normalizeVersion(\"v0.2\") == {0,2,0}（契约定死：v 前缀吃掉、缺段补 0）",
            "got=" .. shown4(Ota:normalizeVersion("v0.2")))
    end

    -- compareVersions
    do
        local cases = {
            { a = "0.10.0", b = "0.9.0",  want = 1,  why = "**反例**：字符串比较会判成 0.10 < 0.9" },
            { a = "0.9.0",  b = "0.10.0", want = -1, why = "反向同样不许串比" },
            { a = "0.2.0",  b = "0.2.0",  want = 0,  why = "相等" },
            { a = "1.0",    b = "1.0.1",  want = -1, why = "缺段按 0 参与比较" },
            { a = "1.0.1",  b = "1.0",    want = 1,  why = "反向" },
            { a = "v2.0.0", b = "1.9.9",  want = 1,  why = "带 v 前缀" },
            { a = "abc",    b = "1.0.0",  want = nil, why = "非法输入 -> nil" },
            { a = "1.0.0",  b = "xyz",    want = nil, why = "非法输入 -> nil（右侧）" },
            { a = "",       b = "",       want = nil, why = "两侧都非法" },
            -- 「非法输入返回 nil」这条的真正后果在这里：normalizeVersion 若对非法串
            -- 返回一个半成品表，compareVersions 就会拿它比出一个看似合理的结果。
            { a = "0.x.1",  b = "1.0.0",  want = nil, why = "中间段非数字，整次比较必须判非法" },
            { a = "1..2",   b = "1.0.0",  want = nil, why = "空段，整次比较必须判非法" },
            { a = "1.0.0",  b = "0.x.1",  want = nil, why = "非法在右侧同样不许比" },
        }
        for _i, c in ipairs(cases) do
            local got = Ota:compareVersions(c.a, c.b)
            ok(got == c.want,
                string.format("B1③-%d：compareVersions(%q, %q) == %s（%s）",
                    _i, tostring(c.a), tostring(c.b), tostring(c.want), c.why),
                "got=" .. tostring(got))
        end
    end
end

-- ======================================================================
-- B2. 网络行为：latestRelease / checkForUpdate / download 重定向
-- ======================================================================
local function secB2()
    section("B2. 网络行为（HttpClient 全程打桩，不打真网）")

    if not OTA_OK then
        otaMissing("B2：ywbf/ota.lua 可加载")
        skip("B2 全部网络用例", "模块未落地")
        return
    end

    ok(type(Ota.REPO) == "string" and Ota.REPO ~= "",
        "B2：（前置）Ota.REPO 存在", Ota.REPO and tostring(Ota.REPO) or nil)

    -- ---- 白名单：这轮新开的出网面 ----
    ok(type(RealHttp.ALLOWED_HOSTS) == "table"
        and RealHttp.ALLOWED_HOSTS["api.deepseek.com"] == true,
        "B2①：（对照）白名单里 api.deepseek.com **仍在**（证明白名单没被整个换掉）",
        nil)
    ok(type(RealHttp.ALLOWED_HOSTS) == "table"
        and RealHttp.ALLOWED_HOSTS["api.github.com"] == true,
        "B2②：白名单里新增了 api.github.com（OTA 查询的 host 必须在白名单内）",
        nil)
    ok(RealHttp.isHostAllowed("http://api.github.com/repos/x/releases/latest") == false,
        "B2③：http:// 明文出站仍被拒（白名单校验没被改成「只看 host 不管协议」）",
        nil)

    -- 挑出可用于重定向链的合法 host（优先 github 系），避免因为实现只放了
    -- 一个 host 就把"合法链"误判成"非法"的假红。
    local GOOD = {}
    do
        local pref, rest = {}, {}
        for h, v in pairs(type(RealHttp.ALLOWED_HOSTS) == "table" and RealHttp.ALLOWED_HOSTS or {}) do
            if v == true and type(h) == "string" then
                if h:find("github", 1, true) then pref[#pref + 1] = h else rest[#rest + 1] = h end
            end
        end
        table.sort(pref)
        table.sort(rest)
        for _i, h in ipairs(pref) do GOOD[#GOOD + 1] = h end
        for _i, h in ipairs(rest) do GOOD[#GOOD + 1] = h end
    end
    local function goodUrl(i)
        if #GOOD == 0 then return nil end
        local h = GOOD[((i - 1) % #GOOD) + 1]
        return "https://" .. h .. "/dl/hop" .. tostring(i) .. ".zip"
    end
    note("B2 可用白名单 host", table.concat(GOOD, ",") .. "（重定向链从这里取，避免假红）")

    -- ---- latestRelease：正常解析 ----
    if type(Ota.latestRelease) ~= "function" then
        otaMissing("B2④：Ota:latestRelease 存在")
    else
        local PAYLOAD = [[{"tag_name":"v9.9.9","name":"远望书友 v9.9.9",
            "zipball_url":"https://api.github.com/repos/]] .. tostring(Ota.REPO)
            .. [[/zipball/v9.9.9",
            "html_url":"https://github.com/]] .. tostring(Ota.REPO) .. [[/releases/tag/v9.9.9",
            "body":"本次更新说明"}]]
        netReset(function() return PAYLOAD, 200, "OK", nil, {} end)
        local rel, err = Ota:latestRelease()

        ok(type(rel) == "table", "B2④：latestRelease 正常返回 table", err or tostring(rel))
        if type(rel) == "table" then
            ok(rel.tag == "v9.9.9", "B2⑤：解析出 tag", rel.tag)
            ok(type(rel.zipball_url) == "string" and has(rel.zipball_url, "zipball"),
                "B2⑥：解析出 zipball_url（下载地址）", rel.zipball_url)
            ok(type(rel.html_url) == "string" and has(rel.html_url, "github.com"),
                "B2⑦：解析出 html_url（发布页）", rel.html_url)
            ok(rel.notes == "本次更新说明", "B2⑧：解析出 notes（更新说明）", rel.notes)
            ok(type(rel.name) == "string" and rel.name ~= "",
                "B2⑨：解析出 name", rel.name)
        else
            skip("B2⑤-B2⑨ 字段解析", "latestRelease 没返回 table")
        end

        -- URL 断言：必须是 GitHub latest 接口，且 host 在真实白名单里
        do
            local want = "https://api.github.com/repos/" .. tostring(Ota.REPO) .. "/releases/latest"
            local got = netUrls()[1]
            ok(got == want,
                "B2⑩：【行为】实际请求的 URL 就是 GitHub latest 接口（不是照着源码猜的）",
                "got=" .. tostring(got) .. " want=" .. want)
            ok(type(got) == "string" and RealHttp.isHostAllowed(got) == true,
                "B2⑪：【行为】请求 URL 的 host 通过了**真实** isHostAllowed",
                tostring(got))
        end

        -- 四种失败路径
        do
            netReset(function() return "500 Internal Error", 500, "Internal Server Error", nil, {} end)
            local r1, e1 = Ota:latestRelease()
            ok(r1 == nil and type(e1) == "string" and e1 ~= "",
                "B2⑫：HTTP 非 200 -> nil + err", "r=" .. tostring(r1) .. " err=" .. tostring(e1))

            netReset(function() return "{这不是合法 JSON", 200, "OK", nil, {} end)
            local r2, e2 = Ota:latestRelease()
            ok(r2 == nil and type(e2) == "string" and e2 ~= "",
                "B2⑬：JSON 非法 -> nil + err", "r=" .. tostring(r2) .. " err=" .. tostring(e2))

            netReset(function() return nil, nil, nil, "simulated network error" end)
            local r3, e3 = Ota:latestRelease()
            ok(r3 == nil and type(e3) == "string" and e3 ~= "",
                "B2⑭：网络异常 -> nil + err", "r=" .. tostring(r3) .. " err=" .. tostring(e3))

            netReset(function() return "", 200, "OK", nil, {} end)
            local r4, e4 = Ota:latestRelease()
            ok(r4 == nil or type(r4) ~= "table" or type(r4.tag) ~= "string",
                "B2⑮：空响应体不产生一个「看起来正常」的 release（空表也算漏）",
                "r=" .. type(r4) .. " err=" .. tostring(e4))
        end
    end

    -- ---- checkForUpdate ----
    if type(Ota.checkForUpdate) ~= "function" then
        otaMissing("B2⑯：Ota:checkForUpdate 存在")
    else
        local function withTag(tag)
            netReset(function()
                return ([[{"tag_name":"%s","name":"n","zipball_url":"https://api.github.com/repos/%s/zipball/%s",
                    "html_url":"https://github.com/%s/releases/tag/%s","body":"notes"}]]):format(
                    tag, tostring(Ota.REPO), tag, tostring(Ota.REPO), tag), 200, "OK", nil, {}
            end)
        end
        local cur = type(VERSION_NOW) == "string" and VERSION_NOW or "0.0.0"

        withTag("99.0.0")
        local r_new, e_new = Ota:checkForUpdate()
        ok(type(r_new) == "table" and r_new.available == true,
            "B2⑯：远端更新 -> available == true",
            type(r_new) == "table" and tostring(r_new.available) or tostring(e_new))
        if type(r_new) == "table" then
            ok(r_new.current == VERSION_NOW,
                "B2⑰：返回的 current 取自 Config.VERSION（不是另一处抄的）",
                "got=" .. tostring(r_new.current) .. " want=" .. tostring(VERSION_NOW))
            ok(type(r_new.latest) == "string" and r_new.latest ~= "",
                "B2⑱：返回 latest", r_new.latest)
            ok(type(r_new.url) == "string" and r_new.url ~= "", "B2⑲：返回 url", r_new.url)
            ok(type(r_new.html_url) == "string" and r_new.html_url ~= "",
                "B2⑳：返回 html_url", r_new.html_url)
        end

        withTag(cur)
        local r_eq, _ = Ota:checkForUpdate()
        ok(type(r_eq) == "table" and r_eq.available == false,
            "B2㉑：远端等于本地 -> available == false",
            type(r_eq) == "table" and tostring(r_eq.available) or "非 table")

        withTag("0.0.1")
        local r_old, _ = Ota:checkForUpdate()
        ok(type(r_old) == "table" and r_old.available == false,
            "B2㉒：远端更旧 -> available == false",
            type(r_old) == "table" and tostring(r_old.available) or "非 table")

        -- 失败路径：**不许静默说"有更新"**
        netReset(function() return nil, nil, nil, "simulated network error" end)
        local r_fail, e_fail = Ota:checkForUpdate()
        local no_false_update = (r_fail == nil)
            or (type(r_fail) == "table" and r_fail.available == false)
        ok(no_false_update and type(e_fail) == "string" and e_fail ~= "",
            "B2㉓：【强度反例】查询失败时 available 绝不为 true，且 err 非 nil",
            "r=" .. (type(r_fail) == "table" and tostring(r_fail.available) or tostring(r_fail))
                .. " err=" .. tostring(e_fail))

        netReset(function() return "boom", 500, "Server Error", nil, {} end)
        local r5, e5 = Ota:checkForUpdate()
        local ok5 = (r5 == nil) or (type(r5) == "table" and r5.available == false)
        ok(ok5 and type(e5) == "string" and e5 ~= "",
            "B2㉔：HTTP 500 时同样不许报「有更新」，且 err 非 nil",
            "r=" .. (type(r5) == "table" and tostring(r5.available) or tostring(r5))
                .. " err=" .. tostring(e5))
    end

    -- ---- download：302 重定向 ----
    if type(Ota.download) ~= "function" then
        otaMissing("B2㉕：Ota:download 存在")
        skip("B2㉕-B2㊱ 重定向用例", "接口缺失")
        return
    end

    local DL_DIR = TEST_DIR .. "/dl"
    ensureDir(DL_DIR)

    -- 二进制安全的载荷：zip 是二进制，文本模式写错一个字节就是坏包。
    -- 里面故意放 NUL 与 0xFF，专门抓"下载当文本处理"的实现。
    -- 开头必须是 PK\003\004（实现侧会校验 zip 魔数，不是这个头会直接判"不是 zip"）。
    local PAYLOAD = "PK\003\004" .. ("\9\8\7\6\5\4\3\2\1\0\255\254\253"):rep(300) .. "\0\255\1\2"
    local PAYLOAD_ZIP_MAGIC = true
    local function script(chain)
        -- chain: { [url] = { code=, location=, body=, err= } }
        netReset(function(url)
            local e = chain[url]
            if not e then return "", 404, "Not Found", nil, {} end
            local hdrs = {}
            if e.location then
                hdrs.location = e.location
                hdrs.Location = e.location
            end
            return e.body or "", e.code or 200, e.status or "OK", e.err, hdrs
        end)
    end
    local function failed(a) return a ~= true end

    -- 重定向相关的断言**不在这里判**：跟随逻辑写在真实 HttpClient 里，
    -- 而这一节把 HttpClient 整个桩掉了——桩返回什么就是什么，
    -- "每跳重新校验白名单"会变成我在桩里自己演一遍（演出来的绿是自说自话）。
    -- 那些用例全部移到 B2'（真实 HttpClient + 只假 ssl.https 那一句出网调用）。
    -- 这里只留一条桩模式下**判得动**的：非 2xx 必须失败并给原因。
    do
        local u1 = goodUrl(1)
        if not u1 then
            skip("B2㉕ HTTP 500", "白名单里没有可用 host")
        else
            script({ [u1] = { code = 500, body = "server error" } })
            local okd, a, b = pcall(Ota.download, Ota, u1, DL_DIR .. "/s6.zip")
            ok((not okd) or failed(a),
                "B2㉕：HTTP 500 -> download 失败并给 err（不许把错误页当更新包）",
                okd and ("got=" .. tostring(a) .. " err=" .. tostring(b)) or tostring(a))
        end
    end

    -- 对照组：同一套脚本化响应下，200 且是 zip 魔数开头时 download 必须成功。
    -- 没有这条，上一条可能只是"download 根本跑不通"。
    do
        local u1 = goodUrl(1)
        if not u1 then
            skip("B2㉖ HTTP 200 成功路径", "白名单里没有可用 host")
        else
            script({ [u1] = { body = PAYLOAD } })
            local dest = DL_DIR .. "/s_ok.zip"
            local okd, a, e = pcall(Ota.download, Ota, u1, dest)
            ok(okd and a == true,
                "B2㉖：（对照）200 + zip 魔数 -> download 成功（证明 B2㉕ 不是因为根本跑不通）",
                okd and tostring(e) or tostring(a))
            ok(readFile(dest) == PAYLOAD,
                "B2㉗：（对照）成功路径上落盘字节与包体逐字节一致",
                "got=" .. tostring(readFile(dest) and #(readFile(dest))) .. " want=" .. #PAYLOAD)
        end
    end

    -- 用例 6：非 200 且非 3xx -> 失败
    do
        local u1 = goodUrl(1)
        if not u1 then
            skip("B2㉝ HTTP 500", "白名单里没有可用 host")
        else
            script({ [u1] = { code = 500, body = "server error" } })
            local okd, a, b = pcall(Ota.download, Ota, u1, DL_DIR .. "/s6.zip")
            ok((not okd) or failed(a),
                "B2㉝：HTTP 500 -> download 失败并给 err",
                okd and ("got=" .. tostring(a) .. " err=" .. tostring(b)) or tostring(a))
        end
    end
end

-- ======================================================================
-- B2'. 重定向：走**真实 HttpClient** + 假 ssl.https 传输层
-- ======================================================================
-- 为什么非得再开这一段：上一节把 HttpClient 整个桩掉了，而实现的
-- 「默认不跟随 / opt-in 开启 / 每跳重新校验白名单 / 最多 3 跳 / 只认 https」
-- 五条全部写在 HttpClient 里。桩掉它之后那些用例测的是空气——我的桩返回什么
-- 就是什么，"每跳校验"变成我自己在桩里演一遍。
--
-- 所以这一段**只假 ssl.https 这一句真正出网的调用**，HttpClient 与 Ota 全用真源码：
-- 白名单、逐跳校验、跳数上限都是被测对象自己在跑，零网络、可离线重复。
local function secB2b()
    section("B2'. 重定向（真实 HttpClient + 假 ssl.https 传输层，不打真网）")

    local XNET = { calls = {}, responder = nil }
    package.loaded["ssl.https"] = {
        TIMEOUT = 60,
        request = function(payload)
            -- 自检（fail-fast）：URL 必须是**字符串**。
            -- 桩写错时（比如把 payload.headers 当 URL 递进来）它会被 tostring 成
            -- "table: 0x…"，后面每一条基于 URL 的断言都会莫名变红，而那种假红
            -- 极易被当成"实现有问题"去改实现。所以这里直接判"桩坏了"并退出，
            -- 不让它流到后面的断言里变成一堆看不懂的红。
            if type(payload.url) ~= "string" then
                io.stdout:write(string.format(
                    "FATAL: ssl.https 桩收到的 url 类型是 %s（%s）—— 是桩/调用方取错了字段，"
                    .. "不是实现的问题。修桩再跑。\n",
                    type(payload.url), tostring(payload.url)))
                io.stdout:flush()
                os.exit(9)
            end
            XNET.calls[#XNET.calls + 1] = {
                url = tostring(payload.url),
                method = payload.method,
                headers = payload.headers,
            }
            local body, code, hdrs, status = "", 200, {}, "OK"
            if type(XNET.responder) == "function" then
                local b, c, h, s = XNET.responder(tostring(payload.url), payload.method)
                if type(b) == "string" then body = b end
                if type(c) == "number" then code = c end
                if type(h) == "table" then hdrs = h end
                if type(s) == "string" then status = s end
            end
            -- 真走 ltn12 sink：不把 body 递回去，实现侧就拿不到包体
            if type(payload.sink) == "function" then
                if body ~= "" then pcall(payload.sink, body) end
                pcall(payload.sink, nil)
            end
            return 1, code, hdrs, status
        end,
    }
    package.loaded["ywbf/httpclient"] = nil
    package.loaded["httpclient"] = nil

    local H = nil
    do
        local okh, m = pcall(require, "ywbf/httpclient")
        if not (okh and type(m) == "table") then
            skip("B2' 全部用例", "真实 HttpClient 起不来：" .. tostring(m))
            package.loaded["ywbf/httpclient"] = HttpStub
            package.loaded["httpclient"] = HttpStub
            return
        end
        H = m
    end
    local OtaR = nil
    do
        package.loaded["ywbf/ota"] = nil
        local okr, m = pcall(require, "ywbf/ota")
        if okr and type(m) == "table" then OtaR = m end
        -- 清掉：C 段会重新 require，那时 HttpClient 已经换回桩
        package.loaded["ywbf/ota"] = nil
    end

    local function restore_stub_at_end()
        package.loaded["ywbf/httpclient"] = HttpStub
        package.loaded["httpclient"] = HttpStub
    end

    -- 载荷：zip 魔数开头 + 二进制脏字节（NUL / 0xFF），抓"下载当文本处理"
    local PAYLOAD = "PK\003\004" .. ("\9\8\7\6\5\4\3\2\1\0\255\254\253"):rep(300) .. "\0\255\1\2"

    ok(type(H.REDIRECT_HOSTS) == "table",
        "B2'-0：（前置）HttpClient.REDIRECT_HOSTS 存在（下载域单独一张表）", nil)
    local rhosts = {}
    do
        for h, v in pairs(type(H.REDIRECT_HOSTS) == "table" and H.REDIRECT_HOSTS or {}) do
            if v == true and type(h) == "string" then rhosts[#rhosts + 1] = h end
        end
        table.sort(rhosts)
    end
    note("B2' 逐跳放行域", table.concat(rhosts, ","))
    if #rhosts == 0 then
        skip("B2' 重定向矩阵", "REDIRECT_HOSTS 是空的，构造不出合法跳转链")
        restore_stub_at_end()
        return
    end

    local START = "https://api.github.com/repos/" .. tostring(Ota and Ota.REPO) .. "/zipball/v9"
    local function rd(i)
        return "https://" .. rhosts[((i - 1) % #rhosts) + 1] .. "/hop" .. tostring(i) .. ".zip"
    end
    local EVIL = "https://evil.example.com/steal.zip"
    local function chainOf(map)
        XNET.calls = {}
        XNET.responder = function(url)
            local e = map[url]
            if not e then return "", 404, {}, "Not Found" end
            local h = {}
            if e.location then h.location = e.location end
            return e.body or "", e.code or 200, h, e.status or "OK"
        end
    end
    local function xurls()
        local t = {}
        for _i, c in ipairs(XNET.calls) do t[#t + 1] = c.url end
        return t
    end
    local function xhas(sub)
        for _i, c in ipairs(XNET.calls) do
            if has(c.url, sub) then return true end
        end
        return false
    end
    local function xplain()
        local n = 0
        for _i, c in ipairs(XNET.calls) do
            if c.url:sub(1, 7) == "http://" then n = n + 1 end
        end
        return n
    end

    -- ① 默认不跟随
    do
        chainOf({ [START] = { code = 302, location = rd(1) }, [rd(1)] = { body = PAYLOAD } })
        local b, code, _st, err = H.get(START, {}, 30)
        ok(code == 302,
            "B2'-①：【强度反例】不开 opt-in 时 HttpClient 遇到 302 **不跟随**（原样返回 302）",
            "code=" .. tostring(code) .. " err=" .. tostring(err) .. " bodylen=" .. tostring(b and #b))
        ok(#XNET.calls == 1,
            "B2'-②：默认只发了 1 个请求（真没去追 Location）",
            "calls=" .. #XNET.calls .. " -> " .. table.concat(xurls(), " | "))
    end

    -- ② opt-in 且每跳合法 -> 跟到底
    do
        local map = { [rd(1)] = { code = 302, location = rd(2) }, [rd(2)] = { body = PAYLOAD } }
        map[START] = { code = 302, location = rd(1) }
        chainOf(map)
        local b, code, _st, err = H.get(START, {}, 30, { follow_redirects = true })
        ok(code == 200 and b == PAYLOAD,
            "B2'-③：开 opt-in 且每跳 host 合法 -> 跟到底并返回完整包体（" .. #PAYLOAD .. " 字节，含 NUL/0xFF）",
            "code=" .. tostring(code) .. " err=" .. tostring(err)
                .. " len=" .. tostring(b and #b))
        ok(#XNET.calls == 3,
            "B2'-④：（对照）确实走了 3 个请求（首跳 + 2 跳），不是一次拿到",
            table.concat(xurls(), " | "))
    end

    -- ③ 第 2 跳跳到白名单外 -> 失败，且**不许把它递到门口**
    do
        local map = {
            [START] = { code = 302, location = rd(1) },
            [rd(1)] = { code = 302, location = EVIL },
            [EVIL] = { body = PAYLOAD },
        }
        chainOf(map)
        local b, code, _st, err = H.get(START, {}, 30, { follow_redirects = true })
        ok(err ~= nil and b ~= PAYLOAD,
            "B2'-⑤：【最关键安全反例】第 2 跳跳到白名单外的 host 必须失败（谁调绿都是过拟合）",
            "code=" .. tostring(code) .. " err=" .. tostring(err) .. " len=" .. tostring(b and #b))
        ok(not xhas("evil.example.com"),
            "B2'-⑥：【强度反例】非法 host 在发出请求之前就被挡住（一次都没递到传输层）",
            table.concat(xurls(), " | "))
    end

    -- ④ 超过 3 跳 -> 防环
    do
        local map = {}
        map[START] = { code = 302, location = rd(1) }
        for _i = 1, 5 do
            map[rd(_i)] = { code = 302, location = rd(_i + 1) }
        end
        map[rd(6)] = { body = PAYLOAD }
        chainOf(map)
        local b, code, _st, err = H.get(START, {}, 30, { follow_redirects = true })
        ok(err ~= nil and b ~= PAYLOAD,
            "B2'-⑦：重定向超过 3 跳必须失败（防环；这里给了 6 跳）",
            "code=" .. tostring(code) .. " err=" .. tostring(err) .. " len=" .. tostring(b and #b))
        ok(#XNET.calls <= 4,
            "B2'-⑧：最多只走 4 个请求（首跳 + 3 跳），第 4 跳不再发起",
            "calls=" .. #XNET.calls)
    end

    -- ⑤ 明文跳转
    do
        local plain = "http://" .. rhosts[1] .. "/plain.zip"
        chainOf({ [START] = { code = 302, location = plain }, [plain] = { body = PAYLOAD } })
        local b, code, _st, err = H.get(START, {}, 30, { follow_redirects = true })
        ok(err ~= nil and b ~= PAYLOAD,
            "B2'-⑨：重定向到 http:// 必须失败（只认 https）",
            "code=" .. tostring(code) .. " err=" .. tostring(err) .. " len=" .. tostring(b and #b))
        ok(xplain() == 0,
            "B2'-⑩：【强度反例】明文 URL 一次都没被发出去",
            table.concat(xurls(), " | "))
    end

    -- ⑥ 下载域不许常驻白名单
    do
        local u = "https://" .. rhosts[1] .. "/x.zip"
        ok(H.isHostAllowed(u) == false,
            "B2'-⑪：【强度反例】下载域**不在**常驻白名单里（只在跟随跳转时按次放行）",
            "u=" .. u)
        ok(H.isHostAllowed(u, H.REDIRECT_HOSTS) == true,
            "B2'-⑫：（对照）显式传 REDIRECT_HOSTS 时同一个 URL 放行（证明⑪不是「根本没这张表」）",
            "u=" .. u)
        ok(type(H.MAX_REDIRECTS) == "number" and H.MAX_REDIRECTS == 3,
            "B2'-⑬：MAX_REDIRECTS == 3（跳数上限写死在模块上，不是散在调用点）",
            tostring(H.MAX_REDIRECTS))
    end

    -- ⑦ 通过 Ota:download 走一遍（真实链路，不再是我演的桩）
    if type(OtaR) == "table" and type(OtaR.download) == "function" then
        local DL = TEST_DIR .. "/dl_real"
        ensureDir(DL)
        do
            local map = {
                [START] = { code = 302, location = rd(1) },
                [rd(1)] = { code = 302, location = rd(2) },
                [rd(2)] = { body = PAYLOAD },
            }
            chainOf(map)
            local dest = DL .. "/ok.zip"
            local okd, a, e = pcall(OtaR.download, OtaR, START, dest)
            ok(okd and a == true,
                "B2'-⑭：Ota:download 在合法跳转链上成功（真 HttpClient 全程参与）",
                okd and tostring(e) or tostring(a))
            local got = readFile(dest)
            ok(got == PAYLOAD and type(got) == "string" and #got == #PAYLOAD,
                "B2'-⑮：【强度反例】落盘字节数 == 返回包体字节数，且逐字节一致（"
                    .. #PAYLOAD .. " 字节，含 NUL/0xFF）",
                "got=" .. tostring(got and #got) .. " want=" .. #PAYLOAD)
        end
        do
            local map = {
                [START] = { code = 302, location = rd(1) },
                [rd(1)] = { code = 302, location = EVIL },
                [EVIL] = { body = PAYLOAD },
            }
            chainOf(map)
            local okd, a = pcall(OtaR.download, OtaR, START, DL .. "/evil.zip")
            ok((not okd) or a ~= true,
                "B2'-⑯：Ota:download 遇到跳到白名单外的 Location 时失败（不落盘）",
                okd and ("got=" .. tostring(a)) or tostring(a))
            ok(not xhas("evil.example.com"),
                "B2'-⑰：【强度反例】download 全程没有向白名单外的 host 发过请求",
                table.concat(xurls(), " | "))
        end
        do
            -- 【团队裁定：EXEMPT，但换成等价强度的断言】
            -- 派单原文"不开 opt-in 时遇到 302 必须失败"指的是 **HttpClient 的默认行为**
            -- （B2'-① 已验：默认不跟随），不是 Ota:download 这一层。
            -- GitHub 的 zipball 地址**必然 302**，download 不开跟随就永远下不下来；
            -- 而"每跳仍过白名单"这道安全属性并没有被绕过（见 B2'-⑤/⑥/⑯/⑰）。
            -- 所以 download 恒开跟随是**正确的**，原断言属于派单把两层的 opt-in 混成了一层。
            -- 换成下面这条：不要求"能关"，要求"是显式开出来的"。
            local map = {
                [START] = { code = 302, location = rd(1) },
                [rd(1)] = { body = PAYLOAD },
            }
            chainOf(map)
            local seen_opts = {}
            local real_get = H.get
            -- 注意签名：HttpClient.get 是**点号定义**的（get(url, headers, timeout, opts)），
            -- 没有 self。第一版我照着冒号习惯写成 function(self, url, ...)，
            -- 于是 opts 落到了 timeout 上、opts 恒为 nil —— 又是一次"桩写错表现为假红"。
            H.get = function(url, headers, timeout, opts, ...)
                seen_opts[#seen_opts + 1] = opts
                return real_get(url, headers, timeout, opts, ...)
            end
            local okd, a, e = pcall(OtaR.download, OtaR, START, DL .. "/default.zip")
            H.get = real_get
            ok(okd and a == true,
                "B2'-⑱：（前置）这条路径上 download 真的成功了"
                .. "（它不成功的话，下面那条 opt-in 断言验的就是个失败流程）",
                okd and tostring(e) or tostring(a))
            local o1 = seen_opts[1]
            if type(o1) == "table" and o1.follow_redirects == true then
                exempt("B2'-⑲ Ota:download 恒开跟随（契约裁定为正确行为）",
                    "实测显式传了 follow_redirects=true；GitHub zipball 必然 302，"
                    .. "默认态由 B2'-① 把着。判 EXEMPT，不计入 PASS。")
            else
                ok(false,
                    "B2'-⑲：Ota:download 必须**显式**传 follow_redirects = true"
                    .. "（不是靠「默认也跟随」混过去；改成 false 时 B2'-⑭ 必须一起转红）",
                    "opts=" .. (type(o1) == "table"
                        and ("follow_redirects=" .. tostring(o1.follow_redirects))
                        or tostring(o1)))
            end
        end
    else
        skip("B2'-⑭-B2'-⑱ download 真链路", "Ota:download 不可达")
    end

    -- 还原：后面的 C 段用回桩 HttpClient（避免 UI 路径上出现真网络调用）
    XNET.responder = nil
    restore_stub_at_end()
end

-- ======================================================================
-- B3. 文件操作：backup / apply / rollback（**只用副本目录做实验**）
-- ======================================================================
local function secB3()
    section("B3. backup / apply / rollback（只在 TEST_DIR 内的假插件目录上做）")

    if not OTA_OK then
        otaMissing("B3：ywbf/ota.lua 可加载")
        skip("B3 全部文件用例", "模块未落地")
        return
    end
    if type(Ota.backup) ~= "function" or type(Ota.apply) ~= "function"
        or type(Ota.rollback) ~= "function" then
        otaMissing("B3：backup / apply / rollback 三件套存在")
        skip("B3 全部文件用例", "接口缺失")
        return
    end

    local FAKE = TEST_DIR .. "/fakeplugin"
    local V1_SETTINGS = '{"api_key_enc":"V1-SECRET","favorites":[1,2,3]}'
    local V1_OTA = "-- V1 OTA\n"
    local V1_MAIN = "-- V1 MAIN\n"
    ensureDir(FAKE .. "/data/history")
    ensureDir(FAKE .. "/ywbf")
    writeFile(FAKE .. "/main.lua", V1_MAIN)
    writeFile(FAKE .. "/_meta.lua", 'return { fullname = "远望书友" }\n')
    writeFile(FAKE .. "/ywbf/config.lua", "-- V1 CONFIG\n")
    writeFile(FAKE .. "/ywbf/ota.lua", V1_OTA)
    writeFile(FAKE .. "/data/settings.json", V1_SETTINGS)
    writeFile(FAKE .. "/data/history/h1.json", '{"entries":{}}\n')
    -- 备份目录与暂存目录**必须真的存在**：B3㉒ 断言的是"备份包里不含这两个目录"，
    -- 夹具里没有它们的话，排不排除结果都一样 —— 那条断言就是空转
    -- （O2 变异把 exclude 换成永不命中的名字后它仍然绿，就是这么暴露的）。
    ensureDir(FAKE .. "/data/ota_backup")
    ensureDir(FAKE .. "/data/ota_stage")
    writeFile(FAKE .. "/data/ota_backup/OLD_BACKUP_SENTINEL", "OLD-BACKUP\n")
    writeFile(FAKE .. "/data/ota_stage/OLD_STAGE_SENTINEL", "OLD-STAGE\n")

    ok(readFile(FAKE .. "/data/settings.json") == V1_SETTINGS,
        "B3：（前置）假插件目录造好了", nil)

    -- 备份产物可能是**目录**也可能是 **tar.gz 包**（实现侧选了后者）。
    -- 断言改成格式无关：不管装在哪儿，都要能把 data/settings.json 原样取出来逐字节比对。
    -- 强度没降——"备份里有没有用户数据"是这个问题本身，不是"用了哪种容器"。
    local function backupRead(path, rel)
        if type(path) ~= "string" or path == "" then return nil end
        if isDir(path) then return readFile(path .. "/" .. rel) end
        local tmp = TEST_DIR .. "/bk_extract.tmp"
        os.remove(tmp)
        os.execute(string.format("tar -xzOf '%s' './%s' > '%s' 2>/dev/null", path, rel, tmp))
        local s = readFile(tmp)
        os.remove(tmp)
        return s
    end
    local function backupList(path)
        if type(path) ~= "string" or path == "" then return {} end
        if isDir(path) then return listFiles(path) end
        local f = io.popen(string.format("tar -tzf '%s' 2>/dev/null", path))
        if not f then return {} end
        local raw = f:read("*a") or ""
        f:close()
        local out = {}
        for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
            if line ~= "" then out[#out + 1] = line end
        end
        table.sort(out)
        return out
    end
    local function backupSize(path)
        if type(path) ~= "string" then return nil end
        local f = io.open(path, "rb")
        if not f then return nil end
        local n = f:seek("end")
        f:close()
        return n
    end

    -- ---- backup ----
    local p1, p2 = nil, nil
    do
        local okb, a, e = pcall(Ota.backup, Ota, FAKE)
        p1 = a
        ok(okb and type(a) == "string" and a ~= "",
            "B3①：backup 返回备份路径", okb and tostring(a) or tostring(e))
        if type(a) == "string" and a ~= "" then
            local sz = backupSize(a)
            ok((sz ~= nil and sz > 0) or isDir(a),
                "B3②：备份产物**真的存在且非空**（空包等于没备份）",
                "path=" .. tostring(a) .. " size=" .. tostring(sz))
            local bs = backupRead(a, "data/settings.json")
            ok(bs == V1_SETTINGS,
                "B3③：【P0·契约待裁定】备份里含 data/settings.json 且内容一致"
                .. "（API Key 与收藏/历史在这，丢了是 P0）",
                "got=" .. (bs and Util.utf8sub(bs, 40) or "备份里没有这个文件"))
            -- 对照组：备份里确实有代码文件，证明"没有 data/"是**刻意排除**
            -- 而不是"tar 打了个空包 / 打包路径写错"。没有这条，B3③ 的红没法判读。
            local bm = backupRead(a, "main.lua")
            ok(bm == V1_MAIN,
                "B3④：（对照）备份里含 main.lua 且内容一致（证明打包真的做了事）",
                "got=" .. tostring(bm))
            -- 【新增·裁定 B3③ 配套】备份包里不许含备份目录/暂存目录**自身**：
            -- 不排除会自我递归，第二次备份把第一次整个打进去 -> 指数膨胀。
            -- 判据走清单扫描，先证清单非空（否则"没有 ota_backup"是空转）。
            local blist = backupList(a)
            ok(readFile(FAKE .. "/data/ota_backup/OLD_BACKUP_SENTINEL") == "OLD-BACKUP\n"
                and readFile(FAKE .. "/data/ota_stage/OLD_STAGE_SENTINEL") == "OLD-STAGE\n",
                "B3㉑'：（前置）夹具里 data/ota_backup 与 data/ota_stage **真的存在**"
                .. "（不存在的话，排不排除都一样，B3㉒ 就是空转）",
                "backup=" .. tostring(readFile(FAKE .. "/data/ota_backup/OLD_BACKUP_SENTINEL")))
            ok(#blist > 0,
                "B3㉑：（前置）拿得到备份清单（清单是空的话，下面那条「不含什么」全都是空转）",
                "entries=" .. #blist)
            local self_ref = {}
            for _i, n in ipairs(blist) do
                if n:find("ota_backup", 1, true) or n:find("ota_stage", 1, true) then
                    self_ref[#self_ref + 1] = n
                end
            end
            ok(#self_ref == 0,
                "B3㉒：备份包里**不含** data/ota_backup / data/ota_stage 自身"
                .. "（不排除就会自我递归：第二次备份把第一次整个打进去，指数膨胀）",
                #self_ref > 0 and table.concat(self_ref, " | ") or "清单里没有这两项")
            -- 对照：改成全量备份之后，data 里**别的**东西必须在（这条就是 B3③，
            -- 与 B3㉒ 互为反向：一个说"要有 data"，一个说"不要有备份目录自身"）。
            note("B3 备份清单里的 data 项",
                (function()
                    local t = {}
                    for _i, n in ipairs(blist) do
                        if n:find("data", 1, true) then t[#t + 1] = n end
                    end
                    return #t > 0 and table.concat(t, " | ") or "（清单里一个 data 项都没有）"
                end)())
            -- 备份不许逃出沙箱
            local np, root = normalize(a), normalize(TEST_DIR)
            ok(type(np) == "string" and type(root) == "string" and np:sub(1, #root) == root,
                "B3⑤：备份路径（规范化后）落在测试沙箱之内，没有穿越出去",
                "backup=" .. tostring(np) .. " root=" .. tostring(root))
            ok(hasNot(tostring(a), "/tmp") and hasNot(tostring(a), "/var"),
                "B3⑥：备份没有落在 /tmp /var（32M tmpfs 常年满，写进去必然失败）", a)
            note("B3 备份归档清单", table.concat(backupList(a), " | "))
        else
            skip("B3②-B3⑥ 备份内容", "backup 没返回路径：" .. tostring(e))
        end

        -- 唯一性：这是本项目出过事故的点（固定路径被并发部署互相删掉，data 整体丢失）
        local md5_p1 = (type(p1) == "string") and md5_of(p1) or nil
        local okb2, a2 = pcall(Ota.backup, Ota, FAKE)
        p2 = a2
        ok(okb2 and type(a2) == "string" and a2 ~= nil and a2 ~= p1,
            "B3⑦：【强度反例】两次 backup 的路径**不同**（固定路径会被并发部署互相删掉）",
            "1st=" .. tostring(p1) .. " 2nd=" .. tostring(a2))
        if type(p1) == "string" and type(a2) == "string" then
            ok(md5_of(p1) == md5_p1 and backupSize(p1) ~= nil,
                "B3⑧：【强度反例】第二次 backup 之后，第一次的备份仍然完好（没被互相删掉）",
                "1st md5 前后=" .. tostring(md5_p1) .. " / " .. tostring(md5_of(p1)))
        end
    end

    -- ---- apply ----
    -- 真 zip：纯 Lua 生成 stored（method 0）zip，真机 busybox unzip 解得开（已实测）。
    -- GitHub 的源码包外面套了一层 `<repo>-<ref>/` 根目录，夹具必须照这个形状造，
    -- 否则实现侧"只认恰好一个顶层目录"的护栏会先把包拒了，后面的用例全是空转。
    local ZIP_PATH = TEST_DIR .. "/update.zip"
    local SLIP_PATH = TEST_DIR .. "/slip.zip"
    local ROOT = "YuanWangBookFriend-0.2.0"
    local V2_OTA = "-- V2 OTA\n"
    local V2_MAIN = "-- V2 MAIN\n"
    local V2_SETTINGS = '{"api_key_enc":"V2-PWNED"}'
    local zip_bytes, slip_bytes = nil, nil
    do
        local function bxor(a, b)
            local r, p = 0, 1
            for _i = 1, 32 do
                if (a % 2) ~= (b % 2) then r = r + p end
                a = math.floor(a / 2)
                b = math.floor(b / 2)
                p = p * 2
            end
            return r
        end
        local function crc32(s)
            local crc = 0xFFFFFFFF
            for _i = 1, #s do
                crc = bxor(crc, s:byte(_i))
                for _j = 1, 8 do
                    if crc % 2 == 1 then
                        crc = bxor(math.floor(crc / 2), 0xEDB88320)
                    else
                        crc = math.floor(crc / 2)
                    end
                end
            end
            return bxor(crc, 0xFFFFFFFF)
        end
        local function u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
        local function u32(v)
            return string.char(v % 256, math.floor(v / 256) % 256,
                math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
        end
        local function buildZip(entries)
            local out, central, offset = {}, {}, 0
            for _i, e in ipairs(entries) do
                local crc = crc32(e.content)
                local lh = "PK\003\004" .. u16(20) .. u16(0) .. u16(0) .. u16(0) .. u16(22561)
                    .. u32(crc) .. u32(#e.content) .. u32(#e.content)
                    .. u16(#e.name) .. u16(0) .. e.name
                out[#out + 1] = lh
                out[#out + 1] = e.content
                central[#central + 1] = "PK\001\002" .. u16(20) .. u16(20) .. u16(0) .. u16(0)
                    .. u16(0) .. u16(22561) .. u32(crc) .. u32(#e.content) .. u32(#e.content)
                    .. u16(#e.name) .. u16(0) .. u16(0) .. u16(0) .. u16(0) .. u32(0)
                    .. u32(offset) .. e.name
                offset = offset + #lh + #e.content
            end
            local body, cd = table.concat(out), table.concat(central)
            return body .. cd .. "PK\005\006" .. u16(0) .. u16(0)
                .. u16(#entries) .. u16(#entries) .. u32(#cd) .. u32(#body) .. u16(0)
        end
        -- 实现侧要求顶层目录里同时有 main.lua 和 _meta.lua 才认这是插件本体，
        -- 夹具必须照给（第一版只给了 main.lua，apply 直接把包拒了，B3⑪ 成假红）
        zip_bytes = buildZip({
            { name = ROOT .. "/main.lua", content = V2_MAIN },
            { name = ROOT .. "/_meta.lua", content = 'return { fullname = "远望书友" }\n' },
            { name = ROOT .. "/ywbf/ota.lua", content = V2_OTA },
            { name = ROOT .. "/ywbf/config.lua", content = "-- V2 CONFIG\n" },
            -- 故意塞一份 data/settings.json：零污染是硬要求，不许被覆盖
            { name = ROOT .. "/data/settings.json", content = V2_SETTINGS },
        })
        -- zip-slip 单独一个包：探针条目混进主包会改变顶层目录个数，
        -- 让实现侧的结构护栏先把它拒了，反而测不到"逃出去没有"。
        slip_bytes = buildZip({
            { name = ROOT .. "/main.lua", content = V2_MAIN },
            { name = ROOT .. "/_meta.lua", content = 'return { fullname = "远望书友" }\n' },
            { name = ROOT .. "/" .. string.rep("../", 5) .. "pwned_ota_probe.txt",
              content = "PWNED BY ZIP SLIP\n" },
        })
    end
    writeFile(ZIP_PATH, zip_bytes)
    writeFile(SLIP_PATH, slip_bytes)
    ok(#zip_bytes > 100 and #slip_bytes > 100,
        "B3⑨：（前置）真 zip 夹具生成成功（update " .. tostring(#zip_bytes)
        .. " 字节 / slip " .. tostring(#slip_bytes) .. " 字节）", nil)
    -- 对照组：这个 zip 确实是能被真机解开的合法 zip（否则后面"apply 成功"全是空转）
    do
        local probe = TEST_DIR .. "/zipprobe"
        ensureDir(probe)
        os.execute("unzip -o -q '" .. ZIP_PATH .. "' -d '" .. probe .. "'")
        ok(readFile(probe .. "/" .. ROOT .. "/main.lua") == V2_MAIN,
            "B3⑩：（对照）真机 unzip 解得开这份 zip（解不开的话 B3⑪ 之后的用例全是空转）",
            tostring(readFile(probe .. "/" .. ROOT .. "/main.lua")))
        os.execute("rm -rf '" .. probe .. "'")
    end

    do
        local oka, a, e = pcall(Ota.apply, Ota, ZIP_PATH, FAKE)
        ok(oka and a == true,
            "B3⑪：apply 成功", oka and tostring(e) or tostring(a))
        -- 对照组：apply 必须真的把新文件写进去了，否则"什么都没做"也能绿
        ok(readFile(FAKE .. "/ywbf/ota.lua") == V2_OTA,
            "B3⑫：（对照）zip 里的新文件真的落进目标目录（证明 apply 不是空转）",
            tostring(readFile(FAKE .. "/ywbf/ota.lua")))
        ok(readFile(FAKE .. "/main.lua") == V2_MAIN,
            "B3⑬：（对照）zip 里的 main.lua 也更新了", tostring(readFile(FAKE .. "/main.lua")))
        -- 硬断言：零污染
        ok(readFile(FAKE .. "/data/settings.json") == V1_SETTINGS,
            "B3⑭：【强度反例】apply 之后 data/settings.json **仍在且内容未被覆盖**"
            .. "（这一条最容易被误判成过约束，但它就是必须保留的强度）",
            tostring(readFile(FAKE .. "/data/settings.json")))
        ok(readFile(FAKE .. "/data/history/h1.json") ~= nil,
            "B3⑮：apply 之后 data/history 也还在（不删用户数据）", nil)
    end

    -- zip-slip：单独一个假插件目录，逐个候选落点检查
    do
        local FAKE2 = TEST_DIR .. "/fakeplugin_slip"
        ensureDir(FAKE2 .. "/data")
        writeFile(FAKE2 .. "/main.lua", V1_MAIN)
        writeFile(FAKE2 .. "/data/settings.json", V1_SETTINGS)
        -- 只查**目标目录之外**的落点。落在 target/data/ota_stage/ 里不算逃逸——
        -- 那是实现自己的解压中转目录，本来就在插件目录内（busybox unzip 会剥掉 ../，
        -- 实测就是剥到了这里）。真正的 zip-slip 是落到 TEST_DIR 乃至 /mnt/us/ywbf_dev 上。
        local candidates = {
            "/mnt/us/ywbf_dev/pwned_ota_probe.txt",
            TEST_DIR .. "/pwned_ota_probe.txt",
            "/mnt/us/ywbf_dev/ota_data_backup_probe.txt",
        }
        for _i, c in ipairs(candidates) do os.remove(c) end
        local oks, r_slip, e_slip = pcall(Ota.apply, Ota, SLIP_PATH, FAKE2)
        local landed = {}
        for _i, c in ipairs(candidates) do
            if readFile(c) ~= nil then landed[#landed + 1] = c end
        end
        ok(#landed == 0,
            "B3⑯：【强度反例】zip 里带 ../ 的条目没有落到目标目录之外（zip-slip）",
            #landed > 0 and table.concat(landed, " ;; ")
                or ("apply=" .. tostring(r_slip) .. " err=" .. tostring(e_slip)))
        note("B3⑯ slip 包处理结果",
            "apply=" .. tostring(r_slip) .. " err=" .. tostring(e_slip)
            .. "（若 apply 拒绝了整个包，那是护栏生效；若成功，则必须没有逃逸文件）")
    end

    -- 目标目录路径必须被校验（不许 .. 穿越出插件目录之外）
    --
    -- 三处**各自单拆**：backup / apply / rollback 是三条不同的 shell 出口
    -- （`tar -czf -C` / `tar -xf -C` / `tar -xzf -C`），护栏必须是三把各管一把的锁。
    -- 只测 apply 一处的代价是实测出来的：拆掉 backup 那处（D1）和 rollback 那处（D3）
    -- 时整套件仍然 159/159 全绿——那两把锁等于"加了但没人看着"。
    local ESC_ROOT = "/mnt/us/ywbf_dev"
    do
        local esc = ESC_ROOT .. "/escape_target"
        os.execute("rm -rf '" .. esc .. "'")
        pcall(Ota.apply, Ota, ZIP_PATH, TEST_DIR .. "/fakeplugin/../../escape_target")
        local files = listFiles(esc)
        ok(#files == 0,
            "B3⑰-a（apply）：【强度反例】target_dir 带 .. 穿越时不许把文件写到沙箱之外"
            .. "（「字符串以 dir..'/' 开头」是假绿，这里比的是规范化后的真实落点）",
            #files > 0 and table.concat(files, ",") or nil)
        os.execute("rm -rf '" .. esc .. "'")
    end
    do
        local esc = ESC_ROOT .. "/escape_backup"
        os.execute("rm -rf '" .. esc .. "'")
        pcall(Ota.backup, Ota, TEST_DIR .. "/fakeplugin/../../escape_backup")
        local files = listFiles(esc)
        ok(#files == 0,
            "B3⑰-b（backup）：【强度反例】backup 的 target_dir 带 .. 穿越时不许写出去"
            .. "（backup 走 `tar -czf -C`，跟 apply 不是一个出口，护栏必须另有一把）",
            #files > 0 and table.concat(files, ",") or nil)
        os.execute("rm -rf '" .. esc .. "'")
    end
    do
        local esc = ESC_ROOT .. "/escape_rollback"
        os.execute("rm -rf '" .. esc .. "'")
        -- 前置：先把逃逸落点**建出来**。不建的话 `tar -C` 直接失败、一个字节都没写，
        -- "没有逃逸文件"就成了空绿——护栏拆没拆都绿，这条断言等于白写。
        ensureDir(esc)
        ok(isDir(esc),
            "B3⑰-c0：（前置）rollback 的逃逸落点目录已建好（建不出来的话，"
            .. "下面那条「没有逃逸文件」就是空绿）", tostring(esc))
        local bp = (type(p2) == "string") and p2 or p1
        local okr2, r_rb, e_rb = pcall(Ota.rollback, Ota, bp,
            TEST_DIR .. "/fakeplugin/../../escape_rollback")
        local files = listFiles(esc)
        ok(#files == 0,
            "B3⑰-c（rollback）：【强度反例】rollback 的 target_dir 带 .. 穿越时不许写出去"
            .. "（rollback 走 `tar -xzf -C`，第三把锁）",
            #files > 0 and table.concat(files, ",") or nil)
        note("B3⑰-c 实测",
            "rollback=" .. tostring(r_rb) .. " err=" .. tostring(e_rb)
            .. "（护栏生效时应是 nil + 错误原因；目录已预先建好，所以「没写」不是 tar 没跑）")
        os.execute("rm -rf '" .. esc .. "'")
    end

    -- ---- rollback ----
    do
        local target_bak = (type(p2) == "string") and p2 or p1
        if type(target_bak) ~= "string" then
            skip("B3⑱-B3⑳ rollback", "没有可用的备份路径")
        else
            local okr, a, e = pcall(Ota.rollback, Ota, target_bak, FAKE)
            ok(okr and a == true, "B3⑱：rollback 成功", okr and tostring(e) or tostring(a))
            ok(readFile(FAKE .. "/data/settings.json") == V1_SETTINGS,
                "B3⑲：rollback 之后 data/settings.json 恢复成备份时的内容",
                tostring(readFile(FAKE .. "/data/settings.json")))
            local back_ota = readFile(FAKE .. "/ywbf/ota.lua")
            ok(back_ota == V1_OTA or back_ota == nil,
                "B3⑳：rollback 之后由 apply 写入的新版本被还原（回到 V1 内容或该文件回到不存在）",
                "got=" .. tostring(back_ota))
            ok(isDir(FAKE .. "/data"),
                "B3㉑：rollback 之后 data/ 目录仍然存在（回滚不许把用户数据一起带走）", nil)
        end
    end

    -- ---- 静态辅助扫描：不许删插件目录之外的东西 ----
    do
        local src = readFile(PLUGIN_DIR .. "/ywbf/ota.lua")
        ok(type(src) == "string" and #src > 200,
            "B3㉒：（前置）读得到 ota.lua 全文（读不到，下面两条是空扫描）",
            src and #src or "<nil>")
        -- 对照组：扫描器在同一份文件上能命中 require（证明文件读到了、扫描器是好的）
        ok(has(src, "require("),
            "B3㉓：（对照）扫描器在 ota.lua 里命中了 require（证明 B3㉔ 不是空扫描）", nil)

        local bad = {}
        local n_shell = 0
        for _i, ln in ipairs(codeLines(src)) do
            local line = ln.text
            if ln.code and (has(line, "os.remove") or has(line, "io.popen")
                or has(line, "os.execute")) then
                n_shell = n_shell + 1
                -- rm -rf 后面直接跟一个**字面量绝对路径**就是危险信号；
                -- 变量拼出来的路径只能靠人工审，这里把原文打出来供复核。
                if has(line, "rm -rf /") or has(line, "rm  -rf /") then
                    bad[#bad + 1] = _i .. ":" .. line
                elseif (has(line, "rm -rf") or has(line, "rm -fr"))
                    and line:find("rm%s+%-[rf][rf]%s+['\"]?/") then
                    bad[#bad + 1] = _i .. ":" .. line
                end
                if has(line, "wget") or has(line, "curl") then
                    bad[#bad + 1] = _i .. ":裸 wget/curl -> " .. line
                end
            end
        end
        ok(#bad == 0,
            "B3㉔：【辅助静态】ota.lua 的 shell 调用点里没有 rm -rf 绝对路径 / 裸 wget|curl",
            #bad > 0 and table.concat(bad, " ;; ") or nil)
        note("B3㉔ shell 调用点", n_shell .. " 处（逐处原文见上；人工复核用）")
        if n_shell == 0 then
            note("B3㉔", "ota.lua 一处 shell 调用都没有——备份/解压全走 Lua，这本身是好事，"
                .. "但此时 B3㉔ 属于空扫描，结论以行为断言为准")
        end
    end
end

-- ======================================================================
-- C. 关于菜单
-- ======================================================================
local function secC()
    section("C. 关于菜单（版本号来自 Config.VERSION / 一次只允许一个对话框）")

    local function itemText(it)
        if type(it) ~= "table" then return nil end
        if type(it.text) == "string" then return it.text end
        if type(it.text_func) == "function" then
            local oks, s = pcall(it.text_func)
            if oks and type(s) == "string" then return s end
        end
        return nil
    end
    local function collectStrings(t, depth, out)
        if type(t) ~= "table" or depth > 5 then return out end
        for _i, k in ipairs({ "text", "title", "info", "message", "_text" }) do
            local v = t[k]
            if type(v) == "string" then out[#out + 1] = v end
        end
        if type(t.text_func) == "function" then
            local oks, s = pcall(t.text_func)
            if oks and type(s) == "string" then out[#out + 1] = s end
        end
        for _k, v in pairs(t) do
            if type(v) == "table" then collectStrings(v, depth + 1, out) end
        end
        return out
    end
    local function collectEntries(t, depth, out)
        if type(t) ~= "table" or depth > 5 then return out end
        if type(t.callback) == "function" then
            local s = itemText(t)
            if type(s) == "string" then out[#out + 1] = { text = s, cb = t.callback } end
        end
        for _k, v in pairs(t) do
            if type(v) == "table" then collectEntries(v, depth + 1, out) end
        end
        return out
    end
    local function loadSettingsUI()
        package.loaded["ui/settings"] = nil
        package.loaded["ui/about"] = nil
        local oks, m = pcall(require, "ui/settings")
        if oks and type(m) == "table" then return m, nil end
        local oka, a = pcall(require, "ui/about")
        if oka and type(a) == "table" then return a, nil end
        return nil, tostring(m)
    end

    local SettingsUI, load_err = loadSettingsUI()
    if type(SettingsUI) ~= "table" then
        ok(false, "C1：ui/settings（或 ui/about）能加载", load_err)
        skip("C2-C13 关于菜单", "UI 模块起不来（多半是 ywbf/ota 还没落地）")
        return
    end
    ok(true, "C1：ui/settings（或 ui/about）能加载", nil)

    local plugin_stub = {
        onYWBFOpenAssistant = function() end,
        showLastReply = function() end,
        bookFingerprint = function() return "fp" end,
        bookTitle = function() return "书名" end,
        currentProgress = function() return { ok = false } end,
    }

    local okb, items = false, nil
    if type(SettingsUI.buildMenu) == "function" then
        okb, items = pcall(function() return SettingsUI:buildMenu(plugin_stub) end)
    else
        okb, items = pcall(function() return SettingsUI:build(plugin_stub) end)
    end
    ok(okb and type(items) == "table" and #items > 0,
        "C2：（前置）插件主菜单画得出来（画不出来下面全是空转）",
        okb and tostring(items) or tostring(items))

    local texts = {}
    if type(items) == "table" then
        for _i, it in ipairs(items) do
            local s = itemText(it)
            if s then texts[#texts + 1] = s end
        end
    end

    -- 对照组：既有菜单项都还在（否则"加了一项"可能是"把菜单换掉了"）
    do
        local expect = { "呼出 AI 助手", "API Key 配置", "模型选择", "防剧透模式", "我的收藏" }
        local miss = {}
        local joined_all = table.concat(texts, "|")
        for _i, e in ipairs(expect) do
            if not has(joined_all, e) then miss[#miss + 1] = e end
        end
        ok(#miss == 0,
            "C3：（对照）主菜单里既有的菜单项**都还在**（少一个就是被这轮改动顶掉了）",
            #miss > 0 and ("缺：" .. table.concat(miss, ",") .. " / 实际：" .. joined_all) or nil)
    end

    local function isAboutText(s)
        return type(s) == "string"
            and (has(s, "关于") or has(s, "版本") or has(s, "检查更新"))
    end
    local about_item = nil
    if type(items) == "table" then
        for _i, it in ipairs(items) do
            if isAboutText(itemText(it)) then about_item = it; break end
        end
    end
    ok(type(about_item) == "table",
        "C4：主菜单里出现了「关于」这一项（用户找得到它）",
        type(about_item) == "table" and itemText(about_item)
            or ("菜单项：" .. table.concat(texts, " | ")))
    if type(about_item) ~= "table" then
        skip("C5-C13 关于对话框", "没找到关于菜单项")
        return
    end

    -- 打开「关于」的**整条链路**：主项回调 + 子菜单每一项的文字与其回调。
    -- 实现既可能是"点开就是个对话框"，也可能是"关于"下挂子菜单（每行各弹一个），
    -- 两种都是合理设计，所以这里**全收**：菜单行文字 + 所有弹窗文字。
    -- （第一版只收"第一个弹窗"，结果把"数据目录"那一行漏在外面，C10 成了假红。）
    -- 菜单项的 text 与 text_func() **两个都要收**：只收 text 会漏掉
    -- "标题固定、版本写在 text_func 里"这种写法——变异 M-B 就是这么躲过 C7/C8 的
    -- （那一次只有静态扫描 A9 抓到了它，行为断言没吭声）。
    local function pushText(out, it)
        if type(it) ~= "table" then return end
        if type(it.text) == "string" then out[#out + 1] = it.text end
        if type(it.text_func) == "function" then
            local oks, s = pcall(it.text_func)
            if oks and type(s) == "string" then out[#out + 1] = s end
        end
    end
    local function openAboutChain(it, with_update)
        uiReset()
        local all = {}
        pushText(all, it)
        if type(it.callback) == "function" then pcall(it.callback) end
        if type(it.sub_item_table) == "table" then
            for _i, sub in ipairs(it.sub_item_table) do
                pushText(all, sub)
                -- 默认**不点**「检查更新」：它的结果框里会印出远端版本号（99.0.0），
                -- 混进来会让 C8"界面上只能有一个版本号"被自己的夹具污染成假红。
                if type(sub.callback) == "function"
                    and (with_update or not has(itemText(sub), "检查更新")) then
                    pcall(sub.callback)
                end
            end
        end
        local entries = {}
        for _i, w in ipairs(UI_SHOWN) do
            collectStrings(w, 0, all)
            for _j, e in ipairs(collectEntries(w, 0, {})) do entries[#entries + 1] = e end
        end
        return table.concat(all, "\n"), entries
    end

    -- 链路里会真的去查一次 GitHub（走桩，不出网），先给一个良性响应器
    local function stubRelease(tag)
        netReset(function()
            return ([[{"tag_name":"%s","name":"远望书友 %s",
                "zipball_url":"https://api.github.com/repos/%s/zipball/%s",
                "html_url":"https://github.com/%s/releases/tag/%s","body":"更新说明"}]]):format(
                tag, tag, tostring(Ota and Ota.REPO or "r"), tag,
                tostring(Ota and Ota.REPO or "r"), tag), 200, "OK", nil, {}
        end)
    end
    stubRelease("99.0.0")

    local joined, entries = openAboutChain(about_item)
    ok(#UI_SHOWN > 0,
        "C5：点开「" .. tostring(itemText(about_item)) .. "」会弹出对话框",
        "shown=" .. #UI_SHOWN)
    ok(type(joined) == "string" and #joined > 0,
        "C5b：（前置）关于链路里收到了文本（收不到，下面两条就是空绿）",
        joined and Util.utf8sub(joined, 60) or "<nil>")

    -- 版本号必须来自 Config.VERSION：变异 Config.VERSION，界面上的版本必须跟着变。
    -- 「字段等于预期值」抓不住写死常量，所以必须配变异 + 对照组。
    local MUT = "7.7.7"
    local old_version = Config.VERSION
    Config.VERSION = MUT            -- 直接改内存字段，不落盘
    local reload_ok, SettingsUI2, reload_err = false, nil, nil
    do
        -- loadSettingsUI 固定返回 (module, err)：只接一个值会把 err 当成模块，
        -- 于是"重载成功"被判成失败，C7/C8 变成空绿——我第一版就是这么栽的。
        local m, e = loadSettingsUI()
        reload_ok, SettingsUI2, reload_err = (type(m) == "table"), m, e
    end
    if not reload_ok then
        note("C6 重载 ui/settings 失败", tostring(reload_err))
    end
    local join_mut = nil
    do
        if reload_ok and type(SettingsUI2.buildMenu) == "function" then
            local okb2, items2 = pcall(function() return SettingsUI2:buildMenu(plugin_stub) end)
            if okb2 and type(items2) == "table" then
                local it2 = nil
                for _i, it in ipairs(items2) do
                    if isAboutText(itemText(it)) then it2 = it; break end
                end
                if type(it2) == "table" then
                    local t2, _e2 = openAboutChain(it2)
                    join_mut = t2
                end
            end
        end
    end
    Config.VERSION = old_version    -- 还原（内存字段，无落盘）

    ok(type(join_mut) == "string" and #join_mut > 0,
        "C6：（前置）变异后也能打开关于链路（打不开，下面两条就是空绿）",
        join_mut and Util.utf8sub(join_mut, 60) or "<nil>")
    ok(type(join_mut) == "string" and has(join_mut, MUT),
        "C7：【强度反例】把 Config.VERSION 改成 " .. MUT .. " 后，界面上的版本跟着变"
        .. "（写死字符串的写法会被这条抓到）",
        join_mut and Util.utf8sub(join_mut, 160) or nil)
    do
        -- 对照组：文本里所有 x.y.z 形态的版本号，去重后只能剩 MUT 一个。
        -- 只断言"含 MUT"挡不住"写死 0.2.0 之外再拼一个动态版本"的糊弄写法。
        local seen, uniq = {}, {}
        for v in tostring(join_mut):gmatch("%d+%.%d+%.%d+") do
            if not seen[v] then seen[v] = true; uniq[#uniq + 1] = v end
        end
        ok(#uniq == 1 and uniq[1] == MUT,
            "C8：（对照）界面上 x.y.z 形态的版本号**只有** " .. MUT .. " 一个",
            #uniq > 0 and table.concat(uniq, ",") or "一个版本号都没有（那 C7 也是空绿）")
    end
    ok(type(joined) == "string" and joined:find("%d+%.%d+%.%d+") ~= nil,
        "C9：（对照）未变异时界面上确实显示了一个版本号",
        joined and Util.utf8sub(joined, 80) or nil)

    -- 数据目录路径（菜单行文字或弹窗文字里都算：两种形态都满足"用户看得到"）
    ok(type(joined) == "string" and has(joined, Config.paths.data),
        "C10：关于链路里显示了数据目录路径（" .. tostring(Config.paths.data) .. "）",
        joined and Util.utf8sub(joined, 200) or nil)

    -- 检查更新入口 + 不许叠对话框
    do
        local upd = nil
        if type(about_item.sub_item_table) == "table" then
            for _i, sub in ipairs(about_item.sub_item_table) do
                local s = itemText(sub)
                if type(s) == "string" and has(s, "更新") and type(sub.callback) == "function" then
                    upd = { text = s, callback = sub.callback }
                    break
                end
            end
        end
        if not upd then
            for _i, e in ipairs(entries) do
                if has(e.text, "更新") then upd = { text = e.text, callback = e.cb }; break end
            end
        end
        local names = {}
        for _i, e in ipairs(entries) do names[#names + 1] = e.text end
        ok(type(upd) == "table",
            "C11：关于链路里有「检查更新」入口",
            type(upd) == "table" and upd.text or ("可点条目：" .. table.concat(names, " | ")))

        if type(upd) == "table" then
            stubRelease("99.0.0")
            uiReset()
            local okc, errc = pcall(upd.callback)
            ok(okc, "C12：点「" .. tostring(upd.text) .. "」不抛异常", errc)
            -- 【裁定的判据】「菜单之上弹 InfoMessage」是 KOReader 的常态（设置菜单里
            -- 到处都是），把它算成叠层会让整条断言失焦。所以判据改成：
            -- **同一时刻非菜单弹层（InfoMessage / ConfirmBox / InputDialog）<= 1**，菜单不计入。
            ok(UI_PEAK_SOLID <= 1,
                "C13：【强度反例】点检查更新的全过程中，**非菜单弹层**同时最多只有 1 个"
                .. "（菜单之上弹提示是 KOReader 常态，不计入）",
                "peak(非菜单)=" .. UI_PEAK_SOLID .. " peak(全口径)=" .. UI_PEAK)

            -- ---- 新增两条：进度提示不许带 timeout，且必须先被 close 再弹结果 ----
            local function wtext(w)
                if type(w) ~= "table" then return "" end
                return tostring(w.text or w.info_text or w.message or "")
            end
            ok(#UI_SHOWN >= 1,
                "C13：（前置）检查更新过程中确实弹了东西（一个都没弹的话，下面两条全是空转）",
                "shown=" .. #UI_SHOWN)
            local progress, result = UI_SHOWN[1], (#UI_SHOWN >= 2) and UI_SHOWN[#UI_SHOWN] or nil
            ok(type(progress) == "table" and type(result) == "table" and progress ~= result,
                "C13：（对照）进度提示与结果弹窗是**两个不同的**弹层"
                .. "（同一个的话，下面 timeout / close 序两条都是在自言自语）",
                string.format("progress=%q result=%q", Util.utf8sub(wtext(progress), 40),
                    Util.utf8sub(wtext(result), 40)))
            if type(progress) == "table" and type(result) == "table" and progress ~= result then
                local tp = progress.timeout
                ok(tp == nil or tp == 0,
                    "C13②：进度提示**不带 timeout**"
                    .. "（查询是 Queue 异步的、要跑好几秒；1 秒后自己消失 = 用户干等，"
                    .. "然后结果弹窗突然蹦出来）",
                    "timeout=" .. tostring(tp) .. " text=" .. Util.utf8sub(wtext(progress), 40))
                note("C13② 对照", "结果弹窗 timeout=" .. tostring(result.timeout)
                    .. "（结果弹窗可以没有 timeout；两者靠「是不是同一个弹层」区分，见上一条）")

                local i_close, i_show_result = nil, nil
                for _i, ev in ipairs(UI_EVENTS) do
                    if ev.op == "close" and ev.w == progress and not i_close then i_close = _i end
                    if ev.op == "show" and ev.w == result then i_show_result = _i end
                end
                ok(i_close ~= nil,
                    "C13③：（前置）进度提示**真的被 close 过**（没 close 过就谈不上先后）",
                    "events=" .. #UI_EVENTS)
                -- 注意：这里**不能**写成 `if i_close ~= nil then ok(i_close < i_show) end`。
                -- 那样"删掉 close"的变异会让 C13④ 直接不执行（既不红也不绿，悄悄消失），
                -- 看起来像"变异没抓到"，其实是断言自己躲了。所以把"有没有 close"并进判据，
                -- 没有 close 就是这条不过（顺序更无从谈起）。
                ok(i_close ~= nil and i_show_result ~= nil and i_close < i_show_result,
                    "C13④：【顺序】结果弹窗 show 之前，进度提示**已经被 close**"
                    .. "（先关进度再弹结果，不许两个并排挂着；连 close 都没有也判不过）",
                    string.format("close(进度)=%s show(结果)=%s 事件流=%s",
                        tostring(i_close), tostring(i_show_result),
                        (function()
                            local t = {}
                            for _j, ev in ipairs(UI_EVENTS) do
                                t[#t + 1] = ev.op .. ":" .. Util.utf8sub(wtext(ev.w), 12)
                            end
                            return table.concat(t, " -> ")
                        end)()))
            end
            note("C13 实测对话框序列",
                "shown=" .. #UI_SHOWN .. " peak=" .. UI_PEAK .. " peak(非菜单)=" .. UI_PEAK_SOLID)
        else
            skip("C12-C13 叠层检查", "没找到检查更新入口")
        end
    end

    -- ==================================================================
    -- C14：testConnection / queryBalance 的进度提示
    --
    -- 为什么**另起一节**而不是并进 C13：这两处是另外两个独立菜单入口
    -- （「测试 DeepSeek 连接」/ 「查询账户余额」），跟 OTA「检查更新」不是同一条
    -- 调用链。并在一起的话，"只改 testConnection" 和 "只改 checkUpdate" 会红成
    -- 同一片，分不清是谁改坏的，也就没法分开回滚。另起一节才能做**双向归因**：
    --   只动 checkUpdate    -> 只有 C13②/③/④ 红，C14 全绿
    --   只动 testConnection -> 只有 C14-1/2/3 红，C14-4/5/6 与 C13 全绿
    --   只动 queryBalance   -> 只有 C14-4/5/6 红，C14-1/2/3 与 C13 全绿
    -- 第 2、3 行是关键：两处如果改一个就一起红，说明断言盯的是共享代码而不是各自
    -- 的调用点，那就没有归因能力。
    -- ==================================================================
    do
        local Prompts = nil
        do
            local okp, m = pcall(require, "ywbf/prompts")
            if okp and type(m) == "table" then Prompts = m end
        end
        local PERSONA = (type(Prompts) == "table" and type(Prompts.PERSONA_NAME) == "string")
            and Prompts.PERSONA_NAME or nil
        ok(type(PERSONA) == "string" and PERSONA ~= "",
            "C14-0：（前置）取得到 Prompts.PERSONA_NAME（取不到，下面的人设断言全是空转）",
            tostring(PERSONA))

        -- 让 DeepSeek 的两条真请求在桩上都**成功**：失败会走 Queue 的指数退避
        -- （真睡 1s+2s），把"点一下"拖成 3 秒，还会盖掉我们要验的弹层时序。
        local function stubDeepSeekOk()
            netReset(function(url)
                if tostring(url):find("user/balance", 1, true) then
                    return ([[{"is_available":true,"balance_infos":[
{"currency":"CNY","total_balance":"19.73","granted_balance":"5.00","topped_up_balance":"14.73"}]}]]),
                        200, "OK", nil, {}
                end
                return ([[{"choices":[{"message":{"content":"QA 桩回复"}}],
"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}]]),
                    200, "OK", nil, {}
            end)
        end

        local function wtext2(w)
            if type(w) ~= "table" then return "" end
            return tostring(w.text or w.info_text or w.message or "")
        end
        local function findMenuItem(kw)
            local names = {}
            if type(items) ~= "table" then return nil, names end
            for _i, it in ipairs(items) do
                local s = itemText(it)
                if type(s) == "string" then
                    names[#names + 1] = s
                    if has(s, kw) and type(it.callback) == "function" then
                        return { text = s, callback = it.callback }, names
                    end
                end
            end
            return nil, names
        end

        local cases = {
            { n = 1, entry = "测试 DeepSeek 连接", prog = "正在测试连接" },
            { n = 4, entry = "查询账户余额",       prog = "正在查询余额" },
        }
        for _c, c in ipairs(cases) do
            local n = c.n
            local it, names = findMenuItem(c.entry)
            ok(type(it) == "table",
                string.format("C14-%dP：（前置）主菜单里找得到「%s」入口", n, c.entry),
                type(it) == "table" and it.text or ("菜单项：" .. table.concat(names, " | ")))
            if type(it) == "table" then
                stubDeepSeekOk()
                uiReset()
                local okc, errc = pcall(it.callback)
                ok(okc, string.format("C14-%dP2：（前置）点「%s」不抛异常"
                    .. "（抛了说明这条链路本来就跑不通，后面几条无意义）", n, c.entry), errc)

                -- 进度提示 = show 事件里文案含"正在…"的那一个；结果 = 最后一个不是它的 show。
                -- 不用 UI_SHOWN[1] 这种位置假设：一旦有人在中间插一个弹层，位置假设就废了。
                local shown_log = {}
                local progress, result, i_show_res = nil, nil, nil
                for _i, ev in ipairs(UI_EVENTS) do
                    if ev.op == "show" and type(ev.w) == "table" then
                        shown_log[#shown_log + 1] = Util.utf8sub(wtext2(ev.w), 24)
                        if (not progress) and has(wtext2(ev.w), c.prog) then
                            progress = ev.w
                        elseif ev.w ~= progress then
                            result, i_show_res = ev.w, _i
                        end
                    end
                end
                ok(type(progress) == "table" and type(result) == "table" and progress ~= result,
                    string.format("C14-%dC：（对照）进度提示与结果弹窗是**两个不同的**弹层"
                        .. "（同一个的话，下面三条都是自言自语）", n),
                    string.format("progress=%q result=%q 事件流=%s",
                        Util.utf8sub(wtext2(progress), 40), Util.utf8sub(wtext2(result), 40),
                        table.concat(shown_log, " -> ")))

                local tp = (type(progress) == "table") and progress.timeout or nil
                ok(type(progress) == "table" and (tp == nil or tp == 0),
                    string.format("C14-%d：进度提示**不带 timeout**（nil/0 才算不带；"
                        .. "这里是 Queue 异步真请求，1 秒自己消失 = 用户干等）", n),
                    "timeout=" .. tostring(tp) .. " text=" .. Util.utf8sub(wtext2(progress), 40))

                local i_close = nil
                for _i, ev in ipairs(UI_EVENTS) do
                    if ev.op == "close" and ev.w == progress and not i_close then i_close = _i end
                end
                ok(i_close ~= nil,
                    string.format("C14-%d：（前置）进度提示**真的被 close 过**", n + 1),
                    "events=" .. #UI_EVENTS .. " close(进度)=" .. tostring(i_close))
                -- 同 C13④：把"有没有 close"并进判据，不许"没 close 就悄悄不跑"
                ok(i_close ~= nil and i_show_res ~= nil and i_close < i_show_res,
                    string.format("C14-%d：【顺序】close(进度) 早于 show(结果)"
                        .. "（先关再弹，不许两个并排挂着）", n + 2),
                    string.format("close(进度)=%s show(结果)=%s 事件流=%s",
                        tostring(i_close), tostring(i_show_res),
                        (function()
                            local t = {}
                            for _j, ev in ipairs(UI_EVENTS) do
                                t[#t + 1] = ev.op .. ":" .. Util.utf8sub(wtext2(ev.w), 12)
                            end
                            return table.concat(t, " -> ")
                        end)()))

                -- 人设：进度文案要带 PERSONA_NAME（不许退回中性措辞）。
                -- 对照组：结果文案**不含**人设名——结果是一份事实报告，不是拟人旁白。
                -- 注意对照组只能断言"含/不含"，不能断言"等于某个字面量"：
                -- queryBalance 的结果是 SettingsUI.formatBalance(res) 现算出来的。
                ok(type(PERSONA) == "string" and PERSONA ~= ""
                    and type(progress) == "table" and has(wtext2(progress), PERSONA),
                    string.format("C14-%dR：【人设】进度文案里带「%s」", n, tostring(PERSONA)),
                    "text=" .. Util.utf8sub(wtext2(progress), 50))
                ok(type(PERSONA) == "string" and PERSONA ~= ""
                    and type(result) == "table" and not has(wtext2(result), PERSONA),
                    string.format("C14-%dR2：（对照）结果文案**不含**「%s」", n, tostring(PERSONA)),
                    "text=" .. Util.utf8sub(wtext2(result), 60))
            end
        end
    end
end
-- ======================================================================
-- D. 全局护栏（回归）
-- ======================================================================
local FROZEN = {
    ["ui/suggestpicker.lua"] = "f83eae6d3b3c241dd75d60ac566c56a9",
    ["ui/asker.lua"]         = "e579bf5ef08660d828c5426127130be2",
    ["ui/chatdialog.lua"]    = "00203f5ce1df29ef3777629956aace73",
    ["ui/toastcard.lua"]     = "228cdbf7b80a3df5cb472503c37bd847",
}

local function secD()
    section("D. 全局护栏（防止这轮把既有功能弄坏）")

    -- D1 冻结文件 md5
    for _i, rel in ipairs({ "ui/suggestpicker.lua", "ui/asker.lua", "ui/chatdialog.lua",
        "ui/toastcard.lua" }) do
        local got = md5_of(PLUGIN_DIR .. "/" .. rel)
        ok(got == FROZEN[rel],
            "D1-" .. rel .. "：md5 未被改动（冻结文件）",
            "got=" .. tostring(got) .. " want=" .. tostring(FROZEN[rel]))
    end

    -- D2 出网必须走 HttpClient，不许裸 wget/curl
    do
        local all = nil
        do
            local f = io.popen("cd '" .. PLUGIN_DIR .. "' && find . -name '*.lua' | sort")
            if f then all = f:read("*a"); f:close() end
        end
        local files = {}
        for line in tostring(all):gmatch("([^\n]+)") do
            files[#files + 1] = line:gsub("^%./", "")
        end
        ok(#files > 5,
            "D2：（前置）扫到了插件下的 .lua 文件（" .. #files .. " 个）", nil)

        local wget_hits, http_hits = {}, {}
        for _i, rel in ipairs(files) do
            local src = readFile(PLUGIN_DIR .. "/" .. rel) or ""
            for _j, ln in ipairs(codeLines(src)) do
                if ln.code then
                    local line = ln.text
                    if (has(line, "os.execute") or has(line, "io.popen"))
                        and (has(line, "wget") or has(line, "curl")) then
                        wget_hits[#wget_hits + 1] = rel .. ":" .. line
                    end
                    if has(line, "HttpClient.post") or has(line, "HttpClient.get") then
                        http_hits[#http_hits + 1] = rel
                    end
                end
            end
        end
        ok(#wget_hits == 0,
            "D2①：源码里没有 os.execute/io.popen 裸调 wget|curl（出网必须走 HttpClient，PRD F8.6）",
            #wget_hits > 0 and table.concat(wget_hits, " ;; ") or nil)
        -- 对照组：HttpClient 的调用点确实存在（否则 D2① 是空扫描）
        local uniq_h, seen_h = {}, {}
        for _i, h in ipairs(http_hits) do
            if not seen_h[h] then seen_h[h] = true; uniq_h[#uniq_h + 1] = h end
        end
        ok(#uniq_h > 0,
            "D2②：（对照）确实存在 HttpClient 的调用点（证明 D2① 不是空扫描）",
            table.concat(uniq_h, ","))
    end

    -- D3 防剧透管道单点仍是 DeepSeek:chat
    do
        local ds = readFile(PLUGIN_DIR .. "/ywbf/deepseek.lua") or ""
        ok(has(ds, "HttpClient.post"),
            "D3①：（对照）deepseek.lua 里确有 HttpClient.post 调用点（证明扫描器是好的）", nil)
        ok(has(ds, "Spoiler.guardMessages") or has(ds, "Spoiler:guardMessages"),
            "D3②：deepseek.lua 仍在发请求前调用 Spoiler.guardMessages（管道第 1 道没被拆）", nil)
        ok(has(ds, "Spoiler.sanitizeAnswer") or has(ds, "Spoiler:sanitizeAnswer"),
            "D3③：deepseek.lua 仍在收响应后调用 Spoiler.sanitizeAnswer（管道第 2 道没被拆）", nil)

        -- 行为级：真调一次 chat，必须且只能产生一次 HttpClient.post，打到 DeepSeek 端点
        netReset(function()
            return json.encode({
                choices = { { message = { content = "（QA 桩回复）" }, finish_reason = "stop" } },
                usage = { prompt_tokens = 1, completion_tokens = 1, total_tokens = 2 },
            }), 200, "OK", nil, {}
        end)
        local okc, res, err = pcall(function()
            return DeepSeek:chat({ { role = "user", content = "问题" } }, { max_tokens = 64 })
        end)
        ok(okc and type(res) == "table" and type(res.content) == "string",
            "D3④：DeepSeek:chat 仍然可用（这轮没把它改坏）", okc and tostring(err) or tostring(res))
        local posts = {}
        for _i, c in ipairs(NET.calls) do
            if c.method == "POST" then posts[#posts + 1] = c.url end
        end
        ok(#posts == 1 and posts[1] == DeepSeek.ENDPOINT,
            "D3⑤：【行为】chat 只发了 1 次 POST 且打到 DeepSeek 端点（没有旁路）",
            table.concat(posts, ","))
        netReset(nil)
    end

    -- D4 外挂回归脚本
    if not DO_REGRESSION then
        note("D4", "YWBF_OTA_REGRESSION=0，跳过外挂回归（变异跑常用这个开关）")
        return
    end

    local function readAll(path)
        local f = io.open(path, "rb")
        if not f then return nil end
        local s = f:read("*a")
        f:close()
        return s
    end
    local function runChild(script, env, outfile)
        local cmd = string.format(
            "cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs %s "
            .. "./luajit %s > %s 2>&1; echo rc=$? >> %s",
            env, script, outfile, outfile)
        os.execute(cmd)
        return readAll(outfile) or ""
    end

    do
        local out = TEST_DIR .. "/reg_run_tests.txt"
        local env = string.format("YWBF_PLUGIN_DIR='%s' YWBF_TEST_DIR=/mnt/us/ywbf_dev/ota_reg_testdata",
            PLUGIN_DIR)
        local txt = runChild(TESTS_DIR .. "/run_tests.lua", env, out)
        local p, f = txt:match("RESULTS:%s*(%d+)%s*passed,%s*(%d+)%s*failed")
        p, f = tonumber(p), tonumber(f)
        ok(f == 0,
            "D4①：tests/run_tests.lua 全绿（基线 626/0）",
            "passed=" .. tostring(p) .. " failed=" .. tostring(f))
        ok(type(p) == "number" and p >= 626,
            "D4②：run_tests 的通过数不少于基线 626（少了就是被删了用例）",
            "passed=" .. tostring(p))
    end
    do
        local out = TEST_DIR .. "/reg_eng.txt"
        local env = string.format("YWBF_PLUGIN_DIR='%s' YWBF_TEST_DIR=/mnt/us/ywbf_dev/ota_reg_eng",
            PLUGIN_DIR)
        local txt = runChild(TOOLS_DIR .. "/eng_check_favorites.lua", env, out)
        local p, f = txt:match("合计%s*(%d+)%s*通过%s*/%s*(%d+)%s*失败")
        p, f = tonumber(p), tonumber(f)
        ok(f == 0 and p == 267,
            "D4③：tools/eng_check_favorites.lua 保持 267/0",
            "passed=" .. tostring(p) .. " failed=" .. tostring(f))
    end
    do
        local out = TEST_DIR .. "/reg_fav.txt"
        local env = string.format("YWBF_PLUGIN_DIR='%s' YWBF_FAV_DIR=/mnt/us/ywbf_dev/ota_reg_fav",
            PLUGIN_DIR)
        local txt = runChild(TOOLS_DIR .. "/qa_verify_favorites.lua", env, out)
        local t, p, f, s = txt:match(
            "TOTAL:%s*(%d+)%s+PASSED:%s*(%d+)%s+FAILED:%s*(%d+)%s+SKIPPED:%s*(%d+)")
        t, p, f, s = tonumber(t), tonumber(p), tonumber(f), tonumber(s)
        ok(f == 0 and p == 120 and t == 120,
            "D4④：tools/qa_verify_favorites.lua 保持 120/120/0",
            string.format("T=%s P=%s F=%s S=%s", tostring(t), tostring(p), tostring(f), tostring(s)))
    end
    do
        local out = TEST_DIR .. "/reg_p2.txt"
        local env = string.format("YWBF_PLUGIN_DIR='%s' YWBF_P2_DIR=/mnt/us/ywbf_dev/ota_reg_p2",
            PLUGIN_DIR)
        local txt = runChild(TOOLS_DIR .. "/qa_verify_phase2.lua", env, out)
        local t, p, f, s, x = txt:match(
            "TOTAL:%s*(%d+)%s+PASSED:%s*(%d+)%s+FAILED:%s*(%d+)%s+SKIPPED:%s*(%d+)%s+EXEMPT:%s*(%d+)")
        t, p, f, s, x = tonumber(t), tonumber(p), tonumber(f), tonumber(s), tonumber(x)
        ok(f == 0 and p == 124 and t == 124 and x == 1,
            "D4⑤：tools/qa_verify_phase2.lua 保持 124/124/0/1 EXEMPT",
            string.format("T=%s P=%s F=%s S=%s E=%s",
                tostring(t), tostring(p), tostring(f), tostring(s), tostring(x)))
    end
end

-- ======================================================================
-- 收尾
-- ======================================================================
print("")
print(string.format("[LOCK] 本次审计的插件目录：%s", PLUGIN_DIR))
do
    for _i, rel in ipairs({ "ywbf/ota.lua", "ywbf/config.lua", "ui/settings.lua", "_meta.lua",
        "ywbf/httpclient.lua", "main.lua" }) do
        print(string.format("[LOCK] md5 %-22s %s", rel, tostring(md5_of(PLUGIN_DIR .. "/" .. rel))))
    end
end

local ok_run, run_err = pcall(secA)
if not ok_run then
    ok(false, "A 段整体抛异常", run_err)
end
ok_run, run_err = pcall(secB1)
if not ok_run then ok(false, "B1 段整体抛异常", run_err) end
ok_run, run_err = pcall(secB2)
if not ok_run then ok(false, "B2 段整体抛异常", run_err) end
ok_run, run_err = pcall(secB2b)
if not ok_run then ok(false, "B2' 段整体抛异常", run_err) end
ok_run, run_err = pcall(secB3)
if not ok_run then ok(false, "B3 段整体抛异常", run_err) end
ok_run, run_err = pcall(secC)
if not ok_run then ok(false, "C 段整体抛异常", run_err) end
ok_run, run_err = pcall(secD)
if not ok_run then ok(false, "D 段整体抛异常", run_err) end

-- 配置还原：放在所有 pcall 之外，保证异常路径也会执行
restoreSettings()

print("")
print(string.format("TOTAL: %d  PASSED: %d  FAILED: %d  SKIPPED: %d  EXEMPT: %d",
    TOTAL, PASSED, FAILED, SKIPPED, EXEMPT))
if FAILED > 0 then
    print("失败清单：")
    for _i, n in ipairs(FAILED_NAMES) do print("  - " .. n) end
end
print("（插件目录 " .. PLUGIN_DIR .. "；测试目录 " .. TEST_DIR .. "，临时文件全在 ywbf_dev 内）")
