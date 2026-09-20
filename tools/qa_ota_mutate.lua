--[==[
QA 变异工具：给 `qa_verify_ota.lua` 的每条新断言做"有牙证明"。

规矩（与项目一致）：
  · **只改副本**。用法是 `cp -r <插件> /mnt/us/ywbf_dev/mutplugin` 然后把本脚本指向副本，
    跑完 `rm -rf` 副本。绝不在真插件目录上做变异。
  · 变异分两类，两类都要做：
      M-A 接线断了（功能写了但没接进管道）；
      M-B/M-C 逻辑写错（接上了但算错 / 护栏被拆）。

在 KPW4 上：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     ./luajit /mnt/us/ywbf_dev/tools/qa_ota_mutate.lua <DIR> <MUT_ID>

未识别的 MUT_ID 会以退出码 2 报错退出（而不是"什么都没改"还假装成功——
那样会让"变异后仍然全绿"看起来像断言没牙，其实是变异没打上）。
--]==]

io.stdout:setvbuf("line")

local DIR = arg and arg[1]
local ID = arg and arg[2]
if type(DIR) ~= "string" or DIR == "" or type(ID) ~= "string" or ID == "" then
    print("用法：luajit qa_ota_mutate.lua <插件副本目录> <MUT_ID>")
    os.exit(2)
end
-- 兜一道保险：只允许动 /mnt/us/ywbf_dev 下的副本
if DIR:find("/mnt/us/ywbf_dev", 1, true) ~= 1 then
    print("拒绝执行：只允许对 /mnt/us/ywbf_dev 下的副本做变异 -> " .. tostring(DIR))
    os.exit(2)
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
local function patch(rel, from, to)
    local path = DIR .. "/" .. rel
    local src = readFile(path)
    if not src then
        print("  变异失败：读不到 " .. path)
        return false
    end
    if src:find(from, 1, true) == nil then
        print("  变异失败：在 " .. rel .. " 里找不到锚点 -> " .. from:sub(1, 60))
        return false
    end
    local out = src:gsub(from:gsub("[%[%]%^%$%(%)%%%.%*%+%-%?]", "%%%1"),
        to:gsub("%%", "%%%%"), 1)
    if not writeFile(path, out) then
        print("  变异失败：写不回 " .. path)
        return false
    end
    print("  变异已打：" .. rel .. " <- " .. ID)
    return true
end

local MUTS = {
    -- ---- M-A：接线断了 —— 「关于」菜单项从主菜单里整个摘掉 ----
    ["M-A"] = function()
        return patch("ui/settings.lua",
            [[    items[#items + 1] = {
        text = _("关于远望书友"),
        keep_menu_open = true,
        text_func = function()
            local v = Config.VERSION
            return T(_("关于远望书友（v%1）"), (type(v) == "string" and v) or _("未知")) -- luacheck: ignore
        end,
        sub_item_table = SettingsUI:buildAboutMenu(),
    }]],
            [[    -- MUT-A：关于菜单项被整段摘掉（模拟"功能写了但没接进主菜单"）]])
    end,
    -- ---- M-B：逻辑写错 —— 版本写死在关于菜单里（不读 Config.VERSION）----
    ["M-B"] = function()
        return patch("ui/settings.lua",
            [[            local v = Config.VERSION]],
            [[            local v = "0.2.0"  -- MUT-B：写死版本号，不读 Config.VERSION]])
    end,
    -- ---- M-C：护栏被拆 —— 下载域常驻进白名单 + 跳数上限放开 ----
    ["M-C"] = function()
        local ok1 = patch("ywbf/httpclient.lua",
            [[HttpClient.MAX_REDIRECTS = 3]],
            [[HttpClient.MAX_REDIRECTS = 99  -- MUT-C：跳数上限放开]])
        local ok2 = patch("ywbf/httpclient.lua",
            [[HttpClient.ALLOWED_HOSTS = {
    ["api.deepseek.com"] = true,
    ["api.github.com"] = true,      -- OTA：查最新 Release 走这里（只读、免费）
}]],
            [[HttpClient.ALLOWED_HOSTS = {
    ["api.deepseek.com"] = true,
    ["api.github.com"] = true,
    ["codeload.github.com"] = true,          -- MUT-C：下载域常驻进白名单
    ["objects.githubusercontent.com"] = true,
}]])
        return ok1 and ok2
    end,
    -- ---- M-D：零污染护栏被拆 —— apply 铺装时不再跳过 data/ ----
    ["M-D"] = function()
        return patch("ywbf/ota.lua",
            [[    local cmd = string.format("tar -cf - -C '%s' --exclude=./data --exclude=data . " ..
        "| tar -xf - -C '%s'", src_root, target_dir)]],
            [[    local cmd = string.format("tar -cf - -C '%s' . | tar -xf - -C '%s'",
        src_root, target_dir)  -- MUT-D：不再跳过 data/]])
    end,
    -- ---- M-E：备份路径改成固定名（并发部署会互相删掉）----
    ["M-E"] = function()
        return patch("ywbf/ota.lua",
            [[    local backup_path = string.format("%s/backup-%s-%s.tar.gz", backup_dir, stamp, salt)]],
            [[    local backup_path = string.format("%s/backup-fixed.tar.gz", backup_dir)  -- MUT-E]])
    end,
    -- ---- M-F：follow 逻辑写错 —— 首跳之外不再校验白名单 ----
    ["M-F"] = function()
        return patch("ywbf/httpclient.lua",
            [[        local extra = (hops > 0) and HttpClient.REDIRECT_HOSTS or nil
        if not HttpClient.isHostAllowed(current_url, extra) then]],
            [[        local extra = HttpClient.REDIRECT_HOSTS  -- MUT-F：每一跳都放行下载域
        if hops == 0 and not HttpClient.isHostAllowed(current_url, extra) then]])
    end,
}

local fn = MUTS[ID]
if type(fn) ~= "function" then
    print("未知的 MUT_ID：" .. tostring(ID))
    print("可用：" .. table.concat((function()
        local t = {}
        for k in pairs(MUTS) do t[#t + 1] = k end
        table.sort(t)
        return t
    end)(), ", "))
    os.exit(2)
end

local okm = fn()
if not okm then
    print("变异未生效（锚点没对上）：" .. ID)
    os.exit(1)
end
os.exit(0)
