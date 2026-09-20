--[[--
OTA 的变异注入器：**只作用在插件副本上**（`cp -r` 出来的 mutplugin），真插件不碰。

为什么用 Lua 写而不用 `sed`：
变异一旦"没打上"，跑出来就是全绿——你会以为这条断言没有牙齿，
其实是被测代码根本没变。上一轮用 sed 时踩过两次（`bad option` 静默失败），
所以这里每一条变异都**断言替换次数恰好是 1**，不是 1 就直接报错退出，
让驱动脚本把它记成 MUTAPPLY-FAIL 而不是"绿了"。

用法：
  ./luajit eng_mut_ota.lua <变异ID> <插件副本目录>

LuaJIT = Lua 5.1 语义：无位运算符；循环变量一律 `_i`。
--]]--

local MUT_ID = arg[1]
local DIR = arg[2]

if type(MUT_ID) ~= "string" or MUT_ID == "" then
    print("usage: eng_mut_ota.lua <id> <plugin_copy_dir>")
    os.exit(2)
end
if type(DIR) ~= "string" or DIR == "" then
    print("usage: eng_mut_ota.lua <id> <plugin_copy_dir>")
    os.exit(2)
end

--[[--
变异表。

分两类：
  · 逻辑写错 —— 算错了、判断反了、漏了该守的线；
  · 接线断了 —— 该接的地方没接上（没传开关、没挂入口、取错了对象）。
两者都要能被测出来：前者证明断言在验"算得对不对"，
后者证明断言在验"到底有没有接上"。
--]]
local MUTS = {
    -- ---------------- 逻辑写错 ----------------
    L1 = {
        kind = "逻辑写错",
        desc = "normalizeVersion 不补位（0.2 不再等于 0.2.0）",
        edits = {
            { file = "ywbf/ota.lua",
              from = "    while #out < 3 do out[#out + 1] = 0 end",
              to   = "    while #out < 0 do out[#out + 1] = 0 end" },
        },
    },
    L2 = {
        kind = "逻辑写错",
        desc = "版本比较退回字符串比较（0.9 会判成比 0.10 新）",
        edits = {
            { file = "ywbf/ota.lua",
              from = "        if x < y then return -1 end",
              to   = "        if tostring(x) < tostring(y) then return -1 end" },
            { file = "ywbf/ota.lua",
              from = "        if x > y then return 1 end",
              to   = "        if tostring(x) > tostring(y) then return 1 end" },
        },
    },
    L3 = {
        kind = "逻辑写错",
        desc = "available 判反（有新版本时不报更新，反而要降级）",
        edits = {
            { file = "ywbf/ota.lua",
              from = "        available = (cmp == -1),",
              to   = "        available = (cmp == 1)," },
        },
    },
    L4 = {
        kind = "逻辑写错",
        desc = "不校验 zipball 地址为空（空地址也会被当成可用 Release）",
        edits = {
            { file = "ywbf/ota.lua",
              from = '    if zip == "" then',
              to   = "    if false then" },
        },
    },
    L5 = {
        kind = "逻辑写错",
        desc = "下载不校验 zip 文件头（一段 HTML 也会被当成更新包）",
        edits = {
            { file = "ywbf/ota.lua",
              from = "    if body:sub(1, 4) ~= ZIP_MAGIC then",
              to   = "    if false then" },
        },
    },
    L6 = {
        kind = "逻辑写错",
        desc = "下载不设大小上限（异常大的包照收）",
        edits = {
            { file = "ywbf/ota.lua",
              from = "    if #body > Ota.MAX_DOWNLOAD_BYTES then",
              to   = "    if false then" },
        },
    },
    --[[--
    L7 的语义跟着 `backup` 的定位变过一次：
    备份从"只打代码"改成"全量（含 data/），只排除自己的两个临时目录"。
    所以这条变异现在是"把它退回不含 data"——回滚点里没有用户的收藏和历史，
    一旦 apply 那条线出问题就真的没了。变异的**方向**随实现改，
    但"必须有一条变异能打到这里"这件事不变。
    --]]
    L7 = {
        kind = "逻辑写错",
        desc = "备份又退回「不含 data」（回滚点里没有用户的收藏和历史）",
        edits = {
            { file = "ywbf/ota.lua",
              from = [==[        "tar -czf '%s' -C '%s' "
            .. "--exclude=./data/%s --exclude=data/%s "
            .. "--exclude=./data/%s --exclude=data/%s .",]==],
              to   = [==[        "tar -czf '%s' -C '%s' --exclude=./data --exclude=data .",]==] },
        },
    },
    L8 = {
        kind = "逻辑写错",
        desc = "备份不落在 data/ 之内（卸载删插件目录后留下垃圾）",
        edits = {
            { file = "ywbf/ota.lua",
              from = 'local backup_dir = target_dir .. "/" .. Ota.DATA_DIR_NAME .. "/" .. Ota.BACKUP_DIR_NAME',
              to   = 'local backup_dir = target_dir .. "/" .. Ota.BACKUP_DIR_NAME' },
        },
    },
    L9 = {
        kind = "逻辑写错",
        desc = "apply 不排除 data/（包里那份假 Key 会盖掉用户真 Key）",
        edits = {
            { file = "ywbf/ota.lua",
              from = "tar -cf - -C '%s' --exclude=./data --exclude=data . ",
              to   = "tar -cf - -C '%s' . " },
        },
    },
    L10 = {
        kind = "逻辑写错",
        desc = "找插件本体只看一层深（真实源码包是两层套娃，会装不进去）",
        edits = {
            { file = "ywbf/ota.lua",
              from = "    local MAX_DEPTH = 3",
              to   = "    local MAX_DEPTH = 1" },
        },
    },
    L11 = {
        kind = "逻辑写错",
        desc = "包里有多处像插件本体时不拒绝（装错一个更糟）",
        edits = {
            { file = "ywbf/ota.lua",
              from = "        if #hits > 1 then",
              to   = "        if #hits > 99 then" },
        },
    },
    L12 = {
        kind = "逻辑写错",
        desc = "apply 改成先把插件目录删光再铺（用户的 data/ 一起没了）",
        edits = {
            { file = "ywbf/ota.lua",
              from = "    mkdirp(stage)",
              to   = "    os.execute(string.format(\"rm -rf '%s'\", target_dir))\n    mkdirp(stage)" },
        },
    },
    L13 = {
        kind = "逻辑写错",
        desc = "回滚把备份铺到别处（等于没回滚）",
        edits = {
            { file = "ywbf/ota.lua",
              from = "tar -xzf '%s' -C '%s'",
              to   = "tar -xzf '%s' -C '/mnt/us/ywbf_dev/no_such_dir_for_mut'" },
        },
    },
    L14 = {
        kind = "逻辑写错",
        desc = "版本源的值本身写错（本地比远端新，永远报「已是最新」）",
        edits = {
            { file = "ywbf/config.lua",
              from = 'Config.VERSION = "0.2.0"',
              to   = 'Config.VERSION = "9.9.9"' },
        },
    },

    -- ---------------- 接线断了 ----------------
    W1 = {
        kind = "接线断了",
        desc = "白名单里没有 api.github.com（查 Release 出不去）",
        edits = {
            { file = "ywbf/httpclient.lua",
              from = '    ["api.github.com"] = true,',
              to   = '    -- ["api.github.com"] = true,' },
        },
    },
    W2 = {
        kind = "接线断了",
        desc = "下载域被写进常驻白名单（临时放行变成永久放行）",
        edits = {
            { file = "ywbf/httpclient.lua",
              from = '    ["api.github.com"] = true,',
              to   = '    ["api.github.com"] = true,\n    ["codeload.github.com"] = true,' },
        },
    },
    W3 = {
        kind = "接线断了",
        desc = "下载没开跳转跟随（GitHub 的 zipball 一定 302）",
        edits = {
            { file = "ywbf/ota.lua",
              from = "    }, 120, { follow_redirects = true })",
              to   = "    }, 120, nil)" },
        },
    },
    W4 = {
        kind = "接线断了",
        desc = "关于菜单里没有「检查更新」这一项",
        edits = {
            { file = "ui/settings.lua",
              from = '            text = _("检查更新"),',
              to   = '            text = _("检查新版本"),' },
        },
    },
    W5 = {
        kind = "接线断了",
        desc = "主菜单里没有「关于」入口（找不到入口等于没有这个功能）",
        edits = {
            { file = "ui/settings.lua",
              from = '        text = _("关于远望书友"),',
              to   = '        text = _("插件信息"),' },
        },
    },
    W6 = {
        kind = "接线断了",
        desc = "关于页的版本号抄了一份字面量，不再取 Config.VERSION",
        edits = {
            { file = "ui/settings.lua",
              from = "    local version_text = Config.VERSION",
              to   = '    local version_text = "0.0.0"' },
        },
    },
    W7 = {
        kind = "接线断了",
        desc = "查不到更新时不给任何提示（静默）",
        edits = {
            { file = "ui/settings.lua",
              from = '                text = T(_("没有查到更新信息：%1"), tostring(err)),',
              to   = '                text = T(_(""), tostring(err)),' },
        },
    },
    W8 = {
        kind = "接线断了",
        desc = "有新版本时不弹确认框（一个误触就直接开装）",
        edits = {
            -- 锚点必须带下一行：settings.lua 里有两处 ConfirmBox（另一处是清缓存），
            -- 只匹配 `ConfirmBox:new{` 会打偏，而打偏的变异跑出来是"全绿"的假象。
            { file = "ui/settings.lua",
              from = "            finish(ConfirmBox:new{\n"
                  .. "                text = T(_([[发现新版本：%1 → %2",
              to   = "            UIManager:show(InfoMessage:new{\n"
                  .. "                text = T(_([[发现新版本：%1 → %2" },
        },
    },
    W9 = {
        kind = "接线断了",
        desc = "当前版本不再取自 Config.VERSION（另写一份，迟早漂移）",
        edits = {
            { file = "ywbf/ota.lua",
              from = "    local current = Config.VERSION",
              to   = '    local current = "0.0.1"' },
        },
    },
    W10 = {
        kind = "接线断了",
        desc = "查 Release 没带 User-Agent（GitHub 会直接 403）",
        edits = {
            { file = "ywbf/ota.lua",
              -- 锚点要带到第三行：latestRelease 与 download 的前两行一模一样，
              -- 只靠 User-Agent 那一行会同时命中两处，变异就不知道打在哪了。
              from = '    local body, code, _status, err = HttpClient.get(url, {\n'
                  .. '        ["User-Agent"] = Ota.USER_AGENT,\n'
                  .. '        ["Accept"] = "application/vnd.github+json",',
              to   = '    local body, code, _status, err = HttpClient.get(url, {\n'
                  .. '        ["Accept"] = "application/vnd.github+json",' },
        },
    },
    W11 = {
        kind = "接线断了",
        desc = "查询打到了别的仓库（Repos 地址写错）",
        edits = {
            { file = "ywbf/ota.lua",
              from = 'Ota.REPO = "WayneChen1994/YuanWangBookFriend.koplugin"',
              to   = 'Ota.REPO = "someone/else"' },
        },
    },
    W12 = {
        kind = "接线断了",
        desc = "进度提示加回 timeout=1（1 秒后自己消失，用户干等）",
        edits = {
            { file = "ui/settings.lua",
              from = '        text = T(_("%1正在检查更新…"), Prompts.PERSONA_NAME), -- luacheck: ignore',
              to   = '        text = T(_("%1正在检查更新…"), Prompts.PERSONA_NAME), timeout = 1, -- luacheck: ignore' },
        },
    },
    W13 = {
        kind = "接线断了",
        desc = "结果弹窗出来前不 close 进度提示（两个并排挂着）",
        edits = {
            { file = "ui/settings.lua",
              from = "    local function finish(widget)\n"
                  .. "        UIManager:close(progress)\n"
                  .. "        UIManager:show(widget)\n"
                  .. "    end",
              to   = "    local function finish(widget)\n"
                  .. "        UIManager:show(widget)\n"
                  .. "    end" },
        },
    },
    W14 = {
        kind = "接线断了",
        desc = "安装的三段提示各自 show 一层、不关前一层（末了摞成一叠）",
        edits = {
            { file = "ui/settings.lua",
              from = "    local function say(text)\n        if stage then UIManager:close(stage) end",
              to   = "    local function say(text)\n        if false then UIManager:close(stage) end" },
        },
    },
    L15 = {
        kind = "逻辑写错",
        desc = "目标目录护栏不认 `..`（tar 会把文件铺到插件目录之外）",
        edits = {
            { file = "ywbf/ota.lua",
              from = [==[    if path:find("%.%.") then return false end          -- 拒绝任何 `..` 段]==],
              to   = [==[    if false then return false end          -- 拒绝任何 `..` 段]==] },
        },
    },
    L16 = {
        kind = "逻辑写错",
        desc = "目标目录护栏不认 shell 元字符（路径被拼进 os.execute 的 shell 串）",
        edits = {
            { file = "ywbf/ota.lua",
              from = [==[    if path:find("['\"`%$;|&\\\n]") then return false end -- shell 元字符]==],
              to   = [==[    if false then return false end -- shell 元字符]==] },
        },
    },
}

