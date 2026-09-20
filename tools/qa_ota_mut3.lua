--[==[
QA 变异补丁（OTA / C13 / C14 专用）。只作用在**插件副本**上，绝不碰真插件。

用法：luajit qa_ota_mut3.lua <id> <root>

自检（M-G 空转变异的教训，三条硬规矩）：
  1. 锚点命中次数必须**恰好 1**——命中 0 是"没打上"，命中 2+ 是"归因不清"，
     两种情况都 fail-fast，不许进结论；
  2. 改完若与改前**逐字节相同**，判 NOOP 并 fail-fast
     （"变异后仍然全绿"有可能是变异根本没生效，不是断言没牙）；
  3. 改动前后 md5 都打出来，人工一眼可核对；两者相同再 fail 一次。

区域定位：不用裸 sed（中文行 sed 锚点对不上就会静默空转），改成
"按函数签名取行区间 + 在区内按特征行定位"，并在关键处用「正在」的字节序列
做二次校验，确保改到的确实是**进度提示**那一行，而不是同函数里的结果弹窗。
--]==]

local ROOT = arg and arg[2]
local ID = arg and arg[1]
if not ROOT or not ID then
    print("usage: luajit qa_ota_mut3.lua <id> <root>")
    os.exit(2)
end

local SETTINGS = ROOT .. "/ui/settings.lua"
local OTAFILE = ROOT .. "/ywbf/ota.lua"

-- 「正在」的 UTF-8 字节序列（正=E6 AD A3 / 在=E5 9C A8）。
-- 直接写汉字要赌编辑器和 scp 的编码，写字节序列最稳。
local ZHENGZAI = "\230\173\163\229\156\168"

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
local function md5of(p)
    local f = io.popen("md5sum " .. p)
    if not f then return "?" end
    local s = f:read("*l") or "?"
    f:close()
    return s:match("^(%S+)") or "?"
