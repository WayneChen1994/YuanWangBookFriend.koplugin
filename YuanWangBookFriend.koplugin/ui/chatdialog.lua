--[[--
深聊模式（PRD F1.1）：连续多轮对话。

交互形态：提问 → 看到完整对话（问与答成对呈现，可滚动）→ 继续追问 → …
直到用户点「结束」。历史会作为多轮上下文传给模型，因此能像聊天一样接着聊。

墨水屏适配：纯文本展示、无动画、对话整体可滚动；每轮回答后停留在对话页，
用户一眼能看到"我问了什么 / 它答了什么"，不需要回菜单翻记录。

防剧透：进度每轮实时重取（用户可能在对话期间翻页），
多轮历史在 DeepSeek:chat 出口统一截断。
--]]

local Asker = require("ui/asker")
local Prompts = require("ywbf/prompts")
local SuggestPicker = require("ui/suggestpicker")
local Util = require("ywbf/util")

local Device = require("device")
local Font = require("ui/font")
local Size = require("ui/size")
local RenderText = require("ui/rendertext")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local ChatDialog = {}

-- description 里最多展示多少个字符（超出部分在「查看选中原文」里看）
local PREVIEW_CHARS = 100

--[[--
分隔线。

两处坑，都是从真机上来的：
  · 字符必须选 U+2014 中文破折号，不能选 ─ ━ 那类制表符：
    墨水屏字体缺字时会渲染成方块；
  · 长度必须按屏幕算，不能写死一串：KPW4 是 1072px 宽，写死 16 个破折号
    只占掉三分之一行（用户看到的就是"分隔线没占满整行"），
    换成更宽的屏就差得更多，反过来在 600px 的小屏上又会折成两行。

TextViewer 的默认几何（frontend/ui/widget/textviewer.lua）：
    width      = Screen:getWidth() - Screen:scaleBySize(30)
    文本区宽    = width - 2*text_padding - 2*text_margin
    text_padding = Size.padding.large, text_margin = Size.margin.small
    face       = Font:getFace("x_smallinfofont")
这里照抄同一套公式，再按实际字形宽度换算字符个数。
任何一步量不出来（例如无头环境没有 Screen）就退回固定长度，绝不报错。
--]]
local SEP_CHAR = "—"  -- U+2014
local SEP_FALLBACK = string.rep(SEP_CHAR, 24)

local function buildSeparator()
    local ok, sep = pcall(function()
        local screen = Device.screen
        if not screen or not screen.getWidth then return SEP_FALLBACK end

        local face = Font:getFace("x_smallinfofont")
        local unit = RenderText:sizeUtf8Text(0, nil, face, SEP_CHAR, true, false)
        if type(unit) ~= "table" or type(unit.x) ~= "number" or unit.x <= 0 then
            return SEP_FALLBACK
        end

        -- 可用宽再打 4% 的折扣后才去排字符。
        -- 为什么必须留余量：用户实测"分隔线多出一个字符、被挤到下一行"，
        -- 说明按几何算出来的可用宽比 TextBoxWidget 实际断行用的宽度略大
        -- （字体回退、字距微调、不同机型 scaleBySize 的取整差异都会贡献这点误差）。
        -- 压满到 100% 换来的只是 1~2 个字符的观感，翻车的代价是多出一行，不值。
        local usable = (screen:getWidth() - screen:scaleBySize(30)
                       - 2 * Size.padding.large - 2 * Size.margin.small) * 0.96
        local measure = function(s)
            local m = RenderText:sizeUtf8Text(0, nil, face, s, true, false)
            return type(m) == "table" and m.x or 0
        end

        local s = Util.fillLine(usable, unit.x, SEP_CHAR, measure)
        if s == "" then return SEP_FALLBACK end
        -- 这几个数写进日志：分隔线到底有没有铺满，看一眼就知道，
        -- 不必靠用户在墨水屏上目测（usable 与 n*unit 越接近越好）
        logger.info(string.format(
            "YWBF: separator usable=%.0fpx unit=%.1fpx chars=%d -> %.0fpx",
            usable, unit.x, Util.utf8len(s),
            (RenderText:sizeUtf8Text(0, nil, face, s, true, false).x)))
        return s
    end)
    if ok and type(sep) == "string" and sep ~= "" then return sep end
    return SEP_FALLBACK
end

--[[--
生成「已选中：…」预览。
必须用 Util.preview：中文 3 字节，string.sub 按字节切会切在汉字中间变乱码。
--]]
local function previewLine(text)
    local txt, total, truncated = Util.preview(text, PREVIEW_CHARS)
    if txt == "" then return nil end
    if truncated then
        return T(_("已选中：%1…（共 %2 字）"), txt, tostring(total))
    end
    return _("已选中：") .. txt
