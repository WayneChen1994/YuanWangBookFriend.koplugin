--[==[
QA 独立探针：`Export:write` 的 **opts.name 输入校验**（safeName）到底挡住了什么。

只测**落点**，不测字符串形状：越界写是文件系统解析之后才发生的，
`path:sub(1, #dir+1) == dir.."/"` 这种前缀比较看不出来（`dir .. "/" .. "../../x.md"`
照样以 `dir.."/"` 开头）—— 这条坑 team-lead 自己的第一版就栽过。

判定方式：
  · 返回了路径 -> 路径必须**解析后在导出目录之内**（去掉目录前缀后不许再含 / \ ..），
    并且那个文件必须真的存在（真落盘，不是画了个路径）；
  · 返回了 nil -> 明确拒绝，可以接受（调用方退回默认名）；
  · **绝不允许**的是"成功返回了路径、但路径越界"。
另外扫一遍导出目录的父目录/祖父目录，确认逃逸文件没有真的落在那里。

在 KPW4 上：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     YWBF_PLUGIN_DIR=/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin \
     YWBF_SN_DIR=/mnt/us/ywbf_dev/p2_safename \
     ./luajit /mnt/us/ywbf_dev/tools/qa_probe_safename.lua
--]==]

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR")
    or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"
local TEST_DIR = os.getenv("YWBF_SN_DIR") or "/mnt/us/ywbf_dev/p2_safename"

io.stdout:setvbuf("line")

if type(TEST_DIR) == "string" and TEST_DIR:find("ywbf_dev", 1, true) and #TEST_DIR > 12 then
    os.execute("rm -rf " .. TEST_DIR)
end

-- 变异轮留下的残留会污染"没有逃逸文件"这条判定。
-- 拆掉护栏时，`../../../evil_probe.md` 这类名字会真的写到 TEST_DIR **之上**
-- （就是 /mnt/us/ywbf_dev/ 里），而 `rm -rf TEST_DIR` 清不到那里；
-- 护栏修好之后再跑，那条陈旧文件会让"没有逃逸"永远红下去，看着像交付代码漏了，
-- 其实是上一轮变异自己拉的屎。所以开局先把这批已知探针名从开发目录顶层清掉。
-- （这条就是这么发现的：护栏早就修好了，探针却红在一份 15:30 的残留上。）
local PROBE_NAMES = {
    "evil_probe.md", "passwd_probe.md", "win_probe.md", "b_probe.md",
    "dir_probe.md", "spaced_probe.md", "middle_probe.md", "normal_probe.md",
}
if type(TEST_DIR) == "string" and TEST_DIR:find("ywbf_dev", 1, true) then
    local dev_root = TEST_DIR:match("^(/mnt/us/ywbf_dev)")
    if dev_root then
        for _i, n in ipairs(PROBE_NAMES) do
            os.execute(string.format("rm -f '%s/%s'", dev_root, n))
        end
    end
end

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")
package.loaded["gettext"] = setmetatable({}, { __call = function(_s, s) return s end })
package.loaded["logger"] = {
    info = function() end, warn = function() end,
    dbg = function() end, err = function() end,
    levels = { dbg = 1, info = 2, warn = 3, err = 4 },
}

local Config = require("ywbf/config")
Config:init(TEST_DIR)
local Export = require("ywbf/export")

local TOTAL, PASSED, FAILED = 0, 0, 0
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
local function note(name, extra) print("  NOTE  " .. name .. " -> " .. tostring(extra)) end

local dir = Export:dir()
print("EXPORT-DIR=" .. tostring(dir))
ok(type(dir) == "string" and dir ~= "", "（前置）拿得到导出目录", tostring(dir))

local rows = {
    {
        book_title = "探针书", question = "探针问？", content = "探针答。",
        time_text = "2023-11-14 22:08", style_text = "专业严谨",
        note = "探针备注", tags = { "探针" },
    },
}

local function exists(p)
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
end

