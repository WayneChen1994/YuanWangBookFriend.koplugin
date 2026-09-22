--[[--
设置页与主菜单（M1 版本）：API Key 配置（掩码输入 + 加密保存）、连通性测试、
模型选择、防剧透开关、用量统计、关于。

PRD 对应：F8.4（Key 加密存储）、F8.5（无遥测声明）、F4.1（防剧透总开关）、§4.3（用量透明）
--]]--

local Config = require("ywbf/config")
local Crypto = require("ywbf/crypto")
local DeepSeek = require("ywbf/deepseek")
local Ota = require("ywbf/ota")
local Prompts = require("ywbf/prompts")
local Queue = require("ywbf/queue")
local Spoiler = require("ywbf/spoiler")
local Tokens = require("ywbf/tokens")

local Favorites = require("ui/favorites")

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local SettingsUI = {}

--[[--
关于 API Key 的显示方式（真机反馈后定的口径）：**菜单上不显示内容，对话框里全明文**。

两个方向都试过、都被否掉了：
  · 菜单里显示掩码（"sk-****…"）：DeepSeek 的 Key 全是 sk- 开头，掩码后只剩
    一串星号加省略号，既看不出是哪个 Key、也没法核对抄错了没有 —— 毫无意义；
  · 菜单里全明文：菜单是常驻可见的，旁边有人时等于把密钥摊在屏幕上。

所以：菜单行只给**状态**（已设置 / 未设置），要核对内容就点进去看——
对话框里把当前明文 Key 预填进输入框，可直接编辑、也可整段粘贴覆盖。
--]]
function SettingsUI:showApiKeyDialog()
    local current = DeepSeek:getApiKey()
    local dialog
    dialog = InputDialog:new{
        title = _("配置 DeepSeek API Key"),
        description = _([[Key 会加密保存在插件目录内，永不以明文落盘。
粘贴后点击「保存」。]]),
        -- 预填当前明文 Key：让人能真的核对"是不是这一个"，
        -- 而不是对着一串星号猜。原样保存等于没改，保存逻辑不用动。
        input = current or "",
        input_hint = current and _("已设置（可直接编辑，或粘贴新的覆盖）") or _("尚未配置"),
        input_type = "string",
        -- 刻意**不设** text_type = "password"：
        -- 它是 KOReader 那个「显示密码」勾选框的唯一来源
        -- （inputtext.lua: is_password_type = text_type == "password"，
        --  为 false 时 _password_toggle 直接是 nil，inputdialog 不会挂出来）。
        -- 去掉它 → 输入框明文、勾选项根本不出现，比去改 KOReader 内置文案干净。
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputText()
                        UIManager:close(dialog)
                        value = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        if value == "" then
                            UIManager:show(InfoMessage:new{ text = _("未输入内容，未做修改") })
                            return
                        end
                        local ok = DeepSeek:setApiKey(value)
                        UIManager:show(InfoMessage:new{
                            text = ok and _("API Key 已加密保存") or _("保存失败"),
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--[[--
从文件导入 API Key：墨水屏上手输 32 位密钥太痛苦。
USB 拷贝一个文本文件到插件 data 目录，命名 api_key.txt，这里一键导入。
导入成功后自动删除明文文件。
--]]
function SettingsUI:importApiKeyFromFile()
    local path = Config.paths.data .. "/api_key.txt"
    local f = io.open(path, "r")
    if not f then
        UIManager:show(InfoMessage:new{
            text = T(_([[没有找到 Key 文件。

请用 USB 连电脑，把写着 DeepSeek API Key 的文本文件放到插件 data 目录，命名为 api_key.txt：

%1

放好后回到这里点击导入。导入成功会自动删除明文文件。]]), path),
        })
        return
    end
    local key = (f:read("*l") or "")
    f:close()
    key = key:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^[\"']", ""):gsub("[\"']$", "")
    if key == "" then
        UIManager:show(InfoMessage:new{ text = _("文件内容为空") })
        return
    end
    if not DeepSeek:setApiKey(key) then
        UIManager:show(InfoMessage:new{ text = _("保存失败") })
        return
    end
    os.remove(path)
    -- 不回显 Key 内容（同菜单口径：要核对就进配置对话框看明文）
    UIManager:show(InfoMessage:new{
        text = _("已导入并加密保存。\n\n明文文件已删除。"),
    })
end

--[[--
插件名与一句话说明：**读 `_meta.lua`，不在设置页里再抄一份**。

抄一份的结果是菜单里的介绍和 KOReader 插件列表里的介绍各自演化，
用户两处看到不一样的东西时，不知道该信哪个。
`@module` 那个 require 偶尔会失败（比如某些加载顺序下），失败就用兜底文案，
宁肯短一点也不回到写死两遍的老路。
--]]
local META_OK, PLUGIN_META = pcall(require, "_meta")
local PLUGIN_FULLNAME = (META_OK and type(PLUGIN_META) == "table"
    and type(PLUGIN_META.fullname) == "string" and PLUGIN_META.fullname) or _("远望书友")
local PLUGIN_DESCRIPTION = (META_OK and type(PLUGIN_META) == "table"
    and type(PLUGIN_META.description) == "string" and PLUGIN_META.description)
    or _("KOReader 的 AI 辅助阅读插件。")

--[[--
「关于」子菜单：版本 / 数据目录 / 检查更新。

版本号**必须取自 `Config.VERSION`**：它同时也是 OTA 用来判"有没有新版本"的那一个数。
在这里写死第二份的话，用户看到"已是最新"却总也拿不到新版本就成了常态，
而排查时会先怀疑网络、怀疑 GitHub，最后才想到是版本号写错了 —— 那份名单太贵。

**这里不放"插件名 / 简介"那一项**（2026-09-20 真机反馈后移除）：它只有 text 和
help_text、没有 callback，KOReader 的菜单对这种行点了什么都不做，用户看到的就是
"点了一下没反应"。名字已经在父菜单项上了，简介挪到父菜单的 help_text（长按可见），
子菜单里剩下的每一项都必须是能点出东西的。
--]]
function SettingsUI:buildAboutMenu()
    local version_text = Config.VERSION
    if type(version_text) ~= "string" or version_text == "" then
        version_text = _("未知")
    end

    return {
        {
            text = T(_("版本：%1"), version_text), -- luacheck: ignore
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_([[当前版本：%1

版本号也是更新检查的基准。如果这个数字跟 Release 页面上的最新版本一致，
说明你已经是最新的了。]]), version_text),
                })
            end,
        },
        {
            text = T(_("数据目录：%1"), tostring(Config.paths.data or _("（未初始化）"))), -- luacheck: ignore
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_([[所有数据都在这个目录里：%1

卸载插件时删掉这个目录就干净了；连上电脑也能直接从这里拷走：
收藏导出的 Markdown 在其中的 export/ 下，更新备份在 ota_backup/ 下。]]),
                        tostring(Config.paths.data or _("（未初始化）"))),
                })
            end,
        },
        {
            text = _("检查更新"),
            help_text = _([[向 GitHub 查询这个插件有没有新版本。
查询只读取 Release 信息，不上传任何本机数据，也不消耗 API 额度。
有新版本时会先给当前版本打一份备份，再下载铺进插件目录——你的 Key、收藏和历史都不会被动。]]),
            keep_menu_open = true,
            callback = function() SettingsUI:checkUpdate() end,
        },
    }