end
local function splitLines(s)
    local t = {}
    local cur = 1
    while true do
        local a = s:find("\n", cur, true)
        if not a then
            local last = s:sub(cur)
            if #last > 0 then t[#t + 1] = last end
            break
        end
        t[#t + 1] = s:sub(cur, a - 1)
        cur = a + 1
    end
    return t
end
local function joinLines(src, ls)
    local s = table.concat(ls, "\n")
    if src:sub(-1) == "\n" then s = s .. "\n" end
    return s
end
-- 取函数区间：从签名行起，到下一行**顶格的 `end`**为止
local function funcRange(ls, sig)
    for i = 1, #ls do
        if ls[i]:find(sig, 1, true) then
            for j = i + 1, #ls do
                if ls[j] == "end" then return i, j end
            end
            return i, #ls
        end
    end
    return nil, nil
end
local function ctxHasZhengzai(ls, i)
    local ctx = tostring(ls[i]) .. "\n" .. tostring(ls[i + 1]) .. "\n" .. tostring(ls[i + 2])
    return ctx:find(ZHENGZAI, 1, true) ~= nil
end

local function apply(rel, mutate)
    local path = (rel == "settings") and SETTINGS or OTAFILE
    local src = readFile(path)
    if not src then print("读不到 " .. path); os.exit(4) end
    local before = md5of(path)
    local out, log = mutate(src)
    if type(out) ~= "string" then
        print("变异未生效：" .. tostring(log)); os.exit(5)
    end
    if out == src then
        print("NOOP：改完与改前逐字节相同（锚点没真正命中）-> 判为无效变异"); os.exit(5)
    end
    if not writeFile(path, out) then print("写不回 " .. path); os.exit(6) end
    local after = md5of(path)
    if before == after then
        print("NOOP：md5 前后相同 -> 判为无效变异"); os.exit(5)
    end
    print(string.format("APPLIED %s -> %s  md5 %s -> %s", ID, rel,
        before:sub(1, 8), after:sub(1, 8)))
    if log then print("   " .. tostring(log)) end
    os.exit(0)
end

-- ---------------- 变异体 ----------------
local M = {}

-- ① 进度提示加回 timeout = 1
local function mkAddTimeout(sig)
    return function(src)
        local ls = splitLines(src)
        local a, b = funcRange(ls, sig)
        if not a then return nil, "找不到函数签名 " .. sig end
        local hits, chosen = 0, nil
        for i = a, b do
            if ls[i]:find("InfoMessage:new{", 1, true) and ctxHasZhengzai(ls, i) then
                hits = hits + 1
                chosen = i
            end
        end
        if hits ~= 1 then
            return nil, "「InfoMessage:new{ 且含『正在』」命中 " .. hits .. " 行（期望恰好 1）"
        end
        if ls[chosen]:find("timeout", 1, true) then
            return nil, "该行已含 timeout —— 变异无从下手"
        end
        ls[chosen] = ls[chosen]:gsub("InfoMessage:new{", "InfoMessage:new{ timeout = 1,", 1)
        return joinLines(src, ls), string.format("%s 第 %d 行：进度提示加回 timeout = 1", sig, chosen)
    end
end

-- ② 删掉「结果出来前先 close 进度」那一步
local function mkDelClose(sig)
    return function(src)
        local ls = splitLines(src)
        local a, b = funcRange(ls, sig)
        if not a then return nil, "找不到函数签名 " .. sig end
        local hits, chosen = 0, nil
        for i = a, b do
            if ls[i]:find("UIManager:close(progress)", 1, true) then
                hits = hits + 1
                chosen = i
            end
        end
        if hits ~= 1 then
            return nil, "UIManager:close(progress) 命中 " .. hits .. " 次（期望恰好 1）"
        end
        ls[chosen] = "        -- QAMUT：close(progress) 被删掉（模拟「忘记先关进度再弹结果」）"
        return joinLines(src, ls), string.format("%s 第 %d 行：删掉 close(progress)", sig, chosen)
    end
end

-- ③ 进度文案退回中性措辞（拿掉人设名）
local function mkDropPersona(sig)
    return function(src)
        local ls = splitLines(src)
        local a, b = funcRange(ls, sig)
        if not a then return nil, "找不到函数签名 " .. sig end
        local hits, chosen = 0, nil
        for i = a, b do
            if ls[i]:find("Prompts.PERSONA_NAME", 1, true) and ctxHasZhengzai(ls, i) then
                hits = hits + 1
                chosen = i
            end
        end
        if hits ~= 1 then
            return nil, "「Prompts.PERSONA_NAME 且含『正在』」命中 " .. hits .. " 行（期望恰好 1）"
        end
        local nl = ls[chosen]:gsub("Prompts%.PERSONA_NAME", '""', 1)
        if nl == ls[chosen] then return nil, "替换没生效" end
        ls[chosen] = nl
        return joinLines(src, ls), string.format("%s 第 %d 行：进度文案去掉人设名", sig, chosen)
    end
end

M.U1 = { "settings", mkAddTimeout("function SettingsUI:checkUpdate()") }
M.U2 = { "settings", mkDelClose("function SettingsUI:checkUpdate()") }
M.T1 = { "settings", mkAddTimeout("function SettingsUI:testConnection()") }
M.T2 = { "settings", mkDelClose("function SettingsUI:testConnection()") }
M.T3 = { "settings", mkDropPersona("function SettingsUI:testConnection()") }
M.Q1 = { "settings", mkAddTimeout("function SettingsUI:queryBalance()") }
M.Q2 = { "settings", mkDelClose("function SettingsUI:queryBalance()") }
M.Q3 = { "settings", mkDropPersona("function SettingsUI:queryBalance()") }

-- ④ B3⑰ 的三处护栏（backup / apply / rollback）各自单独拆
--    「按所在函数挑命中项」而不是按出现顺序挑：顺序会随重构变，函数名不会。
local function mkDropTargetGuard(fname)
    return function(src)
        local ls = splitLines(src)
        local anchor = "isSafeTargetDir(target_dir)"
        local total = 0
        for _i = 1, #ls do
            if ls[_i]:find(anchor, 1, true) then total = total + 1 end
        end
        if total ~= 3 then
            return nil, "isSafeTargetDir(target_dir) 全文命中 " .. total .. " 处（期望 3：backup/apply/rollback）"
        end
        local chosen = nil
        for i = 1, #ls do
            if ls[i]:find(anchor, 1, true) then
                local owner = nil
                for j = i, 1, -1 do
                    local f = ls[j]:match("^function Ota:(%w+)")
                    if f then owner = f; break end
                end
                if owner == fname then chosen = i; break end
            end
        end
        if not chosen then return nil, "没找到属于 Ota:" .. fname .. " 的那处护栏" end
        ls[chosen] = ls[chosen]:gsub("isSafeTargetDir%(target_dir%)", "true", 1)
        return joinLines(src, ls), string.format("Ota:%s 第 %d 行：target_dir 穿越校验被拆掉", fname, chosen)
    end
end
M.D1 = { "ota", mkDropTargetGuard("backup") }
M.D2 = { "ota", mkDropTargetGuard("apply") }
M.D3 = { "ota", mkDropTargetGuard("rollback") }

local m = M[ID]
if not m then
    print("未知变异 ID：" .. tostring(ID))
    local t = {}
    for k in pairs(M) do t[#t + 1] = k end
    table.sort(t)
    print("可用：" .. table.concat(t, ", "))
    os.exit(3)
end
apply(m[1], m[2])
