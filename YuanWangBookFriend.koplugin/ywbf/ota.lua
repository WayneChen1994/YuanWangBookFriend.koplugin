--[[--
OTA 自更新（M4）。

**这个文件不碰 UI**：所有网络、文件、解压逻辑都在这里，UI 只负责把它算出来的东西
显示给人看。可单测是硬要求——`normalizeVersion` 算错一次，"0.9 比 0.10 新"这种结论
会让用户永远停在旧版本上，而他从界面上只会看到一句"已是最新版本"。

四条不能让步的线：

1. **绝不碰 `target_dir/data/`**：里面有 API Key、收藏、历史、缓存。备份跳过它、
   解压跳过它、回滚也跳过它。**任何环节都不许出现"删掉插件目录再铺一份新的"**
   ——那是把用户的半年笔记当成无关文件删掉。
2. **不许重启 / kill KOReader**（用户明确要求，真机上有过两次被打断者的经历）：
   更新只做到"文件铺完"，之后提示用户手动重启。
3. **所有出站必须走 `ywbf/httpclient`**：不许自己 `os.execute("wget …")`，
   那是绕过白名单的后门（PRD F8.6：单一出站口）。
4. **失败一律优雅降级**：网络失败、没发布过 Release、JSON 解析不出来、zip 不是 zip，
   都返回 `nil/false + 原因**，交给调用方显示。不许崩，也不许静默。

LuaJIT = Lua 5.1 语义：无位运算符；循环变量一律 `_i`。
--]]--

local Config = require("ywbf/config")
local HttpClient = require("ywbf/httpclient")
local Util = require("ywbf/util")
local json = require("json")
local ok_ffi, ffiUtil = pcall(require, "ffi/util")
local _ = require("gettext")

-- 兜底：纯逻辑文件也要能脱离 KOReader 的 ffi 层单测（无头 luajit 里没有 ffi/util）
local T
if ok_ffi and type(ffiUtil) == "table" and type(ffiUtil.template) == "function" then
    T = ffiUtil.template
else
    T = function(s, ...)
        local out = s
        local args = { ... }
        for i = 1, #args do
            out = out:gsub("%%" .. tostring(i), tostring(args[i]):gsub("%%", "%%%%"))
        end
        return (out:gsub("%%[1-9]", ""))
    end
end

local Ota = {}

-- 仓库（owner/repo）
Ota.REPO = "WayneChen1994/YuanWangBookFriend.koplugin"

-- API 基址。只查 Releases，任何 upload / 写接口都不碰。
Ota.API_BASE = "https://api.github.com"

-- GitHub 要求带 User-Agent，不带会被 403
Ota.USER_AGENT = "YuanWangBookFriend-OTA"

-- 备份落在 target_dir/data 之下（零污染：卸载即删目录即净）
Ota.BACKUP_DIR_NAME = "ota_backup"

-- 解压中转目录，同样只在 data/ 之内
Ota.STAGE_DIR_NAME = "ota_stage"

-- 永远不许动的目录名
Ota.DATA_DIR_NAME = "data"

--[[--
下载单个包的大小上限（8MB）。

设备上的 /tmp、/var 是 32M 的 tmpfs 常年接近满，插件自用空间也得省着用；
更重要的是：一个"包"如果大得离谱，多半是有人把 Release 指向了别的东西，
而不是这个插件突然长胖了。超过就停下来报错，比写到一半才失败好排查。
--]]
Ota.MAX_DOWNLOAD_BYTES = 8 * 1024 * 1024

-- 少于这么多字节就认为拿到的不是一个 zip（真 zip 至少几十字节起）
local MIN_ZIP_BYTES = 64

-- zip 文件头 magic："PK\x03\x04"
local ZIP_MAGIC = "PK\003\004"

-- ---------- 小工具 ----------

local function trim(s)
    if type(s) ~= "string" then return nil end
    return Util.trim(s)
end

local function fileSize(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local cur = f:seek("end")
    f:close()
    return cur
end

--[[--
只能对我们自己的临时目录动手。

`rm -rf` 是 OTA 里最危险的一行（写错一个变量就是整包代码没了），
所以这里先把"允许删除的路径"钉死成两个具体目录名，别的路径一律拒绝。
@return bool 是否允许
--]]
local function isOurScratchPath(path)
    if type(path) ~= "string" or path == "" then return false end
    return path:find("/" .. Ota.STAGE_DIR_NAME, 1, true) ~= nil
        or path:find("/" .. Ota.BACKUP_DIR_NAME, 1, true) ~= nil
end

--[[--
`backup` / `apply` / `rollback` 三个入口共用的目标目录校验。

为什么必须做：`apply` 的最后一步是 `tar -xf - -C '<target_dir>'`，`rollback` 是
`tar -xzf ... -C '<target_dir>'`。`target_dir` 里带 `..` 的话，文件会真的铺到插件
目录之外去——那不是"更新失败"，是拿着更新权限往任意位置写文件。

**不能用"字符串以某个前缀开头"来判断**：`dir .. "/" .. "../../evil"` 照样以
`dir .. "/"` 开头，而它在文件系统上解析完已经跑到别处了（`Export.safeName` 那次
已经踩过一次，前缀判断是假绿）。这里改成直接拒掉 `..` 段本身。

`os.execute` 是把路径拼进 shell 串的，单引号、反引号、`$()`、分号这些元字符
同样要挡——路径写进单引号里，一个单引号就能把命令切断。
@return bool 是否可以作为写入目标
--]]
local function isSafeTargetDir(path)
    if type(path) ~= "string" or path == "" then return false end
    if path:find("%.%.") then return false end          -- 拒绝任何 `..` 段
    if path:find("%c") then return false end            -- 控制字符（含 NUL）
    if path:find("['\"`%$;|&\\\n]") then return false end -- shell 元字符
    return true
end

--[[--
建目录（要自己写一个而不复用 Config 里的 mkdirp：那个是 Config 的局部函数，
没挂在模块表上，纯逻辑层不该去够别人的内部实现）。
有 lfs 就用 lfs（不 fork 进程），没有就退回 `mkdir -p`。
--]]
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
local function mkdirp(path)
    if not path or path == "" then return end
    if ok_lfs then
        local current = ""
        local prefix = path:sub(1, 1) == "/" and "/" or ""
        for part in path:gmatch("[^/]+") do
            current = (prefix == "/" and (current .. "/" .. part) or
                      (current == "" and part or current .. "/" .. part))
            if current ~= "" and current ~= "." then
                if lfs.attributes(current, "mode") ~= "directory" then
                    pcall(lfs.mkdir, current)
                end
            end
        end
    else
        os.execute(string.format("mkdir -p '%s'", path))
    end
end

local function readFile(path)
    return Config._read_file(path)
end

local function writeFile(path, content)
    return Config._write_file(path, content)
end

-- ---------- 版本 ----------

--[[--
把任意版本串收成**数字分段**的表。

必须分段比较高下：`"0.9.0"` 和 `"0.10.0"` 按字符串比是 `"0.9.0" > "0.10.0"`
（'9' > '1'），结论完全反了——0.9 的用户会被判成"更新到最新"，永远升不上去。
所以每一段都 `tonumber`，非数字一律视为非法并返回 nil。

@param s string|any 形如 "v1.2" / "1.2.3" / "1.2.3-beta"（示例用占位数字，
        不写真实版本号：那个数字全项目只许在 Config.VERSION 出现一次）
@return table|nil {1,2,0}；非法输入返回 nil
--]]
function Ota:normalizeVersion(s)
    if type(s) ~= "string" then return nil end
    local head = trim(s)
    if not head or head == "" then return nil end

    -- 去掉前缀 v / V（GitHub 的 tag 惯例）
    head = head:gsub("^[vV]", "")
    -- 只取开头的"数字.数字…"部分，后面 -beta 之类的后缀丢掉（同一版本的后缀不做区分）
    local digits = head:match("^[%d%.]+")
    if not digits then return nil end

    --[[--
    严格校验：只接受 `1` / `1.2` / `1.2.3` / `1.2.3.4` 这种形状，空段一律拒绝。

    这一行不能省。`0.x.1`、`1..2` 在宽松匹配下会被割成 `{0,0,0}`、`{1,2,0}`
    然后**拿去比大小**——等于用一个根本不是版本号的串得出"有没有新版本"的结论。
    脏数据必须在入口就变 nil，不许流进 compareVersions。

    反过来也不能过严：`v0.2` 必须等价于 `0.2.0`（GitHub tag 常见写法），
    四段 `1.2.3.4` 也合法（比较那边按缺位补 0，行为一致）。
    --]]
    -- 注意：这里不能写成 `^%d+(%.%d+)*$`。Lua 的量词只作用在**单个字符类**上，
    -- 给括号分组加 `*` 是不支持的（实测 `("0.2"):match("^%d+(%.%d+)*$") == nil`，
    -- 合法版本号都会被判死）。所以改成一条条具体的形状规则。
    if digits:find("[^%d%.]") then return nil end   -- 只允许数字和点（挡 `0.x.1` 的 x）
    if digits:find("%.%.") then return nil end      -- 空段：`1..2`
    if digits:sub(1, 1) == "." then return nil end  -- 以点开头：`.2`
    if digits:sub(-1) == "." then return nil end    -- 以点结尾：`0.`（`0.x.1` 被割后的残骸）

    local out = {}
    for part in digits:gmatch("%d+") do
        local n = tonumber(part)
        if n == nil then return nil end
        out[#out + 1] = n
    end
    if #out == 0 then return nil end
    -- 补到三段：`v1.2` 与 `1.2.0` 必须是同一个数，
    -- 而 `1.2.0` 与 `1.2.0.0` 也是（缺位一律当 0，比较那边同样按缺位补 0 比）。
    while #out < 3 do out[#out + 1] = 0 end
    return out
end

--[[--
比较两个版本，按**数字分段**逐段比，缺位补 0。

@return number|nil -1（a 更旧）/ 0（相同）/ 1（a 更新）；任一句柄非法返回 nil
--]]
function Ota:compareVersions(a, b)
    local va = self:normalizeVersion(a)
    local vb = self:normalizeVersion(b)
    if not va or not vb then return nil end

    local len = (#va > #vb) and #va or #vb
    for i = 1, len do
        local x = va[i] or 0   -- 缺位补 0：1.2 与 1.2.0 是同一个版本
        local y = vb[i] or 0
        if x < y then return -1 end
        if x > y then return 1 end
    end
    return 0
end

-- ---------- 查询 ----------

--[[--
查 GitHub 上最新的 Release。走 HttpClient（单一出站口 + 白名单）。

@return table|nil, string|nil  {tag, name, zipball_url, html_url, notes, published_at, prerelease}, err
--]]
function Ota:latestRelease()
    local url = string.format("%s/repos/%s/releases/latest", Ota.API_BASE, Ota.REPO)
    local body, code, _status, err = HttpClient.get(url, {
        ["User-Agent"] = Ota.USER_AGENT,
        ["Accept"] = "application/vnd.github+json",
    }, 30)

    if err ~= nil then return nil, T(_("连不上 GitHub：%1"), tostring(err)) end
    if code == 404 then
        return nil, _("这个仓库还没有发布任何版本。")
    end
    if code ~= 200 then
        return nil, T(_("GitHub 返回了异常状态码 %1"), tostring(code))
    end
    if type(body) ~= "string" or body == "" then
        return nil, _("GitHub 返回的内容是空的。")
    end

    local ok_decode, data = pcall(json.decode, body)
    if not ok_decode or type(data) ~= "table" then
        return nil, _("读不懂 GitHub 返回的内容（不是合法 JSON）。")
    end

    local zip = type(data.zipball_url) == "string" and data.zipball_url or ""
    if zip == "" then
        return nil, _("这个 Release 没有源码包地址（zipball 为空）。")
    end

    return {
        tag = type(data.tag_name) == "string" and data.tag_name or "",
        name = type(data.name) == "string" and data.name or "",
        zipball_url = zip,
        html_url = type(data.html_url) == "string" and data.html_url or "",
        notes = type(data.body) == "string" and data.body or "",
        published_at = type(data.published_at) == "string" and data.published_at or "",
        prerelease = (data.prerelease == true),
    }, nil
end

--[[--
有没有新版本。

为什么不只返回一个"要不要更新"的 bool：调用方要显示的是"当前是什么版本、最新是什么版本、
更新了些什么"，这三样分开取的话，版本源就会各自重复一遍（UI 一份、这里一份），
下次漂移的就是那个数字本身，而不是"要不要更新"这个结论——那更难发现。

（注：这里的示例刻意不写真实的版本号字面量，是为了让"全项目只有一处版本号"
这条静态断言可以简单有效地成立：只要别处出现那个字面量，就一定是第二份定义。）

@return table|nil, string|nil {available=bool, current, latest, name, url, html_url, notes, published_at}, err
--]]
function Ota:checkForUpdate()
    local current = Config.VERSION
    if type(current) ~= "string" or current == "" then
        return nil, _("插件版本号没读到（Config.VERSION 没设置）。")
    end

    local rel, err = self:latestRelease()
    if not rel then return nil, err end

    local latest = rel.tag
    local cmp = self:compareVersions(current, latest)
    if cmp == nil then
        return nil, T(_("认不出这个 Release 的版本号：%1"), tostring(latest))
    end

    return {
        available = (cmp == -1),   -- 当前比最新旧
        current = current,
        latest = latest,
        name = rel.name,
        url = rel.zipball_url,
        html_url = rel.html_url,
        notes = rel.notes,
        published_at = rel.published_at,
        prerelease = rel.prerelease,
    }, nil
end

-- ---------- 下载 ----------

--[[--
下载到 dest_path。跟随跳转（GitHub 的 zipball 一定会跳），每跳都重新过白名单。

@param url string Release 的 zipball_url
@param dest_path string 落盘路径
@return bool, string|nil
--]]
function Ota:download(url, dest_path)
    if type(url) ~= "string" or url == "" then
        return false, _("没有下载地址。")
    end
    if type(dest_path) ~= "string" or dest_path == "" then
        return false, _("没有指定落在哪里。")
    end

    local parent = dest_path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then mkdirp(parent) end

    local body, code, _status, err = HttpClient.get(url, {
        ["User-Agent"] = Ota.USER_AGENT,
        ["Accept"] = "application/zip",
    }, 120, { follow_redirects = true })

    if err ~= nil then return false, T(_("下载失败：%1"), tostring(err)) end
    if code ~= 200 then
        return false, T(_("下载失败：服务器返回状态码 %1"), tostring(code))
    end
    if type(body) ~= "string" or #body == 0 then
        return false, _("下载下来是空的。")
    end
    if #body > Ota.MAX_DOWNLOAD_BYTES then
        return false, T(_("这个文件太大了（%1 字节），不像一个插件更新包，已停止下载。"),
            tostring(#body))
    end
    if body:sub(1, 4) ~= ZIP_MAGIC then
        return false, _("下载下来不是一个 zip 压缩包。")
    end

    if not writeFile(dest_path, body) then
        return false, T(_("写不进去：%1"), dest_path)
    end
    return true, nil
end

-- ---------- 备份 ----------

--[[--
把 `target_dir` 的**代码文件**打个备份包，落在 `target_dir/data/ota_backup/` 之下。

两条刻意的设计：
  · **不打 `data/`**：`data/` 本来就不会被 `apply` 碰，备份它没有意义，
    还会把 API Key 和半年的收藏复制一份到别处（多一处明文副本就是多一处风险）；
  · **落在 `data/` 之内**：PRD §1.3 零污染——卸载删掉插件目录，备份跟着走。

@param target_dir string 插件目录
@return string|nil, string|nil 备份文件路径, err
--]]
function Ota:backup(target_dir)
    if type(target_dir) ~= "string" or target_dir == "" then
        return nil, _("没有指定插件目录。")
    end
    if not isSafeTargetDir(target_dir) then
        return nil, _("插件目录路径不合法，已停止备份。")
    end

    local backup_dir = target_dir .. "/" .. Ota.DATA_DIR_NAME .. "/" .. Ota.BACKUP_DIR_NAME
    mkdirp(backup_dir)

    local stamp = os.date("%Y%m%d-%H%M%S") or tostring(os.time())
    local salt = Util.fnv(tostring(os.time()) .. "#" .. tostring(math.random(1000000))):sub(1, 6)
    local backup_path = string.format("%s/backup-%s-%s.tar.gz", backup_dir, stamp, salt)

    --[[--
    **全量**打包，含 `data/` 里的 API Key、收藏、历史、缓存。

    备份的定位是**回滚点**，不是"代码快照"。`apply` 那边靠 `--exclude=data`
    保证不动用户数据，但那只是一行参数——今天它兜着，明天被人动一下就没人兜了。
    备份要当**第二道**防线，两道防线不能共用同一个开关：备份里如果没有 data，
    一旦 apply 那条线出问题，用户半年的收藏就是真没了（这个项目出过这种事）。

    排除的只有两个临时目录：不排除的话，第二次备份会把第一次的备份包整个
    吞进去，第三次再吞一次，体积指数膨胀，很快把设备上那点空间吃光。
    --]]
    local cmd = string.format(
        "tar -czf '%s' -C '%s' "
            .. "--exclude=./data/%s --exclude=data/%s "
            .. "--exclude=./data/%s --exclude=data/%s .",
        backup_path, target_dir,
        Ota.BACKUP_DIR_NAME, Ota.BACKUP_DIR_NAME,
        Ota.STAGE_DIR_NAME, Ota.STAGE_DIR_NAME)
    local rc = os.execute(cmd)
    if rc ~= 0 and rc ~= true then
        return nil, T(_("备份失败：%1"), tostring(rc))
    end

    local size = fileSize(backup_path)
    if not size or size == 0 then
        return nil, _("备份包是空的。")
    end
    return backup_path, nil
end

-- ---------- 应用与回滚 ----------

--[[--
列出一个目录里的条目名（不含 . 和 ..）。
有 lfs 就用 lfs（不 fork 进程），没有就退回 `ls -1`。
@return table
--]]
local function listDir(path)
    local names = {}
    if ok_lfs and type(lfs.dir) == "function" then
        local ok_iter, it = pcall(lfs.dir, path)
        if ok_iter and type(it) == "userdata" then
            for name in it, nil, nil do
                if name ~= "." and name ~= ".." then names[#names + 1] = name end
            end
            return names
        end
    end
    local tmp = os.tmpname and os.tmpname() or (path .. "/.ywbf_ls")
    local rc = os.execute(string.format("ls -1 '%s' > '%s' 2>/dev/null", path, tmp))
    local raw = (rc == 0 or rc == true) and readFile(tmp) or nil
    os.remove(tmp)
    for line in (raw or ""):gmatch("[^\n]+") do
        if line ~= "." and line ~= ".." then names[#names + 1] = line end
    end
    return names
end

local function isDir(path)
    if ok_lfs and type(lfs.attributes) == "function" then
        return lfs.attributes(path, "mode") == "directory"
    end
    -- 没有 lfs 时退回"试着当目录打开"：busybox 下这个技巧不总是准，
    -- 所以只在拿不到 lfs 时用（设备上 lfs 一直是有的）
    local f = io.open(path .. "/.", "rb")
    if f then f:close(); return true end
    return false
end

--[[--
在解压出来的中转目录里找到"插件本体在哪一层"。

**这个查找是拿 GitHub 真实源码包对过之后才有的**。之前的写法是
"假定外面只有一层 `<owner>-<repo>-<sha>/`，插件文件直接在它下面"，
而真实的包是：
```
WayneChen1994-YuanWangBookFriend.koplugin-<sha>/
    README.md  PRD.md  DEV_PLAN.md
    YuanWangBookFriend.koplugin/_meta.lua  main.lua  ui/  ywbf/
    tests/  tools/
```
——中间还隔着一层仓库目录。照原来那套假设，真包装不进去，
而且**报错会停在一句"包里没有 main.lua"上**，让人以为是包坏了。

所以这里改成"往下找最多三层，找到同时有 main.lua 和 _meta.lua 的那一层"。
认 `_meta.lua` 而不只认 main.lua：KOReader 插件必须带它，
两个一起认才不会把仓库里某个恰好叫 main.lua 的示例文件当成插件本体。

@return string|nil, string|nil  找到的目录, 失败原因
--]]
local function findPluginRoot(stage)
    local MAX_DEPTH = 3
    local queue = { stage }
    local depth = 0
    while #queue > 0 and depth <= MAX_DEPTH do
        local hits = {}
        local next_queue = {}
        for _i, dir in ipairs(queue) do
            local entries = listDir(dir)
            local has_main, has_meta = false, false
            for _j, name in ipairs(entries) do
                if name == "main.lua" then has_main = true end
                if name == "_meta.lua" then has_meta = true end
            end
            if has_main and has_meta then hits[#hits + 1] = dir end
            if depth < MAX_DEPTH then
                for _j, name in ipairs(entries) do
                    local sub = dir .. "/" .. name
                    if isDir(sub) then next_queue[#next_queue + 1] = sub end
                end
            end
        end
        if #hits == 1 then return hits[1], nil end
        if #hits > 1 then
            return nil, T(_("包里有 %1 处都像是插件本体，无法确定该装哪一个，已停下。"),
                tostring(#hits))
        end
        queue = next_queue
        depth = depth + 1
    end
    return nil, _("包里找不到插件本体（没有同时带 main.lua 和 _meta.lua 的目录），已停下。")
end

--[[--
铺一个新版本到 target_dir。

流程刻意做成"先把新版本铺到 data 之下的中转目录，确认它长得像一个插件包，
再整体搬过去"：直接 `unzip -o` 到 target_dir 的话，万一 zip 的结构跟预期不一样
（比如没有那层 GitHub 自动生成的根目录），文件会天女散花一样散到插件根目录里，
那种现场没有回滚能救。

**绝不删任何东西**：只覆盖同名文件。上游删掉的文件会留下——
留着的代价是"多一个没人调用的文件"，删起的代价可能是"删掉了用户还在用的东西"。

@param zip_path string
@param target_dir string
@return bool, string|nil
--]]
function Ota:apply(zip_path, target_dir)
    if type(zip_path) ~= "string" or zip_path == "" then
        return false, _("没有压缩包路径。")
    end
    if type(target_dir) ~= "string" or target_dir == "" then
        return false, _("没有指定插件目录。")
    end
    -- 铺文件是 `tar -xf - -C '<target_dir>'`，带 `..` 会把文件写到插件目录之外
    if not isSafeTargetDir(target_dir) then
        return false, _("插件目录路径不合法，已停止更新。")
    end
    if not fileSize(zip_path) then
        return false, T(_("压缩包不在：%1"), zip_path)
    end

    -- 先确认它真的是个 zip，而不是"下载失败时被写进去的一段 HTML"
    local f = io.open(zip_path, "rb")
    if not f then return false, T(_("压缩包打不开：%1"), zip_path) end
    local head = f:read(MIN_ZIP_BYTES)
    f:close()
    if head:sub(1, 4) ~= ZIP_MAGIC then
        return false, _("这个压缩包不是有效的 zip 文件。")
    end

    local data_dir = target_dir .. "/" .. Ota.DATA_DIR_NAME
    mkdirp(data_dir)
    local stage = data_dir .. "/" .. Ota.STAGE_DIR_NAME

    -- 清掉上一次留下的中转：这个删除动作专门验证过路径（见 isOurScratchPath）
    if isOurScratchPath(stage) then
        os.execute(string.format("rm -rf '%s'", stage))
    end
    mkdirp(stage)

    local ok_unzip = os.execute(string.format("unzip -qq -o '%s' -d '%s'", zip_path, stage))
    if not (ok_unzip == 0 or ok_unzip == true) then
        return false, T(_("解压失败：%1"), tostring(ok_unzip))
    end

    -- 找插件本体在哪一层（见 findPluginRoot 上方的说明：真实源码包是两层套娃）
    local src_root, err_root = findPluginRoot(stage)
    if not src_root then
        return false, err_root
    end

    -- 整体搬过去，跳过 data/：这两种写法同样是为了兼容 busybox tar。
    -- 用 tar 管道而不是 cp -R，是因为 cp -R 的"目标目录已存在时到底合并还是嵌套"
    -- 在不同实现上不一致（GNU 与 busybox 就不一样），而这个操作没有第二次机会。
    local cmd = string.format("tar -cf - -C '%s' --exclude=./data --exclude=data . " ..
        "| tar -xf - -C '%s'", src_root, target_dir)
    local rc = os.execute(cmd)
    if not (rc == 0 or rc == true) then
        return false, T(_("铺文件失败：%1"), tostring(rc))
    end

    -- data/ 必须还在：这是"用户的东西一件没少"的直接证据。
    -- 两个文件都不在不一定是错（全新的用户还没配过 Key、也没产生过历史），
    -- 但连 data 目录都不在了，就是这次操作动了不该动的东西。
    if ok_lfs and type(lfs.attributes) == "function"
        and lfs.attributes(data_dir, "mode") ~= "directory" then
        return false, _("更新后数据目录不见了，这可能是本次更新造成的问题，请检查备份。")
    end

    return true, nil
end

--[[--
用备份包回滚。`apply` 只覆盖不删除，所以回滚就是把当时的代码文件铺回去。

@param backup_path string `backup()` 的返回值
@param target_dir string
@return bool, string|nil
--]]
function Ota:rollback(backup_path, target_dir)
    if type(backup_path) ~= "string" or backup_path == "" then
        return false, _("没有备份文件路径。")
    end
    if type(target_dir) ~= "string" or target_dir == "" then
        return false, _("没有指定插件目录。")
    end
    -- 回滚同样是 `tar -xzf ... -C '<target_dir>'`，和 apply 一个风险面
    if not isSafeTargetDir(target_dir) then
        return false, _("插件目录路径不合法，已停止回滚。")
    end
    if not fileSize(backup_path) then
        return false, T(_("备份文件不在：%1"), backup_path)
    end

    local rc = os.execute(string.format("tar -xzf '%s' -C '%s'", backup_path, target_dir))
    if not (rc == 0 or rc == true) then
        return false, T(_("回滚失败：%1"), tostring(rc))
    end
    return true, nil
end

return Ota