end

--[[--
@param plugin 插件实例（预留：后续可把对话落到历史里）
@param opts { selected, page_text, book_fp, progress, seed_question }
--]]
function ChatDialog:open(plugin, opts)
    opts = opts or {}

    -- 这两个 local 必须在任何闭包之前声明：Lua 词法作用域下写在后面会让
    -- 闭包里的 selected_clean 解析成全局变量（拿到 nil）——之前出过这个 bug。
    local selected = opts.selected or ""
    local selected_clean = Util.sanitizeForDisplay(selected)

    -- 一轮对话 = { q = 问题, a = 回答 }
    local turns = {}

    -- 前向声明：askInput 与 ask 互相引用
    local askInput, ask

    -- 轮与轮之间的分隔线。用中文破折号而不是 ─ ━ 之类的制表符：
    -- 墨水屏字体对 U+2500 那类符号缺字时会渲染成方块。
    -- 长度按屏幕宽度现算（见 buildSeparator）：写死一串在宽屏上只占一小截。
    local function separator()
        return buildSeparator()
    end

    -- 某一轮的完整文本（分隔线 + 「第 N 轮」+ 问 + 答）
    local function renderTurn(i)
        local t = turns[i]
        return T(_("第 %1 轮"), tostring(i)) .. "\n"
            .. T(_("【问】%1"), t.q) .. "\n\n"
            -- 答的标签直接用角色名（Prompts.PERSONA_NAME = "小望"）：
            -- 用户要能一眼看出这是谁在说话，也避免改名时这里漏改。
            .. T(_("【%1】%2"), Prompts.PERSONA_NAME, t.a)
    end

    -- 完整对话：每轮之间用分隔线隔开，一眼能看出边界在哪
    local function renderAll()
        local parts = {}
        -- 循环变量不用 `_`：文件头 `local _ = require("gettext")` 会被遮蔽
        for i in ipairs(turns) do
            if i > 1 then parts[#parts + 1] = separator() end
            parts[#parts + 1] = renderTurn(i)
        end
        return table.concat(parts, "\n")
    end

    -- 只渲染最新一轮：多轮之后用户要的是「刚才那个回答」，
    -- 让他每次都从第一轮重新划到底太折磨人了。
    local function renderLatest()
        local i = #turns
        local t = turns[i]
        if not t then return "" end
        local head = ""
        if i > 1 then
            head = T(_("（共 %1 轮对话 · 当前显示最新一轮）"), tostring(i)) .. "\n\n"
        end
        return head .. renderTurn(i)
    end

    -- 多轮上下文：交替 user/assistant
    local function historyForModel()
        local h = {}
        for _i, t in ipairs(turns) do
            h[#h + 1] = { role = "user", content = t.q }
            h[#h + 1] = { role = "assistant", content = t.a }
        end
        if #h == 0 then return nil end
        return h
    end

    --[[--
    关掉所有"一划就消失"的手势，只允许点按钮关闭。

    TextViewer 默认有两个坑：
      · onMultiSwipe：任意多指滑动直接 onClose()；
      · onSwipe 落在文本区域外时交给 MovableContainer，同样可能关闭。
    用户在多轮对话里想往上翻看内容，一划就把窗口划没了，非常恼火。
    这里全部吞掉，只保留按钮（继续追问 / 完整对话 / 结束）来关闭。
    --]]
    local function hardenAgainstSwipeClose(viewer)
        viewer.onMultiSwipe = function() return true end
        viewer.onTapClose = function() return true end
        viewer.onSwipe = function(self_, arg, ges)
            if ges and ges.pos and self_.textw and ges.pos:intersectWith(self_.textw.dimen) then
                -- 区内：沿用原生逻辑（左右滑动翻页）
                return TextViewer.onSwipe(self_, arg, ges)
            end
            -- 区外：吞掉，绝不交给 MovableContainer 触发关闭
            return true
        end
    end

    -- 对话页：默认展示最新一轮，可切到完整对话；底部给「继续追问 / 结束」
    local function showConversation(view_all)
        local n = #turns
        local viewer
        viewer = TextViewer:new{
            title = T(_("远望书友-深聊（第 %1 轮）"), tostring(n)),
            text = view_all and renderAll() or renderLatest(),
            buttons_table = {
                {
                    {
                        text = _("继续追问"),
                        is_enter_default = true,
                        callback = function()
                            UIManager:close(viewer)
                            askInput()
                        end,
                    },
                    {
                        text = view_all and _("只看最新一轮") or _("查看完整对话"),
                        enabled = n > 1,
                        callback = function()
                            UIManager:close(viewer)
                            showConversation(not view_all)
                        end,
                    },
                },
                {
                    {
                        text = _("结束"),
                        callback = function()
                            UIManager:close(viewer)
                        end,
                    },
                },
            },
        }
        hardenAgainstSwipeClose(viewer)
        UIManager:show(viewer)
    end

    ask = function(question)
        table.insert(turns, { q = question, a = _("（等待回复…）") })
        local idx = #turns

        Trapper:wrap(function()
            -- 与即时提问共用同一个出口（Asker:thinkingText），改文案只需改一处
            Trapper:info(Asker:thinkingText())
            -- 每轮实时重取进度：对话期间用户可能已经翻页，用进入时的旧进度会误判
            local prog = Asker:fetchProgress() or opts.progress
            local content, err, from_cache, spoiler_hit = Asker:askSync({
                kind = "chat",
                title = _("远望书友-深聊"),
                selected = selected_clean,
                page_text = opts.page_text,
                book_fp = opts.book_fp,
                question = question,
                history = historyForModel(),
                progress = prog,
            })
            if Trapper:isWrapped() then Trapper:clear() end

            if not content then
                turns[idx] = nil
                UIManager:show(InfoMessage:new{
                    text = _("请求失败：") .. tostring(err),
                })
                -- 失败也回到对话页，之前轮次的问答不丢
                if #turns > 0 then showConversation() end
                return
            end

            turns[idx].a = content
            if from_cache then
                logger.info("YWBF: chat turn served from cache")
            end
            if spoiler_hit then
                Asker:notify(_("已按防剧透规则屏蔽未读内容"))
            end
            showConversation()
        end)
    end

    -- prefill：从「你可能想问」选回来时带着问题重新打开，而不是直接发出
    askInput = function(prefill)
        local dialog
        -- 建议问题：本地算，零 API 调用；开关关掉或算不出来时列表为空，入口自动置灰。
        -- page_text / book_fp / progress 是给「让小望来问」那条路准备的：
        -- AI 出题走的是 Asker:askSync 同一条管道，缺了 progress 防剧透就是空壳。
        -- 每次重开输入框都重算一次，所以进度也是最新的（对话期间翻页不会用旧进度）。
        local suggest_opts = {
            kind = "chat",
            selected = selected_clean,
            context = opts.page_text,
            page_text = opts.page_text,
            book_fp = opts.book_fp,
            progress = Asker:fetchProgress() or opts.progress,
        }
        local suggestions = SuggestPicker:list(suggest_opts)
        dialog = InputDialog:new{
            title = #turns > 0 and _("继续追问") or _("深聊：想问什么？"),
            description = previewLine(selected),
            input = prefill or "",
            input_hint = _("输入你的问题"),
            buttons = {
                {
                    {
                        text = _("取消"),
                        callback = function()
                            UIManager:close(dialog)
                            -- 已有对话时不直接消失，回到对话页
                            if #turns > 0 then showConversation() end
                        end,
                    },
                    {
                        text = _("查看选中原文"),
                        enabled = selected ~= "",
                        callback = function()
                            UIManager:show(TextViewer:new{
                                title = _("选中的原文"),
                                text = selected_clean,
                            })
                        end,
                    },
                },
                {
                    {
                        -- 不挂条数：括号里的数字会让人以为"只有这几条可选"，
                        -- 而且换个开关设置它就变了，反而像坏了
                        text = _("你可能想问"),
                        enabled = #suggestions > 0,
                        callback = function()
                            -- 必须先关掉输入框再弹选择层：叠在 InputDialog（连同它的
                            -- 虚拟键盘）之上时，弹层点不动也关不掉（真机实测症状）。
                            UIManager:close(dialog)
                            SuggestPicker:show(suggest_opts, function(q)
                                -- 只回填，不直接发出：误触不该变成一次真实请求，
                                -- 用户也常常想在建议的基础上改几个字
                                askInput(q)
                            end, suggestions, function()
                                -- 返回/点空白：把输入框还给用户，别把他晾在半路
                                askInput()
                            end)
                        end,
                    },
                },
                {
                    {
                        text = _("发送"),
                        is_enter_default = true,
                        callback = function()
                            local q = dialog:getInputText()
                            UIManager:close(dialog)
                            q = (q or ""):gsub("^%s+", ""):gsub("%s+$", "")
                            if q == "" then
                                if #turns > 0 then showConversation() end
                                return
                            end
                            ask(q)
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    -- 有引子问题（例如从选中文本直接进来）就先问一轮，否则先问用户
    if opts.seed_question and opts.seed_question ~= "" then
        ask(opts.seed_question)
    else
        askInput()
    end
end

return ChatDialog