end

--[[--
走一遍完整的手动更新：**备份 → 下载 → 铺装 → 提示重启**。

为什么是全自动而不是"下载完让你自己去铺"：真机上让用户去 `tar` 解压，
等于这个功能没有。所以整条链路都在这里，UI 只负责问一句"要不要装"。

刻意不做的事：
  · **不重启 KOReader**（用户明确要求）——装完只提示"请手动重启"；
  · 任一步失败就把备份路径一起告诉用户，而不是只说"失败了"；
  · 每一步都给一句短提示。沉默几秒钟在那个时刻看起来和"卡死了"没有区别。
@param info table `Ota:checkForUpdate()` 的返回值
--]]
function SettingsUI:installUpdate(info)
    local target = Config.paths.plugin
    if type(target) ~= "string" or target == "" then
        UIManager:show(InfoMessage:new{ text = _("插件目录没读到，没法更新。") })
        return
    end

    --[[--
    全程只留**一个**弹层。

    原来这里是三个 `timeout = 1` 的短提示依次 show。问题是：备份、下载、安装是
    **同步**执行的，主循环被堵住时它们根本来不及绘制，等循环转过来就变成好几层
    摞在一起（还都带着 1 秒后自动消失的计时）。改成复用同一个弹层：换文案时
    先 close 再 show，出结果时同样先 close——屏幕上任何时刻只有一个。
    --]]
    local stage = nil
    local function say(text)
        if stage then UIManager:close(stage) end
        stage = InfoMessage:new{ text = text }
        UIManager:show(stage)
    end
    local function finish(text)
        if stage then UIManager:close(stage); stage = nil end
        UIManager:show(InfoMessage:new{ text = text })
    end

    say(T(_("%1正在备份当前版本…"), Prompts.PERSONA_NAME)) -- luacheck: ignore
    local backup_path, err = Ota:backup(target)
    if not backup_path then
        finish(T(_("备份失败，已停止更新：%1"), tostring(err)))
        return
    end

    local zip_path = target .. "/data/" .. string.format("update-%s.zip",
        os.date("%Y%m%d-%H%M%S") or tostring(os.time()))
    say(T(_("%1正在下载新版本…"), Prompts.PERSONA_NAME)) -- luacheck: ignore
    local ok_dl, err_dl = Ota:download(info and info.url or nil, zip_path)
    if not ok_dl then
        finish(T(_("下载失败，当前版本没有被改动：%1"), tostring(err_dl)))
        return
    end

    say(T(_("%1正在安装…"), Prompts.PERSONA_NAME)) -- luacheck: ignore
    local ok_apply, err_apply = Ota:apply(zip_path, target)
    if not ok_apply then
        finish(T(_([[安装失败：%1

当前版本没有被改动。如果想回到安装前的样子，把这份备份里的文件盖回去即可：
%2]]), tostring(err_apply), tostring(backup_path)))
        return
    end

    -- 落盘成功就把压缩包删掉：它可能有好几 MB，没必要长期占着插件目录
    os.remove(zip_path)

    finish(T(_([[更新完成：%1 → %2

请手动重启 KOReader 让新版本生效（插件不会自己去重启你的阅读器）。

当前版本的备份在：%3
新版本有问题的话，把备份里的文件盖回去即可。]]),
            tostring(info and info.current or _("未知")),
            tostring(info and info.latest or _("未知")),
            tostring(backup_path)))
end