local mut = MUTS[MUT_ID]
if not mut then
    print("MUTFAIL " .. tostring(MUT_ID) .. " unknown mutation id")
    os.exit(3)
end

local function readfile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end
local function writefile(path, content)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

--[[--
按**纯文本**替换一次。

不能用 `string.gsub`：变异的 `from` 里满是 `[`、`(`、`.`、`%` 这些 Lua 模式字符，
gsub 会把它们当模式解释——结果是"替换次数 0"或者"打到了另一个位置"，
两者都表现为测试全绿，而实际上被测代码根本没动。这种假绿比红更贵。
--]]
local function replaceOnce(s, from, to)
    local i = string.find(s, from, 1, true)
    if i == nil then return s, 0 end
    return string.sub(s, 1, i - 1) .. to .. string.sub(s, i + #from), 1
end

local function countAll(s, from)
    local n, pos = 0, 1
    while true do
        local i = string.find(s, from, pos, true)
        if i == nil then break end
        n = n + 1
        pos = i + #from
    end
    return n
end

for _i, ed in ipairs(mut.edits) do
    local path = DIR .. "/" .. ed.file
    local src = readfile(path)
    if type(src) ~= "string" then
        print("MUTFAIL " .. MUT_ID .. " 读不到文件 " .. tostring(ed.file))
        os.exit(4)
    end
    --[[--
    这个模式在全文里必须**恰好出现 1 次**：
    0 次 = 变异没打上（跑出来全绿，是最坏的一种假象）；
    2 次以上 = 打到了不该打的地方，结论同样不可信。
    --]]
    local total_all = countAll(src, ed.from)
    if total_all ~= 1 then
        print("MUTFAIL " .. MUT_ID .. " 模式出现 " .. tostring(total_all) ..
            " 次（应为 1，否则替换的不是我要的那一处）  文件=" .. tostring(ed.file))
        os.exit(5)
    end
    local new_src, n = replaceOnce(src, ed.from, ed.to)
    if n ~= 1 then
        print("MUTFAIL " .. MUT_ID .. " 替换失败  文件=" .. tostring(ed.file))
        os.exit(6)
    end
    if not writefile(path, new_src) then
        print("MUTFAIL " .. MUT_ID .. " 写不回去 " .. tostring(ed.file))
        os.exit(7)
    end
end

print("MUTOK " .. MUT_ID .. "  [" .. mut.kind .. "] " .. mut.desc)
os.exit(0)