-- 落点在目录之内：不是看前缀，是看**去掉目录前缀之后那一段**还干不干净
local function insideDir(p)
    if type(p) ~= "string" or type(dir) ~= "string" then return false end
    if p:sub(1, #dir + 1) ~= (dir .. "/") then return false end
    local rest = p:sub(#dir + 2)
    if rest == "" then return false end
    if rest:find("%.%.") then return false end
    if rest:find("/", 1, true) then return false end
    if rest:find("\\", 1, true) then return false end
    return true
end

local cases = {
    { "../../evil_probe.md",       "evil_probe.md", "父目录逃逸" },
    { "../../../evil_probe.md",    "evil_probe.md", "祖父目录逃逸" },
    { "/etc/passwd_probe.md",      "passwd_probe.md", "绝对路径" },
    { "C:\\Windows\\win_probe.md", "win_probe.md", "Windows 反斜杠绝对路径" },
    { "..\\..\\win_probe.md",      "win_probe.md", "Windows 反斜杠父目录" },
    { "a/../b_probe.md",           "b_probe.md", "中间带 .. 的相对路径" },
    { "sub/dir_probe.md",          "dir_probe.md", "带子目录" },
    { "..",                        nil, "只有两个点" },
    { ".",                         nil, "只有一个点" },
    { "....",                      nil, "四个点" },
    { "",                          nil, "空串" },
    { "   ",                       nil, "只有空白" },
    { "  spaced_probe.md  ",       "spaced_probe.md", "两端空白（应被 trim）" },
    { "midd..le_probe.md",         "middle_probe.md", "文件名中间的 ..（应被去掉）" },
    -- NUL 的契约改过：不再"整名判非法退回默认名"，而是**把控制字符清掉后照用**，
    -- 所以期望落点是 probe.md（照用），不是默认名。第一版我按"应被拒"写，是我的断言错了。
    { "probe" .. string.char(0) .. ".md", "probe.md", "含 NUL 字节（清掉后照用）" },
    { string.rep("L", 300) .. ".md", nil, "超长文件名" },
}

print("=== 1. 逐个喂敌意文件名：落点必须在导出目录之内 ===")
for _i, c in ipairs(cases) do
    local name, want, why = c[1], c[2], c[3]
    local okc, p, e = pcall(function() return Export:write(rows, { name = name }) end)
    local tag = string.format("name=%q（%s）", (name:gsub("%z", "<NUL>")), why)
    if not okc then
        ok(false, "1. " .. tag .. " 不该抛异常", tostring(p))
    elseif p == nil then
        -- 明确拒绝：可以接受（退回默认名）
        ok(true, "1. " .. tag .. " 被明确拒绝（返回 nil + 原因）")
        note("  拒绝原因", e)
    else
        ok(insideDir(p), "1. " .. tag .. " 返回的路径解析后仍在导出目录之内", p)
        if type(want) == "string" then
            ok(p == (dir .. "/" .. want),
                "1. " .. tag .. " 落点正好是 " .. dir .. "/" .. want, p)
        else
            -- 非法名字的契约是**退回默认名**（不是返回 nil），所以这里验的是
            -- "没有原样采用我喂进去的那个名字"：用默认名的形状来判定。
            -- 第一版我把这条写成"本该返回 nil"，那是**我的断言写错了**，不是代码错。
            local base = p:sub(#dir + 2)
            ok(base:find("^ywbf%-favorites%-") ~= nil,
                "1. " .. tag .. " 没有原样采用非法名字，退回默认名", base)
        end
        if insideDir(p) then
            ok(exists(p), "1. " .. tag .. " 路径指向的文件真的存在", p)
        end
    end
end

print("=== 2. 落点实证：扫导出目录之外的位置，看有没有逃逸文件真的落下来 ===")
local escapes = {
    "evil_probe.md", "passwd_probe.md", "win_probe.md",
    "b_probe.md", "dir_probe.md", "spaced_probe.md", "middle_probe.md",
}
local stray = {}
for _i, n in ipairs(escapes) do
    local up1 = dir .. "/../" .. n
    local up2 = dir .. "/../../" .. n
    local up3 = dir .. "/../../../" .. n
    if exists(up1) then stray[#stray + 1] = up1 end
    if exists(up2) then stray[#stray + 1] = up2 end
    if exists(up3) then stray[#stray + 1] = up3 end
end
ok(#stray == 0, "2. 导出目录的父/祖父/曾祖父目录里没有出现任何逃逸文件",
    #stray > 0 and table.concat(stray, " | ") or "")

print("=== 3. 对照：正常名字仍然工作（别把护栏修成了一律拒绝） ===")
local ok3, p3 = pcall(function() return Export:write(rows, { name = "normal_probe.md" }) end)
ok(ok3 and p3 == (dir .. "/normal_probe.md"),
    "3. 正常文件名照原样用（护栏没有把合法输入一起挡掉）",
    ok3 and tostring(p3) or tostring(p3))
ok(ok3 and type(p3) == "string" and exists(p3),
    "3. 正常文件名真的落盘了", ok3 and tostring(p3) or "")
local ok3b, p3b = pcall(function() return Export:write(rows, {}) end)
ok(ok3b and type(p3b) == "string" and p3b ~= p3,
    "3. 不给 name 时用默认名（默认名分支没被护栏弄坏）", tostring(p3b))

print("=== 4. 可诊断性：被拒的名字有没有给调用方一个信号？ ===")
local ok4, p4, e4 = pcall(function() return Export:write(rows, { name = ".." }) end)
ok(ok4 and type(p4) == "string",
    "4. name 非法时退回默认名、写入仍然成功（不算错）", tostring(p4))
note("4. 但调用方拿不到'我给的名字被拒了'这个信号",
    string.format("err=%s; 返回的路径用的是默认名，不是调用方传的那个", tostring(e4)))

print(string.format("TOTAL: %d  PASSED: %d  FAILED: %d", TOTAL, PASSED, FAILED))
if FAILED > 0 then
    print("FAILED-LIST:")
    for _i, n in ipairs(FAILED_NAMES) do print("  - " .. n) end
end