--[[--
查有没有新版本（走 Queue，和"测试连接"同一套异步写法）。

三种结果都要说清楚：
  · 有新版本 → 二次确认再装（下载安装是有副作用的动作，不该一个误触就跑起来）；
  · 已是最新 → 明确告诉他"这就是最新的了"，而不是什么都不说；
  · 查不到 → 把原因说出来（没网 / GitHub 没发布过 / 内容解析不出来），
    绝不静默——静默的话用户只会以为"检查过了，没有"，而真相可能是根本没查成功。
--]]
function SettingsUI:checkUpdate()
    --[[--
    进度提示**不能带 timeout**。

    下面这一步是 `Queue:submit` 的异步网络查询，真机上要跑好几秒。
    `timeout = 1` 的话那句话 1 秒就自己消失了，之后屏幕上什么都没有，
    直到结果窗口突然蹦出来——用户看到的实际效果是"点了没反应，隔半天才响一下"。
    所以让它常驻到结果回来为止，回来时**先 close 再 show 结果**：
    任何时刻手上一个弹层，既不叠层，也不会中途失联。
    --]]
    local progress = InfoMessage:new{
        text = T(_("%1正在检查更新…"), Prompts.PERSONA_NAME), -- luacheck: ignore
    }
    UIManager:show(progress)

    -- 结果窗口统一从这里出去：先收掉进度提示，再显示结果
    local function finish(widget)
        UIManager:close(progress)
        UIManager:show(widget)
    end

    Queue:submit({
        name = "check_update",
        retries = 1,
        fn = function()
            local info, err = Ota:checkForUpdate()
            if not info then return nil, err end
            return info
        end,
        on_done = function(info)
            if type(info) ~= "table" then
                -- 走到这里说明 fn 既没给结果也没抛错，静默等于让人以为"查过了，没有"
                finish(InfoMessage:new{ text = _("没有查到更新信息。") })
                return
            end
            if not info.available then
                finish(InfoMessage:new{
                    text = T(_([[已经是最新版本了。

当前版本：%1
GitHub 最新：%2]]), tostring(info.current), tostring(info.latest)),
                })
                return
            end
            -- 更新说明可能很长，先收短：确认框不是读长篇 Markdown 的地方。
            -- 完整的说明在 Release 页面上，地址一并给用户（他想细看时得有地方去）。
            local notes = type(info.notes) == "string" and info.notes or ""
            if #notes > 200 then
                notes = notes:sub(1, 200) .. "…"
            end
            local release_url = type(info.html_url) == "string" and info.html_url or ""
            finish(ConfirmBox:new{
                text = T(_([[发现新版本：%1 → %2

%3

更新说明：
%4

Release 页面：%5

会先给现在的版本打个备份，再下载安装。装完请手动重启 KOReader。]]),
                    tostring(info.current), tostring(info.latest),
                    tostring(info.name or ""), notes, release_url),
                ok_text = _("下载并安装"),
                cancel_text = _("以后再说"),
                ok_callback = function() SettingsUI:installUpdate(info) end,
            })
        end,
        on_error = function(err)
            finish(InfoMessage:new{
                text = T(_("没有查到更新信息：%1"), tostring(err)),
            })
        end,
    })
    Queue:process()
end

function SettingsUI:testConnection()
    if not DeepSeek:hasApiKey() then
        UIManager:show(InfoMessage:new{ text = _("请先配置 API Key") })
        return
    end
    --[[--
    与 `checkUpdate` 同一套写法：进度提示**不带 timeout**（这里要打一次真请求，几秒起步，
    `timeout = 1` 的提示 1 秒就消失，用户看到的是"点了没反应"）；结果出来前**先 close
    进度提示再 show**，任何时刻手上一个弹层。文案统一走「小望」，不写中性措辞。
    --]]
    local progress = InfoMessage:new{
        text = T(_("%1正在测试连接…"), Prompts.PERSONA_NAME), -- luacheck: ignore
    }
    UIManager:show(progress)
    local function finish(widget)
        UIManager:close(progress)
        UIManager:show(widget)
    end

    Queue:submit({
        name = "test_connection",
        fn = function()
            return DeepSeek:chat({
                { role = "system", content = "你是阅读助手，回答务必简短。" },
                { role = "user",   content = "用一句话说明《红楼梦》的作者是谁。" },
            }, { max_tokens = 128, temperature = 0.3 })
        end,
        on_done = function(result)
            -- result 可能是 nil（fn 既没返回也没抛错），直接取字段会崩
            local r = type(result) == "table" and result or {}
            finish(InfoMessage:new{
                text = T(_("连接成功\n\n模型回复：%1\n\n本次消耗：%2 tokens"),
                    r.content or "", tostring((r.usage or {}).total_tokens or "?")),
            })
        end,
        on_error = function(err)
            finish(InfoMessage:new{ text = _("连接失败：") .. tostring(err) })
        end,
    })
    Queue:process()
end

-- 余额展示用的货币符号；接口返回的是 ISO 代码（CNY / USD）
local CURRENCY_SYMBOL = {
    CNY = "¥",
    USD = "$",
}

