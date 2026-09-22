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
local Store = require("ywbf/store")
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
    -- 闭包里的 selected_kept 解析成全局变量（拿到 nil）——之前出过这个 bug。
    local selected = opts.selected or ""
    --[[--
    引文的**唯一出口**：原文保留段落结构后的形态。

    为什么只算一次、处处都用它：本文件里引文有四个去处（对话页的引文块、
    发给模型的 `selected`、`suggest` 的入参、「查看选中原文」的 TextViewer），
    以前它们分头用 `selected_clean`（`sanitizeForDisplay` 的产物，而后者
    `gsub("%c","")` 里的 `%c` **包含 `\n`**，实测 `("a\nb"):gsub("%c","")=="ab"`），
    于是**存进历史的那一份从一开始就没有换行**——后面任何展示层都救不回来。
    这次改成四处同源，写入侧就是带换行的，展示层才有的救。
    --]]
    local selected_kept = Util.keepParagraphs(selected)

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

    --[[--
    引文块：把"当时选中的那段原文"显示在问答**上方**。

    为什么要有这一段：深聊的每一轮回答都是针对这段原文说的，只显示问与答的话，
    用户翻到第 3 轮就认不出当初问的是哪一段了（真机反馈"缺引文"）。
    这一段与「收藏详情页」「结果卡片」「导出 Markdown」是同一口径。

    完整对话里它**只跟第 1 轮**（见 renderAll）：整段对话共用同一段原文，
    每一轮都贴一遍 = 同一段话连着重复 N 遍，划都划不完（真机第 7 轮）。
    只看最新一轮时照旧带 —— 那一屏本来就只有一轮，不带就没有上下文。

    **深聊这一路的引文不截断**（用户要求"我希望可以暂时全部引文"）：深聊来回好几轮，
    每轮都要重看这段原文，截到 100 字之后用户得退出去按「查看选中原文」对照，很烦。

    截断并没有从文件里删掉：`previewLine`（输入框上方那句「已选中：…」）仍然是 100 字。
    那处是"一句话交代我选了什么"，不是"把引文读一遍"，全量会把输入框挤爆。
    结果卡片那一路（`Asker.selectionBlock`，120 字）同样保持原样，见那里的注释。

    **为什么是 `Util.keepParagraphs(selected)` 而不是 `collapseWhitespace(selected_clean)`**
    （真机反馈第 6 项：引文完整了，但全挤在一起，没有分段，用户要"保持原文一样的格式"）：
      · `collapseWhitespace` 把 `\n` 也压成空格，段落结构当场没了；
      · 更关键的是 `selected_clean` 本身就是 `sanitizeForDisplay` 的产物，而它那句
        `gsub("%c", "")` 里的 `%c` **包含 `\n`**（实测 `("a\nb"):gsub("%c","") == "ab"`）
        ——换行在进到这里之前就被删掉了，后面再怎么改都救不回来。**必须喂原始
        `selected`**，由 `keepParagraphs` 内部走 `sanitizeForDisplay(s, true)`。
      · `keepParagraphs` 保留换行，只把连续 3 个以上的换行压成 2 个（最多留一个空行）、
        去掉每行首尾空白与整段首尾的空行：epub 为排版塞的一大串空行不会把整屏撑满。
    绝不用裸 `string.sub`：中文 3 字节，会切在汉字中间变乱码。
    --]]
    local function selectionBlock()
        if selected == "" then return "" end
        -- 显示层才排好看（首行缩进 2 字 + 段间多一个空行）。
        -- `selected_kept` 本身照旧：它还要发给模型、还要当 cache_seed 的一半，
        -- 排版的空格绝不能混进去（见 Util.quoteBlock 的注释）。
        local shown = Util.quoteBlock(selected_kept)
        if shown == "" then return "" end
        -- 标题走 Prompts 常量：收藏详情页 / 导出 / 结果卡片四处同一份文案，
        -- 改一处就全改，不会出现同一本书里两种叫法（旧叫法已全库清除）。
        return Prompts.QUOTE_LABEL .. "\n" .. shown .. "\n\n" .. separator() .. "\n\n"
    end

    --[[--
    某一轮的完整文本（「第 N 轮」+ 引文 + 问 + 答）。

    `with_quote` 由调用方给，自己不猜：
      · `renderAll`（完整对话）只在第 1 轮给 true —— 整段对话共用同一段原文，
        每轮都贴一遍就是同一段话重复 N 遍（真机第 7 轮望仔反馈）；
      · `renderLatest`（只看最新一轮）恒为 true —— 那一屏只有一轮，
        不带引文的话只剩孤零零一问一答，看不出在问哪一段。
    --]]
    local function renderTurn(i, with_quote)
        local t = turns[i]
        -- 引文在【问】之上：先看见引的是哪段，再看问了什么
        local quote = with_quote and selectionBlock() or ""
        return T(_("第 %1 轮"), tostring(i)) .. "\n"
            .. quote
            .. T(_("【问】%1"), t.q) .. "\n\n"
            -- 答的标签直接用角色名（Prompts.PERSONA_NAME = "小望"）：
            -- 用户要能一眼看出这是谁在说话，也避免改名时这里漏改。
            .. T(_("【%1】%2"), Prompts.PERSONA_NAME, t.a)
    end

    -- 完整对话：每轮之间用分隔线隔开，一眼能看出边界在哪。
    -- 引文只给第 1 轮：它是整段对话的上下文，不是每一轮各自的。
    local function renderAll()
        local parts = {}
        -- 循环变量不用 `_`：文件头 `local _ = require("gettext")` 会被遮蔽
        for _i = 1, #turns do
            if _i > 1 then parts[#parts + 1] = separator() end
            parts[#parts + 1] = renderTurn(_i, _i == 1)
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
        -- 这一屏只有一轮，引文必须带：不带就只剩一问一答，认不出问的是哪段
        return head .. renderTurn(i, true)
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

    --[[--
    关掉对话页（**深聊所有出口都必须走这里**，不许各自 `UIManager:close(viewer)`）。

    真机新 bug（望仔，第 6 轮第 5 项的连带）：在深聊里 收藏 → 取消收藏 → 再收藏，
    最后点「结束」，**画面卡住、结束按钮一直保持反转颜色**。

    为什么必须自己排一次刷新 —— 三步都在真机源码里，不是推断：

      1. `UIManager:close(widget)` 不传 refreshtype 时，末尾那句
         `self:_refresh(refreshtype, ...)` 传进去的是 nil，而
         `UIManager:_refresh` 第一行就是
             `if not mode then return end`
         （`frontend/ui/uimanager.lua:1139-1148`，注释原话是
         "we drop it to avoid enqueuing a useless full-screen refresh"）。
         ⇒ **关窗这一次一次刷新都不排**。它只把下层 widget 标脏（同样是
         `setDirty(w)` 不传 refreshtype），等下一个主循环才画。

      2. 而点按钮那一下，`Button:_undoFeedbackHighlight` 已经往刷新队列里排了
         一条 **"fast" 局部区域**（只覆盖按钮那一小块，`button.lua:442` 与
         `button.lua:468`）。于是 `_repaint` 末尾那条兜底——
             `if dirty and not self._refresh_stack[1] then self:_refresh("partial") end`
         （`uimanager.lua:1308-1310`）—— **因为队列不空而被跳过**。

      3. 结果：整屏只有按钮那一小块被刷新，而且波形是 `fast`
         （局部无闪波形，正是墨水屏上留残影的那种）。对话框残留在屏幕上，
         反色也清不掉 ⇒ 望仔看到的"卡住 + 结束按钮一直反色"。

    所以关完之后**必须自己排一次整屏刷新**。用 `full` 不用 `ui`：这次要清的是
    已经画进 framebuffer 的反色残影，`ui`（无闪）在墨水屏上仍可能留痕；`full`
    带一次闪，代价是关窗时闪一下，换来的是一定能清干净。

    三个出口（继续追问 / 查看完整对话 / 结束）都走这里：它们都是
    `UIManager:close(viewer)` 的同形代码，同一个后果。
    --]]
    local function closeConversation(v)
        if not v then return end
        UIManager:close(v)
        -- 整屏、带闪：见上面第 3 步。第二个参数是波形，第三参数不传 = 整屏。
        UIManager:setDirty(nil, "full")
    end

    -- 对话页：默认展示最新一轮，可切到完整对话；底部给「收藏 / 继续追问 / 结束」
    --
    -- 收藏只针对**最新一轮**（不管当前是在看最新一轮还是完整对话）：
    -- 整段对话里每一轮都有自己的收藏按钮会把范围说不清楚——收藏的到底是这一轮、
    -- 还是整段对话？用户在多轮里来回看时也会按错。一刀划到"最新一轮"最简单，
    -- 语义也最清楚：屏幕上"当前在聊的这一轮"就是按钮作用的对象。
    local function showConversation(view_all)
        local n = #turns
        local current = turns[n]
        local ref = nil
        if type(current) == "table" then
            if type(current.stored) == "table" and current.stored.book_fp
                and type(current.stored.index) == "number" then
                ref = current.stored
            elseif opts.book_fp and type(current.a) == "string" and current.a ~= "" then
                -- 命中缓存的那一轮不会再写历史，用回答原文把之前那条找回来
                local idx = Store:indexOfContent(opts.book_fp, current.a, "assistant")
                if idx then ref = { book_fp = opts.book_fp, index = idx } end
            end
        end

        local viewer
        local rows = {
            {
                {
                    text = _("继续追问"),
                    is_enter_default = true,
                    callback = function()
                        closeConversation(viewer)
                        askInput()
                    end,
                },
                {
                    text = view_all and _("只看最新一轮") or _("查看完整对话"),
                    enabled = n > 1,
                    callback = function()
                        closeConversation(viewer)
                        showConversation(not view_all)
                    end,
                },
            },
        }

        if ref then
            rows[#rows + 1] = {
                {
                    id = Asker.FAVORITE_BUTTON_ID,
                    text = Store:isFavorite(ref.book_fp, ref.index) and _("取消收藏") or _("收藏"),
                    callback = function()
                        local now = Store:setFavorite(ref.book_fp, ref.index,
                            not Store:isFavorite(ref.book_fp, ref.index))
                        if now == nil then
                            Asker:notify(_("收藏没有生效：这一轮已经不在历史里了"))
                            return
                        end
                        --[[--
                        按钮就地刷新**必须走 `Asker.refreshFavoriteButton`**，不许在这里
                        自己 `btn:setText(text)`（真机新 bug：深聊里点「收藏」毫无反应）。

                        根因（查证过，不是猜的）：**写入是成功的，坏的是"把新状态画出来"**。

                        真机证据两条：
                          · `data/history/2ab82829f86c2867.json`（红楼梦）里那条**多段**
                            引文的 assistant 记录就是 `"favorite":true`；
                          · `crash.log` 11:57:51 有 `YWBF notify: 已收藏这一轮…`
                            （`Asker:notify` 只在 `setFavorite` 返回非 nil 时才报这句）。

                        那就是说回调**跑到了**、数据**写进去了**，用户却说"没反应"——
                        区别只在屏幕上：`Button:setText(text)` **不传 width** 会走
                        `label_widget:free() + self:init()` 把按钮整颗重建
                        （`frontend/ui/widget/button.lua:276`，`self.width = nil`），
                        而这一路**既没有 `UIManager:setDirty`、也没有让 ButtonTable 重排**，
                        「收藏」→「取消收藏」变宽之后没有任何东西把它画出来 ⇒
                        按钮纹丝不动。结果卡片那一路（showResult）走的是
                        `Asker.refreshFavoriteButton`（带 width + 整屏 setDirty），
                        所以那边一直是对的 —— 这也解释了为什么**只有深聊这一路**坏了。

                        顺带排掉的两个怀疑（都不是）：
                          · 不是收藏白名单（`FAVORITE_SURFACES` 只管 showResult 那颗按钮，
                            深聊这颗是 `if ref then` 自己挂的，不经过白名单）；
                          · 也不是多段引文把写入搞坏了（多段 selection 完整落在历史里，
                            上面那条 `favorite:true` 就是带 `\n` 的）。
                        --]]
                        Asker.refreshFavoriteButton(viewer, Asker.FAVORITE_BUTTON_ID,
                            now and _("取消收藏") or _("收藏"))
                        -- 必须传 SOURCE_ALWAYS_SHOW，否则会被通知开关过滤掉、用户什么都看不到
                        Asker:notify(now and _("已收藏这一轮，可在「我的问答收藏」里找到")
                                         or _("已取消收藏这一轮"))
                    end,
                },
            }
        end

        rows[#rows + 1] = {
            {
                text = _("结束"),
                callback = function()
                    closeConversation(viewer)
                end,
            },
        }

        viewer = TextViewer:new{
            title = T(_("远望书友-深聊（第 %1 轮）"), tostring(n)),
            text = view_all and renderAll() or renderLatest(),
            buttons_table = rows,
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
            local content, err, from_cache, spoiler_hit, _truncated, stored = Asker:askSync({
                kind = "chat",
                title = _("远望书友-深聊"),
                -- 存进历史与发模型同源：写入侧就是带换行的，展示层才救得回来
                selected = selected_kept,
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
            -- 这一轮在历史里的定位，供对话页挂收藏按钮
            turns[idx].stored = stored
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
            selected = selected_kept,
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
                                -- 与对话页引文块同一口径：原文怎么分段，这里就怎么显示
                                -- （同一层排版，见 Util.quoteBlock）
                                text = Util.quoteBlock(selected_kept),
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
