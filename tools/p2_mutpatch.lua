--[==[
QA 变异补丁（只在**插件副本**上用，绝不动真插件）。

为什么用一个 Lua 脚本来改而不是 sed：要改的行里有中文（「，」「导出 Markdown」），
而 Windows 的 PowerShell 经 ssh 发过去的中文会被按 GBK 编码，到了设备上的 sh 里
字节已经不对，sed 匹配不上（上一轮 grep "导出" 就是这么空手而归的）。
这个脚本本身以 UTF-8 二进制上传，Lua 按字节比较，中文才对得上。

用法：luajit p2_mutpatch.lua <变异编号> <副本目录>
--]==]

-- 「专业严谨」的 UTF-8 字节（十进制转义）
local STYLE_LABEL_BYTES = "\228\184\147\228\184\154\228\184\165\232\176\168"

local MUT = {
    -- 逻辑写错：只认英文逗号（全角逗号不再归一化）
    M1 = { "ywbf/store.lua",
           'local normalized = input:gsub("，", ",")',
           'local normalized = input -- QAMUT' },
    -- 逻辑写错：改备注把别的字段一起冲掉
    M2 = { "ywbf/store.lua",
           '        e.note = text',
           '        e.note = text; e.question = nil; e.style = nil; e.tags = nil; e.favorite = nil -- QAMUT' },
    -- 逻辑写错：下界不含（差一天）
    M3 = { "ywbf/store.lua",
           'if type(since) == "number" and ts < since then return false end',
           'if type(since) == "number" and ts <= since then return false end -- QAMUT' },
    -- 逻辑写错：上界不含
    M4 = { "ywbf/store.lua",
           'if type(until_ts) == "number" and ts > until_ts then return false end',
           'if type(until_ts) == "number" and ts >= until_ts then return false end -- QAMUT' },
    -- 逻辑写错：老数据（缺 style）被算成 professional
    M5 = { "ywbf/store.lua",
           'and e.style or Store.UNKNOWN_STYLE',
           'and e.style or "professional" -- QAMUT' },
    -- 逻辑写错：tag 筛选恒真
    M6 = { "ywbf/store.lua",
           '        if not found then return false end',
           '        if false then return false end -- QAMUT' },
    -- 接线断了：write 自己拼个标题，不调 render
    M7 = { "ywbf/export.lua",
           '    local text = self:render(rows, opts)',
           '    local text = "# QA MUTANT: write did not call render\\n" -- QAMUT' },
    -- 接线断了：UI 导出传空行数组，导出成空壳
    M8 = { "ui/favorites.lua",
           'Export:write(rows, opts)',
           'Export:write({}, opts) -- QAMUT' },
    -- 接线断了：设置菜单里根本没有导出项（两个入口都改名，所以要替换**全部**命中）
    M9 = { "ui/settings.lua",
           '导出 Markdown',
           '收藏 Markdown',
           "all" },
    -- 逻辑写错：称呼写死 AI
    M10 = { "ywbf/export.lua",
            'local persona = Prompts.PERSONA_NAME',
            'local persona = "AI" -- QAMUT' },
    -- 逻辑写错：正文按字节截断（裸 string.sub）
    M11 = { "ywbf/export.lua",
            'lines[#lines + 1] = bodyText(row.content)',
            'lines[#lines + 1] = string.sub(row.content or "", 1, 200) -- QAMUT' },
    -- 逻辑写错：导出写到 /tmp（插件目录之外）
    M12 = { "ywbf/export.lua",
            '    local dir = self:dir()',
            '    local dir = "/tmp/ywbf_qa_mut" -- QAMUT' },
    -- 逻辑写错：另抄一份中文风格映射表（不走 Prompts.STYLES）——3⑯ 必须红。
    -- 中文字面量一律用**十进制字节转义**写：这个文件要经 scp 传来传去，
    -- 写成明文一旦编码不对，变异就变成"插入了一段乱码"，那样"没变红"会有两种解释，
    -- 结论就不可信了。（专=228,184,147 业=228,184,154 严=228,184,165 谨=232,176,168）
    M14 = { "ywbf/export.lua",
            'local persona = Prompts.PERSONA_NAME',
            'local persona = Prompts.PERSONA_NAME\n    local QA_STYLE_COPY = "'
            .. STYLE_LABEL_BYTES .. '" -- QAMUT' },
    -- 同一个字面量**只在注释里**出现 —— 3⑯ 应当放行，但计 EXEMPT（不合并进通过数）
    M15 = { "ywbf/export.lua",
            'local persona = Prompts.PERSONA_NAME',
            'local persona = Prompts.PERSONA_NAME\n    -- QAMUT '
            .. STYLE_LABEL_BYTES },
    -- 接线断了：toRow 不带 note / tags（回到阶段一的形状）
    M13 = { "ywbf/store.lua",
            '        note = e.note,\n        tags = e.tags,',
            '        -- QAMUT: note/tags dropped from row' },
    -- 逻辑写错：清空标签后留**空数组**而不是 nil（2⑤ / 2⑤b 必须红）。
    -- 「有没有标签」这个问题上，空数组的答案是含糊的：#t==0 和 t==nil 都判得出"没有"，
    -- 但存进 JSON 之后空数组会被写成 `[]`，下次读回来是个 table 而不是 nil，
    -- "从来没打过标签"和"打过又删光了"就分不开了。
    M16 = { "ywbf/store.lua",
            'if #out == 0 then return nil end',
            'if false then return nil end -- QAMUT' },
    -- 接线/遍历断了：筛选菜单里不再有「不限风格」那一项（11② 必须红）。
    -- Lua 里 `{ nil }` 是空表、`ipairs` 零次，所以这类"少一项"的洞
    -- 靠"某一项存在吗"的断言查不出来，要靠"项数正好是 N" + "选中后回得了不限"。
    M17 = { "ui/favorites.lua",
            '    addStyle(nil)',
            '    -- QAMUT: addStyle(nil) removed' },
    -- 形状写错：write 退回 `(ok, path)` —— 4① 必须红。
    -- 这条专门用来证明"收紧后的 4① 不是把期望值改成了新顺序"：
    -- 只要谁把返回形状改回去，调用方 `if p then` 照样通过、然后拿 true 当路径用。
    M18 = { "ywbf/export.lua",
            '    return path, nil',
            '    return true, path -- QAMUT' },
    -- 逻辑写错：导出时把**内部 key** 当成显示名写出去（3⑨ / 4⑥ 必须红）。
    -- 用户看到的是 `professional`，而设置菜单里同一回事写的是「专业严谨」。
    M19 = { "ywbf/export.lua",
            '                return s.text',
            '                return k -- QAMUT' },
    -- 【漂移检测的两组反向变异】（作用在 tests/run_tests.lua 的副本上）
    -- D1：让目录扫描返回空 —— 空扫描会让下面每条"清单必须覆盖到"的断言恒绿，
    --     所以 run_tests 必须红在"扫描本身可用"这条前置上。
    D1 = { "run_tests.lua",
           'if not (ok_lfs and lfs and type(lfs.dir) == "function") then return nil end',
           'if true then return {} end -- QAMUT' },
    -- D2：把 ui_files 清单写坏（漏掉 favorites / suggestpicker）——
    -- 用来确认漂移检测不是摆设：写坏之后"扫描仍然可用"的前置必须保持成立，
    -- 真正变红的是"清单必须覆盖到"那一条。
    D2 = { "run_tests.lua",
           'local ui_files = { "asker", "chatdialog", "settings", "toastcard",\n                   "favorites", "suggestpicker" }',
           'local ui_files = { "asker", "chatdialog", "settings", "toastcard" } -- QAMUT: 新文件没进清单' },
    -- 成功却带了错误原因：`return path, "不知哪来的原因"`。
    -- 用来检验"成功时 err 必须是 nil"这条约束到底是谁在把着：
    -- 只验拿得到路径的写法会让它全绿通过，而调用方据此无法判断成败。
    M20 = { "ywbf/export.lua",
            '    return path, nil',
            '    return path, "QAMUT 假的错误原因" -- QAMUT' },
    -- 护栏拆掉：name 重新变成原样拼接（越界写）。
    -- 前置小心点：不设防时返回的字符串**照样以 dir.."/" 开头**（越界是文件系统
    -- 解析之后才发生的），所以只有"精确相等"或"真去扫目录"的断言才抓得到，
    -- 前缀比较的写法会被它全绿放过。
    M21 = { "ywbf/export.lua",
            'local name = safeName(opts.name) or self:defaultName()',
            'local name = opts.name or self:defaultName() -- QAMUT' },
    -- 护栏拆掉另一种：只去 ".." 但不去目录分隔符 —— name="../../evil.md" 就会
    -- 带着分隔符拼进路径。这条用来问：只盯着 ".." 的断言（不看落点）能不能抓到。
    M22 = { "ywbf/export.lua",
            '    local base = name:gsub("^.*[/\\\\]", "")',
            '    local base = name -- QAMUT: separators not stripped' },
    -- 三条失败分支各自拆一条：不返回 (nil, 原因) 而是返回一个路径字符串。
    -- 24h / 24i / 24j 必须各自红 —— 三条分支各自有人把着，才算补上了。
    M23 = { "ywbf/export.lua",
            '    if not dir then return nil, _(',
            '    if not dir then return "QAMUT_NOT_NIL", nil end; if false then return nil, _(' },
    M24 = { "ywbf/export.lua",
            '    if not ensureDir(dir) then return nil, T(',
            '    if not ensureDir(dir) then return "QAMUT_NOT_NIL", nil end; if false then return nil, T(' },
    M25 = { "ywbf/export.lua",
            '    if not ok_write then return nil, T(',
            '    if not ok_write then return "QAMUT_NOT_NIL", nil end; if false then return nil, T(' },
    -- 控制字符不清了：C 层截断成 `probe` 落盘、返回的路径却仍带 NUL（24m 必须红）。
    M26 = { "ywbf/export.lua",
            '    base = base:gsub("%c", "")',
            '    base = base -- QAMUT: control chars kept' },
}