--[[--
把余额结果排成一段可直接展示的文本。

必须把"总余额 / 充值余额 / 赠送余额"分开写：赠送余额有有效期，
用户看到总数多就够了，但想知道自己充了多少时不能让他猜。
--]]
function SettingsUI.formatBalance(res)
    if type(res) ~= "table" then return _("没有拿到余额信息") end

    local lines = { _("DeepSeek 账户余额"), "" }

    if type(res.balances) == "table" and #res.balances > 0 then
        -- 循环变量不能用 `_`：文件头 `local _ = require("gettext")` 会被它遮蔽，
        -- 循环体里再调 _("…") 就变成「attempt to call a number value」。
        -- 这个坑踩过一次（余额页正常路径必崩），所以这里一律用 _i。
        for _i, b in ipairs(res.balances) do
            local cur = tostring(b.currency or "?")
            local sym = CURRENCY_SYMBOL[cur] or ""
            lines[#lines + 1] = T(_("%1%2（%3）"),
                sym, tostring(b.total_balance or "?"), cur)
            if b.topped_up_balance ~= nil or b.granted_balance ~= nil then
                lines[#lines + 1] = T(_("  充值 %1%2 · 赠送 %3%4"),
                    sym, tostring(b.topped_up_balance or "0.00"),
                    sym, tostring(b.granted_balance or "0.00"))
            end
        end
    else
        lines[#lines + 1] = _("接口没有返回余额条目")
    end

    lines[#lines + 1] = ""
    if res.is_available == false then
        lines[#lines + 1] = _("状态：不可用（余额不足或未开通，调用会失败）")
    else
        lines[#lines + 1] = _("状态：可用")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = _("本查询只读，不消耗额度。")

    return table.concat(lines, "\n")
end

--[[--
查询账户余额（GET /user/balance）。

只查余额，不发任何书籍内容；失败要立刻报错（retries=0），
不要像聊天请求那样退避重试——重试会白等 1s+2s，界面像卡住。
--]]
function SettingsUI:queryBalance()
    if not DeepSeek:hasApiKey() then
        UIManager:show(InfoMessage:new{ text = _("请先配置 API Key") })
        return
    end
    -- 同上：进度提示不带 timeout，结果先关再弹，文案走「小望」
    local progress = InfoMessage:new{
        text = T(_("%1正在查询余额…"), Prompts.PERSONA_NAME), -- luacheck: ignore
    }
    UIManager:show(progress)
    local function finish(widget)
        UIManager:close(progress)
        UIManager:show(widget)
    end

    Queue:submit({
        name = "balance",
        retries = 0,
        fn = function() return DeepSeek:balance() end,
        on_done = function(res)
            finish(InfoMessage:new{ text = SettingsUI.formatBalance(res) })
        end,
        on_error = function(err)
            finish(InfoMessage:new{
                text = _("余额查询失败：") .. tostring(err),
            })
        end,
    })
    Queue:process()
end

local MODELS = {
    { key = "deepseek-chat",     text = _("deepseek-chat（常规，成本低）") },
    { key = "deepseek-reasoner", text = _("deepseek-reasoner（深度推理，成本高）") },
}

-- 防剧透粒度（PRD F4.5）
local GRANULARITIES = {
    {
        key = Spoiler.GRANULARITY_CHAPTER,
        text = _("按章节边界（推荐）"),
        help = _("用目录定位当前章节，未读章节的文本在进入请求前就被物理截断。"),
    },
    {
        key = Spoiler.GRANULARITY_COLLECTION,
        text = _("按作品（合集）"),
        help = _([[一本 epub 里含多部独立作品时用这个（如《十本书读懂阿加莎》）。

读合集的人不会从头读到尾，而是直接跳到其中某一部去读；按"读到第几章"判断的话，
排在它前面的那些部会被误判成已读而剧透。选这项后，除当前在读的那一部之外，
其余各部不论排在前面还是后面都算未读。]]),
    },
    {
        key = Spoiler.GRANULARITY_PERCENT,
        text = _("按全书百分比"),
        help = _("没有可用目录时的粗粒度方案：按当前进度比例限制「向前看」的文本量。"),
    },
}

-- 合集判定的三种取值（对应 Config 的 spoiler_collection）
local COLLECTION_MODES = {
    {
        key = Spoiler.COLLECTION_AUTO,
        text = _("自动识别（默认）"),
        help = _("按目录结构自动判断：一级条目不少于 3 个、条目下还有更深层级，"
            .. "且一级标题不大多是「第 X 章/篇/卷/部」这类序号式标题时，判为合集。"),
    },
    {
        key = Spoiler.COLLECTION_ON,
        text = _("是，本书是合集"),
        help = _("强制按合集隔离：目录里的每个一级条目都当作一部独立作品，"
            .. "当前部之外的全都算未读。自动识别漏判时用这个。"),
    },
    {
        key = Spoiler.COLLECTION_OFF,
        text = _("不是合集"),
        help = _("强制按普通单本书处理：只有当前位置之后的章节算未读。"
            .. "自动识别误判（如带卷/篇结构的小说）时用这个。"),
    },
}

--[[--
章末自动询问的两种取值（对应 Config 的 chapter_summary_prompt）。

只有"关 / 每章问一次"两项，没有"每 N 章问一次"这类中间档：
中间档要么得记住"上次问的是第几章"（跨重启、跨书的状态），要么会退化成
随机问 —— 那正是要治的骚扰。真要少问一点，用下面的"一天最多几次"更直白。
--]]
local CHAPTER_PROMPT_MODES = {
    {
        key = "off",
        text = _("关（默认）"),
        help = _("只在自己点「总结本章」时才总结。系统不会主动弹窗，也不会花钱。"),
    },
    {
        key = "ask_each_chapter",
        text = _("每读完一章问一次"),
        help = _([[读完一整章、翻进下一章时弹一句「要不要让小望总结这一章？」。

同一章一天只问一次（倒着翻回去再翻过来不会重复问），并且受下面的
「一天最多几次」限制。选「不用了」之后这一章今天也不再问第二次 ——
**弹窗即记账，与成败无关**（这是刻意的：不然就成了骚扰）。所以自动问过的
那一章今天不会再自动弹；想重试或者当时选了「不用了」，用上面的
「总结本章」手动入口，随时都能再来一次。]]),
    },
}

-- 一天最多问几次（0 = 不限次，见 Chapter.canAuto：<= 0 就是不卡配额）
local CHAPTER_QUOTA_MODES = {
    { key = 1, text = _("一天 1 次"), help = _("最安静：一天里最多问你一次。") },
    { key = 3, text = _("一天 3 次（默认）"), help = _("一天里最多问 3 次，够用又不至于烦。") },
    { key = 5, text = _("一天 5 次"), help = _("一天里最多问 5 次。回目很密的书可以用这个。") },
    { key = 0, text = _("不限次"), help = _("不卡次数，只看「同一章一天一次」这一条。") },
}

local function collectionModeName(key)
    if key == Spoiler.COLLECTION_ON then return _("是") end
    if key == Spoiler.COLLECTION_OFF then return _("不是") end
    return _("自动")
end

--[[--
无目录时的强度说明。

书没有可用目录时，"进度百分之几"只能估算每一句话是否已读 —— 这不是隔离，
只是把暴露窗口压小。必须对用户讲清楚，否则他会以为关掉开关之外的所有情况
都已经挡住了。
--]]
local function fallbackNotice(prog)
    if type(prog) ~= "table" or prog.granularity_auto ~= true then return "" end
    return T(_([[

注意：这本书没有可用的目录，找不到章节边界。
此时的防护是**弱防护**——只会把向后看的原文压缩到 %1 字以内，并不能保证
紧贴阅读位置之后的句子一定是已读的。想要真正的章节级隔离，请换用带目录的
EPUB，或暂时关闭依赖语境的功能。]]), tostring(Spoiler.AUTO_FALLBACK_MAX_CHARS))
end

--[[--
合集状态一句话（设置页用）。
自动识别只能给"疑似"，最终判定权在用户手上，所以这里必须把"生效/未生效 + 原因"
说清楚，否则用户会以为一切都挡住了。
--]]
local function collectionStatus(prog)
    if type(prog) ~= "table" then return _("未识别到阅读进度") end
    if prog.collection_active then
        if type(prog.work_index) == "number" and prog.work_index >= 1
            and type(prog.work_total) == "number" then
            return T(_("生效：当前第 %1 / %2 部%3，其余各部全部算未读"),
                tostring(prog.work_index), tostring(prog.work_total),
                (type(prog.work_title) == "string" and prog.work_title ~= "")
                    and ("（" .. prog.work_title .. "）") or "")
        end
        return _("生效：还没进入第 1 部，全部未读")
    end
    if prog.collection_detected then
        return _("未生效：目录疑似合集，但当前设置按普通单本书处理")
    end
    return _("未生效：未识别为合集（只有当前位置之后的章节算未读）")
end

--[[--
合集诊断页（PRD F4.5：把判定依据讲给用户，让他能自己拍板）。
--]]
function SettingsUI:collectionDiagnose(plugin)
    local prog = (plugin and plugin.currentProgress) and plugin:currentProgress() or nil
    local detected = (type(prog) == "table" and prog.collection_detected == true)
    local active = (type(prog) == "table" and prog.collection_active == true)
    local mode = Config:get("spoiler_collection") or Spoiler.COLLECTION_AUTO
    local works = (type(prog) == "table" and type(prog.work_total) == "number")
        and tostring(prog.work_total) or _("未知")

    local hint
    if active then
        hint = _([[已按合集隔离：除当前这一部之外的其余各部（不论排在它前面还是后面），
以及当前这一部里你还没读到的章节，都不会进入发给 AI 的内容。]])
    elseif detected then
        hint = _([[这本书的目录看起来像合集：一级条目下还有更深一层的章节。
若它确实是合集，请把「本书是合集」设为「是」，否则排在前面的那些部会被当成已读。]])
    else
        hint = _([[未识别为合集，按普通单本书处理：只有当前位置之后的章节算未读。
如果这本书其实是合集（一本里含多部独立作品），请手动把开关设为「是」。]])
    end

    return T(_([[· 目录一级条目数（作品数）：%1
· 自动识别结果：%2
· 「本书是合集」开关：%3
· 隔离状态：%4

%5

自动识别阈值：一级条目不少于 %6 个，且条目下还有更深层级的章节，
且一级标题不大多是「第 X 章 / 篇 / 卷 / 部」这类序号式标题。]]),
        works,
        detected and _("疑似合集") or _("不像合集"),
        collectionModeName(mode),
        collectionStatus(prog),
        hint,
        tostring(Spoiler.COLLECTION_MIN_WORKS))
end

--[[--
防剧透子菜单（PRD F4.1 全局开关 + F4.5 粒度选择 + 合集判定 + 当前进度展示）。
所有改动即时写入 Config，下一次提问立刻生效。
--]]
function SettingsUI:buildSpoilerMenu(plugin)
    local items = {}

    items[#items + 1] = {
        text = _("启用防剧透"),
        checked_func = function() return Config:get("spoiler_guard") == true end,
        callback = function()
            local v = Config:get("spoiler_guard")
            Config:set("spoiler_guard", not v)
            UIManager:show(InfoMessage:new{
                text = (not v) and _("防剧透已开启：未读章节不会进入发给 AI 的内容")
                              or _("防剧透已关闭：AI 可以看到完整上下文"),
            })
        end,
    }

    items[#items + 1] = {
        text = _("截断粒度"),
        sub_item_table = (function()
            local subs = {}
            for _i, g in ipairs(GRANULARITIES) do
                subs[#subs + 1] = {
                    text = g.text,
                    help_text = g.help,
                    checked_func = function() return Config:get("spoiler_granularity") == g.key end,
                    callback = function()
                        Config:set("spoiler_granularity", g.key)
                        UIManager:show(InfoMessage:new{
                            text = T(_("已切换为：%1\n\n%2"), g.text, g.help),
                        })
                    end,
                }
            end
            return subs
        end)(),
    }

    -- 合集判定（M3-COL）：自动识别是猜测，用户必须能强制开关
    items[#items + 1] = {
        text_func = function()
            return T(_("本书是合集（%1）"),
                collectionModeName(Config:get("spoiler_collection"))) -- luacheck: ignore
        end,
        sub_item_table = (function()
            local subs = {}
            for _i, m in ipairs(COLLECTION_MODES) do
                subs[#subs + 1] = {
                    text = m.text,
                    help_text = m.help,
                    checked_func = function()
                        return (Config:get("spoiler_collection") or Spoiler.COLLECTION_AUTO) == m.key
                    end,
                    callback = function()
                        Config:set("spoiler_collection", m.key)
                        UIManager:show(InfoMessage:new{
                            text = T(_("已设为：%1\n\n%2"), m.text, m.help),
                        })
                    end,
                }
            end
            return subs
        end)(),
    }

    items[#items + 1] = {
        text = _("合集判定诊断"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(InfoMessage:new{ text = SettingsUI:collectionDiagnose(plugin) })
        end,
    }

    items[#items + 1] = {
        text = _("查看当前识别到的进度"),
        keep_menu_open = true,
        callback = function()
            local prog = nil
            if plugin and plugin.currentProgress then
                prog = plugin:currentProgress()
            end
            local label = Spoiler.progressLabel(prog)
            local detail
            if type(prog) == "table" and prog.ok then
                detail = T(_([[当前进度：%1

· 定位方式：%2
· 文档类型：%3
· 截断粒度：%4
· 未读章节标题数：%5

防剧透会用这个位置决定截断点。若显示「未识别到阅读进度」，
防剧透会退化为只靠提示词约束，不会阻塞你的提问。]]),
                    label,
                    tostring(prog.source or "未知"),
                    prog.has_pages and _("分页文档（PDF 类）") or _("滚动文档（EPUB 类）"),
                    prog.granularity_auto and _("百分比（无可用目录，已自动回落）")
                        or (prog.granularity == Spoiler.GRANULARITY_PERCENT and _("百分比") or _("章节边界")),
                    tostring(prog.unread_titles and #prog.unread_titles or 0))
                    .. fallbackNotice(prog)
                    .. "\n\n· 合集判定：" .. collectionStatus(prog)
            else
                detail = T(_([[当前进度：%1

没有读到有效的页码/目录信息，防剧透退化为只靠提示词约束，不阻塞提问。]]), label)
            end
            UIManager:show(InfoMessage:new{ text = detail })
        end,
    }

    return items
end

--[[--
AI 回复风格子菜单（7 选 1，单选 = 后选的覆盖先选的）。
选项列表直接取自 Prompts.STYLES，不在 UI 里复制一份：
加风格时只改 prompts.lua 一处，菜单自动跟上。
--]]
function SettingsUI:buildReplyStyleMenu()
    local subs = {}
    -- 循环变量用 _i：文件头 `local _ = require("gettext")` 会被 `_` 遮蔽成数字，
    -- 循环体里再调 _("…") 就是「attempt to call a number value」。
    for _i, s in ipairs(Prompts.STYLES) do
        subs[#subs + 1] = {
            text = _(s.text),
            help_text = _(s.help),
            checked_func = function()
                return Prompts.normalizeStyleKey(Config:get("reply_style")) == s.key
            end,
            callback = function()
                Config:set("reply_style", s.key)
                UIManager:show(InfoMessage:new{
                    text = T(_([[已切换 AI 回复风格：%1
回复时请以“%2”的身份说话。

%3

下一次提问立即生效；同一段话按风格分别缓存，换风格不会命中旧回答。]]),
                        _(s.text), Prompts.PERSONA_NAME, _(s.help)),
                })
            end,
        }
    end
    return subs
end

--[[--
「我的问答收藏」子菜单。

五个入口各自的范围都写在标题里（本书 / 全部 / 搜索 / 导出本书 / 导出全部），
因为"收藏在哪儿"这件事用户最容易记混：收藏跟着书走，不在一本书里。

导出为什么放在这里而不是另起一级菜单：导出是"把收藏带走"的动作，
跟"看收藏"是同一件事的后半段——用户想起来要导出的时候，一定是在看收藏的时候。
--]]
function SettingsUI:buildFavoritesMenu(plugin)
    local function currentBookFp()
        if plugin and plugin.bookFingerprint then return plugin:bookFingerprint() end
        return nil
    end
    local function currentBookTitle()
        if plugin and plugin.bookTitle then return plugin:bookTitle() end
        return nil
    end

    --[[--
    没开书时，与"本书"有关的项一律不出现。

    真机反馈：从文件管理器（没打开任何书）进「我的问答收藏」，子菜单里还挂着
    「本书收藏」，点进去只会弹一句"当前没有打开的书"——那不是提示，
    是把一个用不了的按钮摆在那儿让人点。

    `addToMainMenu` 每次打开菜单都会重新调用本函数，所以这里按当前有没有书
    动态决定加不加就行，不需要额外的刷新机制。

    「导出 Markdown（本书）」是同一个毛病，一起隐藏（用户只点名了「本书收藏」）。

    **判据必须是 `plugin:hasOpenBook()`，不能是"取到的书指纹非 nil"** ——
    `bookFingerprint()` 没书时返回的是字符串 `"unknown"`，不是 nil，
    于是 `(fp ~= nil)` 恒为真，这两项永远藏不掉（第一次改就栽在这里）。
    布尔默认值给 **false**：桩环境里 plugin 没有 `hasOpenBook` 时就得当成"没开书"，
    反过来默认 true 会让这个开关在最该隐藏的时候一直藏着 Bug。
    --]]
    local has_book = false
    if plugin and type(plugin.hasOpenBook) == "function" then
        has_book = (plugin:hasOpenBook() == true)
    end

    local items = {}

    if has_book then
        items[#items + 1] = {
            text = _("本书收藏"),
            keep_menu_open = true,
            callback = function()
                --[[--
                打开列表之前先把老数据的章节补准。

                回填要依赖"当前打开着的这本书的目录"，所以它只能在**有书时**做；
                pcall 包住是必须的：回填是顺手做的善后，它本身出任何问题都不能
                挡住"看看我的问答收藏"这件正事。
                --]]
                if plugin and type(plugin.backfillFineChapters) == "function" then
                    pcall(plugin.backfillFineChapters, plugin)
                end
                Favorites:showBookFavorites(currentBookFp(), currentBookTitle())
            end,
        }
    end

    items[#items + 1] = {
        text = _("全部收藏"),
        help_text = _("按书名分组，组内按时间倒序。收藏跟着书走，不在一本书里。"),
        keep_menu_open = true,
        callback = function()
            -- 跨书视图也一样：当前这本书的收藏要在里面显示对的回目名
            if plugin and type(plugin.backfillFineChapters) == "function" then
                pcall(plugin.backfillFineChapters, plugin)
            end
            Favorites:showAllFavorites()
        end,
    }
    items[#items + 1] = {
        text = _("搜索收藏与历史"),
        help_text = _("在所有书里搜索：命中提问、引文，以及小望的回复。"),
        keep_menu_open = true,
        callback = function() Favorites:askSearch(nil) end,
    }

    if has_book then
        items[#items + 1] = {
            text = _("导出 Markdown（本书）"),
            help_text = _("把这本书的收藏写成 Markdown，文件落在插件目录里，连上电脑拷走。"),
            keep_menu_open = true,
            callback = function() Favorites:exportBook(currentBookFp()) end,
        }
    end

    items[#items + 1] = {
        text = _("导出 Markdown（全部）"),
        help_text = _("把所有书收藏写成一个文件，按书分组。文件名里带导出时间，不会互相覆盖。"),
        keep_menu_open = true,
        callback = function() Favorites:exportAll() end,
    }

    return items
end

function SettingsUI:buildMenu(plugin)
    local items = {}

    -- 高频入口放最前（一级子菜单，点击即达）
    items[#items + 1] = {
        text = _("呼出 AI 助手"),
        keep_menu_open = true,
        callback = function()
            if plugin and plugin.onYWBFOpenAssistant then
                plugin:onYWBFOpenAssistant()
            end
        end,
    }

    --[[--
    章末总结的**手动入口**（望仔拍板第 3 项）。

    它必须常驻，且**不受开关影响**：章末自动询问是默认关的，而自动询问是
    "系统主动发起、每章真花钱"，跟用户自己点一下性质完全不同。
    关着自动询问的人照样该能手动总结（成本为零，不点不花钱）。

    放在一级菜单最前面：它跟「呼出 AI 助手」一样是"点了就有反馈"的高频动作，
    埋进子菜单里等于没有。
    --]]
    items[#items + 1] = {
        text = _("总结本章"),
        keep_menu_open = true,
        help_text = _([[把当前这一整章交给小望详细、全面、多角度地总结一遍。

必须**读完这一章**才给总结（读到一半会提示你先读完）——这是防剧透的硬闸：
未读的正文根本不会进到发送给 AI 的内容里。

章末自动询问关掉也照样能用这个入口，不点就不花钱。

自动问过的那一章今天不会再自动弹（弹窗即记账，与成败无关）；任何时候
想再总结一次，点这里就行 —— 包括当时选了「不用了」的那一章。]]),
        callback = function()
            if plugin and plugin.summarizeCurrentChapter then
                plugin:summarizeCurrentChapter()
            end
        end,
    }

    --[[--
    章末自动询问的**开关**（望仔拍板第 3 项：默认关）。

    为什么必须有这一项：第 4 步做完之后，自动弹窗是"系统主动发起、每章真花钱"
    的动作，而 `chapter_summary_prompt` 的默认值是 `"off"` —— 没有这个开关的话
    它永远打不开，第 4 步等于白做。手动入口「总结本章」不受它影响（不点不花钱）。
    --]]
    items[#items + 1] = {
        text = _("章末自动询问"),
        sub_item_table = (function()
            local subs = {}
            for _i, m in ipairs(CHAPTER_PROMPT_MODES) do
                subs[#subs + 1] = {
                    text = m.text,
                    help_text = m.help,
                    checked_func = function()
                        return (Config:get("chapter_summary_prompt") or "off") == m.key
                    end,
                    callback = function()
                        Config:set("chapter_summary_prompt", m.key)
                        UIManager:show(InfoMessage:new{
                            text = T(_("已设为：%1\n\n%2"), m.text, m.help),
                        })
                    end,
                }
            end
            return subs
        end)(),
    }

    --[[--
    一天最多问几次。

    有开关还不够：一本回目极多的书（哈利波特 254 条目录）一晚上能翻十几章，
    "每章都问"就是骚扰 —— 而骚扰的下场是用户把整个开关关掉，那这一期就白做了。
    所以这个上限要让用户自己能拧。
    --]]
    items[#items + 1] = {
        text = _("章末询问：一天最多几次"),
        sub_item_table = (function()
            local subs = {}
            for _i, m in ipairs(CHAPTER_QUOTA_MODES) do
                subs[#subs + 1] = {
                    text = m.text,
                    help_text = m.help,
                    checked_func = function()
                        return (Config:get("chapter_summary_max_per_day") or 3) == m.key
                    end,
                    callback = function()
                        Config:set("chapter_summary_max_per_day", m.key)
                        UIManager:show(InfoMessage:new{
                            text = T(_("已设为：%1\n\n%2"), m.text, m.help),
                        })
                    end,
                }
            end
            return subs
        end)(),
    }

    -- API Key
    local current = DeepSeek:getApiKey()
    items[#items + 1] = {
        text = _("API Key 配置"),
        keep_menu_open = true,
        -- 括号里只给状态，不给内容（见 showApiKeyDialog 上方那段说明）
        text_func = function()
            return DeepSeek:getApiKey()
                and _("API Key 配置（已设置）")
                or _("API Key 配置（未设置）")
        end,
        callback = function() SettingsUI:showApiKeyDialog() end,
    }

    items[#items + 1] = {
        text = _("从文件导入 API Key"),
        keep_menu_open = true,
        callback = function() SettingsUI:importApiKeyFromFile() end,
    }

    items[#items + 1] = {
        text = _("测试 DeepSeek 连接"),
        keep_menu_open = true,
        callback = function() SettingsUI:testConnection() end,
    }

    -- 模型选择
    local model_items = {}
    for _i, m in ipairs(MODELS) do
        model_items[#model_items + 1] = {
            text = m.text,
            checked_func = function() return Config:get("model") == m.key end,
            callback = function()
                Config:set("model", m.key)
                UIManager:show(InfoMessage:new{ text = T(_("已切换模型：%1"), m.key) })
            end,
        }
    end
    items[#items + 1] = {
        text = _("模型选择"),
        sub_item_table = model_items,
    }

    -- AI 回复风格（7 选 1）：parent 项实时显示当前风格，不用点进去才知道选了啥
    items[#items + 1] = {
        text = _("AI 回复风格"),
        help_text = T(_([[
决定“%1”用什么样的语气说话——无论选哪一种，跟你对话的都是他。

只影响表达方式，不影响事实边界：无论哪种风格，都仍受「只基于上下文回答」
和防剧透约束的限制，两者冲突时以那些约束为准。]]), Prompts.PERSONA_NAME),
        text_func = function()
            return T(_("AI 回复风格（%1）"),
                _(Prompts.styleText(Config:get("reply_style")))) -- luacheck: ignore
        end,
        sub_item_table = SettingsUI:buildReplyStyleMenu(),
    }

    -- 防剧透（M3：开关 + 粒度 + 进度自检，改完即时生效）
    items[#items + 1] = {
        text = _("防剧透模式"),
        text_func = function()
            local on = Config:get("spoiler_guard") == true
            local g = Config:get("spoiler_granularity")
            local gname = (g == Spoiler.GRANULARITY_PERCENT) and _("百分比")
                or (g == Spoiler.GRANULARITY_COLLECTION and _("作品") or _("章节"))
            return T(_("防剧透模式（%1 · %2）"), on and _("已开启") or _("已关闭"), gname) -- luacheck: ignore
        end,
        sub_item_table = SettingsUI:buildSpoilerMenu(plugin),
    }

    -- 收藏与回顾（阶段一：列表 + 关键词检索）
    items[#items + 1] = {
        text = _("我的问答收藏"),
        sub_item_table = SettingsUI:buildFavoritesMenu(plugin),
    }

    -- 轻问的异步回复入口
    items[#items + 1] = {
        text = _("查看最近回复"),
        keep_menu_open = true,
        callback = function()
            if plugin and plugin.showLastReply then
                plugin:showLastReply()
            end
        end,
    }

    -- 轻问回复的呈现方式（默认直接弹出，不用去菜单里找）
    items[#items + 1] = {
        text = _("轻问回复直接弹出"),
        help_text = _([[
开启（默认）：轻问的回复到达后直接弹出结果卡片，问题和回答一起显示，不必去菜单里翻。
关闭：只在顶部发一条通知，回复存在「查看最近回复」里，不打断你的阅读。]]),
        checked_func = function() return Config:get("light_auto_popup") ~= false end,
        callback = function()
            local v = Config:get("light_auto_popup")
            Config:set("light_auto_popup", not v)
            UIManager:show(InfoMessage:new{
                text = (not v) and _("轻问回复会直接弹出")
                              or _("轻问只在顶部通知，回复可在「查看最近回复」中查看"),
            })
        end,
    }

    -- 「你可能想问」：给提不出问题的用户几条本地生成的建议问题
    items[#items + 1] = {
        text = _("提问框显示建议问题"),
        help_text = _([[开启（默认）：深聊和轻问的输入框里多一个「你可能想问」入口，
        点开是几条根据当前选中文本现算的问题，选中后回填到输入框，可改可发。

        建议问题是本地生成的，不走 AI，不消耗额度、也不用等网络。
        觉得占地方就关掉。]]),
        checked_func = function() return Config:get("show_suggestions") ~= false end,
        callback = function()
            local v = Config:get("show_suggestions")
            Config:set("show_suggestions", not v)
            UIManager:show(InfoMessage:new{
                text = (not v) and _("提问框会显示「你可能想问」")
                              or _("提问框不再显示建议问题"),
            })
        end,
    }

    -- 「你可能想问」里的 AI 出题按钮（kind = ideas）
    items[#items + 1] = {
        text = T(_("让%1帮我提问"), Prompts.PERSONA_NAME),
        help_text = T(_([[开启（默认）：「你可能想问」里多一个「让%1来问（用一次额度）」按钮，
        点一下由 AI 针对你选中的那段文字现出几条问题。

        这跟本地建议不是一回事：本地那几条是通用的（「这段讲了什么」），
        AI 才能问出「他为什么偏偏在这个时点说这句话」这种贴着文本的问题。

        代价是它会真实调用一次 API（上限 300 token），所以按钮上写明了「用一次额度」。
        同一段文字再点会命中缓存，不重复花钱。
        不想花这个额度就关掉，关掉后「你可能想问」仍是零开销的本地建议。

        同样受防剧透保护：AI 只会基于你已经读到的内容提问。]]), Prompts.PERSONA_NAME),
        checked_func = function() return Config:get("ai_suggestions") ~= false end,
        callback = function()
            local v = Config:get("ai_suggestions")
            Config:set("ai_suggestions", not v)
            UIManager:show(InfoMessage:new{
                text = (not v) and T(_("「你可能想问」里会出现「让%1来问」按钮"), Prompts.PERSONA_NAME)
                              or _("「你可能想问」只保留本地建议，不再消耗额度"),
            })
        end,
    }

    -- 用量统计
    items[#items + 1] = {
        text = _("用量统计"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(InfoMessage:new{ text = Tokens.formatUsage() })
        end,
    }

    -- 账户余额（只读取 DeepSeek 的 /user/balance，不携带任何书籍内容）
    items[#items + 1] = {
        text = _("查询账户余额"),
        help_text = _([[向 api.deepseek.com 查询当前 API Key 还剩多少额度。

只读取余额，不发送任何书籍正文或选中文本，也不消耗额度。]]),
        keep_menu_open = true,
        callback = function() SettingsUI:queryBalance() end,
    }

    -- 数据与隐私
    items[#items + 1] = {
        text = _("数据与隐私"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(InfoMessage:new{
                text = T(_([[数据位置：%1

· 阅读进度、笔记、对话、X-Ray 数据全部只存本机插件目录
· AI 请求只在你主动触发时发生，且仅发往 api.deepseek.com
· 插件无任何使用统计上报]]), tostring(Config.paths.data)),
            })
        end,
    }

    items[#items + 1] = {
        text = _("关于远望书友"),
        keep_menu_open = true,
        -- 插件简介挪到这里（长按可见）：原来它是子菜单里一个"点了没反应"的死项
        help_text = PLUGIN_DESCRIPTION,
        text_func = function()
            local v = Config.VERSION
            return T(_("关于远望书友（v%1）"), (type(v) == "string" and v) or _("未知")) -- luacheck: ignore
        end,
        sub_item_table = SettingsUI:buildAboutMenu(),
    }

    items[#items + 1] = {
        text = _("清空全部本地数据"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("将删除对话记录、缓存与 X-Ray 数据（不含 API Key）。确定？"),
                ok_text = _("删除"),
                cancel_text = _("取消"),
                ok_callback = function()
                    -- TODO(M4/M5)：实现目录清理
                    UIManager:show(InfoMessage:new{ text = _("（M1 占位）清理功能将在后续里程碑实现") })
                end,
            })
        end,
    }

    return items
end

return SettingsUI