local id = arg and arg[1]
local root = arg and arg[2]
if not id or not root then
    print("usage: luajit p2_mutpatch.lua <id> <root>")
    os.exit(2)
end
local m = MUT[id]
if not m then
    print("unknown mutation id: " .. tostring(id))
    os.exit(3)
end

local rel, from, to = m[1], m[2], m[3]
local path = root .. "/" .. rel
local f = io.open(path, "rb")
if not f then print("cannot open " .. path); os.exit(4) end
local src = f:read("*all")
f:close()

-- 全用**纯文本**查找（plain = true）：待改的行里有 [ ] ( ) . 这些 Lua 模式元字符，
-- 走模式匹配要么匹配不上、要么匹配到别处去。
local pos = src:find(from, 1, true)
if not pos then
    print("NOTFOUND " .. id .. " in " .. rel)
    os.exit(5)
end
-- 必须**只命中一处**：命中多处说明我定位得不够准，那这个变异的结论就不可信
-- （例外：显式标了 "all" 的变异就是要改掉每一处，比如"把所有导出入口都改名"）
local replace_all = (m[4] == "all")
local cnt = 0
local p = 1
while true do
    local a = src:find(from, p, true)
    if not a then break end
    cnt = cnt + 1
    p = a + #from
end
if cnt == 0 then
    print("NOTFOUND " .. id .. " in " .. rel)
    os.exit(5)
end
if (not replace_all) and cnt ~= 1 then
    print(string.format("AMBIGUOUS %s in %s: hit %d times", id, rel, cnt))
    os.exit(6)
end

local out
if replace_all then
    local parts = {}
    local q = 1
    while true do
        local a = src:find(from, q, true)
        if not a then parts[#parts + 1] = src:sub(q); break end
        parts[#parts + 1] = src:sub(q, a - 1)
        parts[#parts + 1] = to
        q = a + #from
    end
    out = table.concat(parts)
    print(string.format("APPLIED %s -> %s (%d occurrences replaced)", id, rel, cnt))
else
    out = src:sub(1, pos - 1) .. to .. src:sub(pos + #from)
    print(string.format("APPLIED %s -> %s (line-ish offset %d)", id, rel, pos))
end
local w = io.open(path, "wb")
if not w then print("cannot write " .. path); os.exit(7) end
w:write(out)
w:close()
