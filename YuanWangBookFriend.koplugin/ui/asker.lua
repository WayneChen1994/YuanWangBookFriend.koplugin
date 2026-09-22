--[[--
提问流水线：上下文 → 缓存 → Prompt → DeepSeek → 落缓存/历史。

同步接口 askSync 供上层在 Trapper 协程中调用；
UI 封装 askAndShow（深聊/释义等即时展示）与 submitAsync（轻问异步）。
--]]--

local Cache = require("ywbf/cache")
local Config = require("ywbf/config")
local Context = require("ywbf/context")
local DeepSeek = require("ywbf/deepseek")
local Prompts = require("ywbf/prompts")
local Queue = require("ywbf/queue")
local Spoiler = require("ywbf/spoiler")
local Store = require("ywbf/store")
local Util = require("ywbf/util")

--[[--
结果卡片的分隔线要用到屏幕几何（理由见下面 buildSeparator）。

这四项一律用 `pcall(require, ...)` 包住，和 `ui/favorites.lua` 同一个理由：
本文件在设备上是被 KOReader 加载的，但在无头 luajit 里跑验收脚本时
`ui/font` / `ui/rendertext` 这条链拉不起来（它们要去 require `frontend/util` 等），
直接 require 会让**整个模块加载失败**，把所有断言一起带崩。
拉不起来时这四个变量是 nil，`buildSeparator` 里那句 `Device.screen` 会抛异常，
被它自己的 pcall 兜住并退回固定长度——功能上完全正确。

与 `ui/chatdialog.lua` 的 buildSeparator 是同一套公式（含 0.96 的余量），
改一处必须同步改另一处，否则两块屏幕上的分隔线长度会不一样。
--]]
local ok_dev, Device = pcall(require, "device")
local ok_font, Font = pcall(require, "ui/font")
local ok_size, Size = pcall(require, "ui/size")
local ok_rt, RenderText = pcall(require, "ui/rendertext")

local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

--[==[
TextBoxWidget 的 **PTF**（Poor Text Formatting）内联加粗标记。

KOReader 2024.01 才加的东西：整串开头挂一次 `PTF_HEADER` 打开开关，要加粗的
那几段用 `PTF_BOLD_START` / `PTF_BOLD_END` 包起来。它们是**非法 Unicode 码点**
（私有区 U+FFF1/U+FFF2/U+FFF3），只有 TextBoxWidget 认。

为什么要守卫、不能裸用：**这个插件是要公开发布的，不止望仔一台**。
低于 2024.01 的 KOReader 上这三个常量是 **nil**，`PTF_HEADER .. text` 直接抛
`attempt to concatenate nil` —— 章末总结卡片当场崩。那种"别人装上就崩"的事故
比少一个加粗严重得多，所以取不到就置 nil，走纯文本兜底（排版照旧，只是不粗）。

真机（v2026.07.2）实测三个常量都在：`frontend/ui/widget/textboxwidget.lua:132-133`
定义，`:186` 有 `self.text:sub(1, #PTF_HEADER) == PTF_HEADER` 的判别。

三个**全是 string 才认**：只传一半同样会在真机上崩。
--]==]
local PTF = nil
do
    local ok_tbw, TextBoxWidget = pcall(require, "ui/widget/textboxwidget")
    if ok_tbw and type(TextBoxWidget) == "table"
        and type(TextBoxWidget.PTF_HEADER) == "string"
        and type(TextBoxWidget.PTF_BOLD_START) == "string"
        and type(TextBoxWidget.PTF_BOLD_END) == "string" then
        PTF = {
            header = TextBoxWidget.PTF_HEADER,
            bold_start = TextBoxWidget.PTF_BOLD_START,
            bold_end = TextBoxWidget.PTF_BOLD_END,
        }
    end
end

local Asker = {}

-- 结果卡片上那个收藏按钮的 id（深聊那边也用它，所以挂在 Asker 上而不是文件私有）。
-- ButtonTable 支持按 id 取回真正的 Button 实例（getButtonById），
-- 于是切换收藏状态时只改按钮文字即可，不必重建整个结果页——
-- 重建会把用户正在读的位置顶回开头（见 showResult 的用法）。
Asker.FAVORITE_BUTTON_ID = "ywbf_favorite"

--[[--
**哪些入口的回答可以收藏**——按"入口"判，不按提示词 `kind` 判。

用户要求：能收藏问答的只有「轻问」和「深聊」，「AI解释」「AI摘要」等等不要有
收藏 / 取消收藏。菜单上的名字与代码里的 kind 对不齐，所以先把对齐关系写清楚：

  菜单项                 入口               kind（提示词）   surface（入口）  可收藏
  ------------------------------------------------------------------------
  远望书友-轻问            ToastCard           light            light           ✓
  远望书友-轻问（留空）     ToastCard           explain(*)       light           ✓
  远望书友-深聊            ChatDialog          chat             chat            ✓
  远望书友-AI解释          highlight 菜单        explain          explain         ✗
  远望书友-AI摘要          highlight 菜单        summary          summary         ✗

(*) 轻问把输入框留空时 kind 会退化成 explain（`Prompts.build("light", {question=nil})`
    给模型发的是**空消息**，所以不能只改 kind，见 ui/toastcard.lua 那一行）。
    但用户看到的卡片标题是「远望书友-轻问回复」，对他来说就是轻问——所以这一路
    判的必须是 **surface**（记录里也按 surface 存档，见 recordTurn），否则会出现
    "刚问完能收藏、回头在『查看最近回复』里又不能收藏"这种自相矛盾的界面。

为什么 `surface` 要单独存进历史：`showResult` 在"查看最近回复"里是**从记录重建**的
（没有入口上下文可问），只能读记录里的字段。所以 main.lua 那两处读记录时取
`reply.surface or reply.kind`——多数老记录只有 kind，回退到 kind 仍能对上轻问/深聊。
但白名单是**默认拒绝**的：老记录若既无 surface 也无 kind（`nil`），就等于「不在白名单」，
**不挂**收藏按钮——无法确认它出自哪个入口，就不给收藏，这是定案的口径。
--]]
Asker.FAVORITE_SURFACES = { light = true, chat = true }

--[[--
等待类提示的统一出口（拟人化：主语是 %1，不是"AI"）。

为什么写成方法而不是加载期的字符串常量：`_()` 的结果不能在模块加载时就固化，
那时翻译目录可能还没装好，提前固化成原文会让后续切语言失效。
和 ui/suggestpicker 的 thinkingText 是同一个写法。

抽出来的理由很实际：深聊（ui/chatdialog）和即时提问（本文件）都要这句，
两处各写一遍的话，改文案时必然改一处忘一处，用户就会在两块屏幕上看到
两种叫法——那比不拟人更糟。

为什么主语必须是 %1：这是用户唯一会长时间盯着看的文案。主语写成技术名词，
整句听起来就只是个"中转站"；用户要的是"有个角色在跟我对话"这种感觉。
--]]
function Asker:thinkingText()
    return T(_("%1思考中…"), Prompts.PERSONA_NAME)
end

--[[--
注册"进度兜底来源"。

P0 事故的根因是某个入口**忘了传** progress，于是防剧透的四道防线静默空转。
改 bug 之外必须有结构性兜底：上层在 init 时把取进度的函数注册到这里，
askSync 发现 opts.progress 为空时会主动再取一次，而不是退化成空壳。
（单测/脚本里不注册也能跑，只是没有兜底；取不到会打 warn 日志而非静默。）
--]]
function Asker:setProgressProvider(fn)
    self.progress_provider = fn
end

function Asker:fetchProgress()
    if type(self.progress_provider) ~= "function" then return nil end
    local ok, prog = pcall(self.progress_provider)
    if ok and type(prog) == "table" then return prog end
    return nil
end

--[[--
弹出一条轻提示。

坑：Notification:notify(text) 不传 source 时会被 notification_sources_to_show_mask
过滤掉而静默丢弃（source 为 nil 时条件直接为 false）。
必须显式传 SOURCE_ALWAYS_SHOW，否则用户什么都看不到。
--]]
function Asker:notify(text)
    logger.info("YWBF notify:", text)
    Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW, true)
end

-- 各类任务的模型参数
local TASK_PARAMS = {
    explain = { temperature = "temperature_fact", max_tokens = "max_tokens_explain" },
    summary = { temperature = "temperature_fact", max_tokens = "max_tokens_summary" },
    concept = { temperature = "temperature_fact", max_tokens = "max_tokens_summary" },
    chat    = { temperature = "temperature_chat", max_tokens = "max_tokens_chat" },
    light   = { temperature = "temperature_chat", max_tokens = "max_tokens_chat" },
    -- 引导式提问：只要 4 条 ≤20 字的问题，走聊天温度（要有点发散才问得有意思），
    -- 但 max_tokens 单独压到 300 —— 这是一个"顺手点一下"的入口，不能让它贵过正经提问
    ideas   = { temperature = "temperature_chat", max_tokens = "max_tokens_ideas" },
    --[[--
    章末总结：温度取 **fact（0.3）**，不取 chat（0.7）。

    它要"多角度"，听起来该发散；但发散的方向恰好最容易滑向剧透
    （"这预示着…""为后文埋下伏笔"）。这里宁可写得平一点：
    生动由回复风格（`reply_style`）去补，事实边界不能被温度换掉。
    max_tokens 必须单独一个（2500），`max_tokens_summary` 只有 1024，铺不开。
    --]]
    chapter_summary = {
        temperature = "temperature_fact",
        max_tokens = "max_tokens_chapter_summary",
    },
}

--[[--
同步提问（会阻塞，调用方负责放进 Trapper 协程）。

防剧透全链路（M3 T3.6）：
  1. 进度 prog 由 main.lua 在 gather() 时读好塞进 opts.progress；
  2. 上下文窗口先过 Spoiler.truncateWindow —— 后文段跨章的部分被物理剪掉，
     保证「未读文本不进入 payload」（PRD F4.3 是工程级隔离，不是靠 prompt 嘱咐）；
  3. 命中缓存的旧回复同样过 Spoiler.sanitizeAnswer（缓存是历史泄漏路径）；
  4. system + user 双保险注入进度声明（PRD F4.2）；
  5. 最终请求统一走 DeepSeek:chat —— 那里是防剧透管道的单点出口。

@param opts { kind, selected, page_text, question, history, book_fp, progress }
@return content, err, from_cache, spoiler_hit
--]]
function Asker:askSync(opts)
    opts = opts or {}
    local kind = opts.kind or "explain"
    local selected = opts.selected or ""

    local prog = opts.progress
    if prog == nil then
        -- 结构性兜底：入口忘传时再取一次，绝不静默退化成 enabled=true 的空壳
        prog = self:fetchProgress()
        if prog == nil then
            logger.warn("YWBF: progress missing at " .. tostring(kind))
        else
            logger.info("YWBF: progress recovered via provider at " .. tostring(kind))
        end
    end
    prog = Spoiler.withConfig(prog, Spoiler.currentConfig())

    local win = Context.fromSelection(opts.page_text, selected, Config:get("context_chars"))

    -- 第 1 道：上下文窗口物理截断
    local win2, cut_info = Spoiler.truncateWindow(win, prog)
    if cut_info and cut_info.truncated then
        logger.info("YWBF: spoiler truncated context, reason=", tostring(cut_info.reason),
            " marker=", tostring(cut_info.marker))
    end
    win = win2

    local ctx = Prompts.contextFromWindow(win)
    if Util.isEmpty(ctx) then ctx = "【选中内容】\n" .. selected end

    local model = Config:get("model")
    -- 风格必须进缓存 key：否则换成毒舌后问同一段话，会命中之前专业风格攒下的
    -- 旧回答，用户会以为"改了设置没生效"。
    -- 刻意只在**非默认风格**时才加后缀：老版本攒下的缓存（默认风格）仍然能命中。
    local style = Prompts.normalizeStyleKey(Config:get("reply_style"))
    local cache_seed = selected .. "|" .. (opts.question or "")
    if style ~= Prompts.STYLE_DEFAULT then
        cache_seed = cache_seed .. "|style:" .. style
    end
    local cache_key = Cache:keyFor(opts.book_fp, cache_seed, kind, model)

    if Config:get("cache_enabled") then
        local hit = Cache:get(cache_key)
        if hit then
            logger.info("YWBF: cache hit, kind=", kind)
            -- 缓存里可能是之前在后面章节查到的内容，出库前同样过预警
            local safe, was_hit = Spoiler.sanitizeAnswer(hit, prog)
            return safe, nil, true, was_hit
        end
    end

    -- 本地硬拦：明显在问后续剧情且还没读到结尾 → 直接回模糊话术，不发请求
    local blocked, note, refusal = Spoiler.evaluate(Spoiler.currentConfig(), prog, opts.question)
    if blocked then
        logger.info("YWBF: spoiler blocked question locally")
        return refusal, nil, false, true
    end

    local messages = Prompts.build(kind, {
        context = ctx,
        selected = selected,
        question = opts.question,
        history = opts.history,
        spoiler_note = Prompts.spoilerNote(prog),
        spoiler_hint = Prompts.spoilerHint(prog),
        style = style,
    })

    local params = TASK_PARAMS[kind] or TASK_PARAMS.explain
    local res, err = DeepSeek:chat(messages, {
        model = model,
        temperature = Config:get(params.temperature),
        max_tokens = Config:get(params.max_tokens),
        spoiler_progress = prog,
    })
    if not res then
        return nil, err, false, false
    end

    --[[--
    输出被长度截断（finish_reason == "length"）：最后一行多半是半句话。

    为什么非得看上游这个标志：「完整的句子漏写问号」（必须收）和「被截断的残句」
    （必须丢）在**文本层面长得一模一样**，本地规则判不了（QA 实测样本：
    「窗外雪停了以后他才发」被收成一条按钮，用户点它 = 花一次额度问半句话）。
    标志从 res.raw 直接读，不用改 DeepSeek:chat（它本来就带回了 decoded）。
    --]]
    local truncated = false
    local choice = type(res.raw) == "table" and type(res.raw.choices) == "table"
        and res.raw.choices[1] or nil
    if type(choice) == "table" and choice.finish_reason == "length" then
        truncated = true
        logger.warn("YWBF: output truncated by max_tokens, kind=", tostring(kind))
    end

    --[[--
    **截断的一律不进缓存**（不看 kind）。

    原来只排除了 `ideas`，于是章末总结被砍掉的半截照样写进了缓存 —— 真机第 8 轮
    望仔反馈"章末总结提示结尾可能不完整"，而这半截一旦进缓存就是**永久的**：
    缓存命中走的是上面那条 early return，连 `truncated` 标志都带不出来，
    以后每次点同一章拿到的都是那半截，他永远看不到完整总结。

    为什么"不缓存"是唯一解：残缺的结果和不缓存相比，前者糟糕得多 ——
    不缓存只是下次重发一次（多花一次额度），缓存了残缺结果则是**每次都错**，
    而且用户没有任何办法把它清掉（缓存没有过期时间，只能去删文件）。

    缓存命中那条 early return 走不到这里、带不出 truncated 标志，所以残句会被
    当成正常输出再收一次 —— 这也是为什么只能在**写入侧**拦。
    --]]
    if Config:get("cache_enabled") and not truncated then
        Cache:set(cache_key, res.content)
    end
    -- ideas 不进历史：它不是一轮问答，只是"帮你把问题想出来"的中间产物。
    -- 写进 Store 会污染笔记/对话导出（用户会看到一堆自己没问过的问题），
    -- 也会让"继续追问"的上下文里混进莫名其妙的 assistant 发言。
    -- 缓存照存（那是省钱的；上面那句只把**截断**的那次排除掉），历史不落。
    local stored = nil
    if opts.book_fp and kind ~= "ideas" then
        stored = self:recordTurn(opts, res.content, prog, style)
    end
    logger.info("YWBF: ask ok, kind=", kind, " tokens=", tostring(res.usage and res.usage.total_tokens))
    -- 第五个返回值 truncated：只有真正走了请求才有意义。
    -- 缓存命中的 early return 不带它（nil = false），语义正确：
    -- 能进缓存的都是完整输出，被截断的那次我们根本没存（任何 kind 都不存）。
    -- 第六个返回值 stored：这一轮**回答条目**在历史里的定位 { book_fp, index }，
    -- 结果卡片要靠它挂收藏按钮；写不进去（例如没有 book_fp）时为 nil。
    return res.content, nil, false, (res.spoiler_hit == true), truncated, stored
end

--[[--
把一轮问答写进历史，并返回回答条目的定位。

为什么单独摊成一个方法：askSync 有好几条出口（缓存命中 / 本地拦截 / 请求失败 / 正常），
每条各自拼一遍 Store:append 的字段，迟早在某条分支上漏掉一个新字段
（turn_id 漏了就配不成对，book_title 漏了列表里就只显示"未知书"）。
字段只在**这一处**拼，出口都来调它。

**同一轮的两条共用 turn_id**：列表展示时要能把"当时问的是什么"找回来，
而 user / assistant 是两条独立记录，靠相邻位置猜不可靠。

@param opts   askSync 的原始 opts（用到 book_fp / kind / selected / question / book_title）
@param answer 回答正文
@param prog   已经算好的进度（章节信息从这里取，**不再重算、也不发任何请求**）
@param style  当时的回复风格 key（阶段二要做风格筛选，现在就得记下来，
              事后再补是补不出来的——老数据不知道当时用了什么风格）
@return table|nil { book_fp = ..., index = ... }；写失败或没有 book_fp 时为 nil
--]]
function Asker:recordTurn(opts, answer, prog, style)
    opts = opts or {}
    local book_fp = opts.book_fp
    if not book_fp then return nil end

    local turn_id = Store:newTurnId()
    local fields = {
        kind = opts.kind or "explain",
        --[[--
        入口（light / chat / explain / summary…），决定这条记录**回头还挂不挂收藏按钮**
        （见 Asker.FAVORITE_SURFACES）。

        为什么不复用 kind：轻问把输入框留空时 kind 退化成 explain，而 AI解释 的 kind
        也是 explain —— 两者靠 kind 分不开，但一个该能收藏、一个不该。
        老记录没有这个字段 → 读的时候回退到 kind（main.lua 那两处 `or reply.kind`），
        行为与今天一致，不需要回填。
        --]]
        surface = opts.surface or opts.kind,
        selection = opts.selected or "",
        turn_id = turn_id,
        book_fp = book_fp,
        book_title = opts.book_title,
        chapter_title = type(prog) == "table" and prog.chapter or nil,
        chapter_index = type(prog) == "table" and prog.chapter_index or nil,
        --[[--
        细粒度章节（回目级）与粗粒度**一起存**：列表分组只认这对**都有**的口径
        （旧数据没有，就会自动回落到上面那对粗粒度字段，行为与今天一致）。

        这两行不要挪进下面任何一处 Store:append —— 两处调用必须带**同一套**字段，
        否则 assistant 那条有回目、配成对的 user 那条没有，按 answer 找回锚点时
        就会拿到半套章节信息。
        --]]
        chapter_fine_title = type(prog) == "table" and prog.chapter_fine or nil,
        chapter_fine_index = type(prog) == "table" and prog.chapter_fine_index or nil,
        page = type(prog) == "table" and prog.page or nil,
        question = opts.question,
        style = style,
    }

    local ok_write = Store:append(book_fp, {
        role = "assistant", content = answer or "",
        kind = fields.kind, selection = fields.selection,
        surface = fields.surface,
        turn_id = turn_id, book_fp = book_fp, book_title = fields.book_title,
        chapter_title = fields.chapter_title, chapter_index = fields.chapter_index,
        chapter_fine_title = fields.chapter_fine_title,
        chapter_fine_index = fields.chapter_fine_index,
        page = fields.page, question = fields.question, style = fields.style,
    })
    if not ok_write then return nil end

    if not Util.isEmpty(opts.question) then
        Store:append(book_fp, {
            role = "user", content = opts.question,
            kind = fields.kind, selection = fields.selection,
            surface = fields.surface,
        turn_id = turn_id, book_fp = book_fp, book_title = fields.book_title,
        chapter_title = fields.chapter_title, chapter_index = fields.chapter_index,
        chapter_fine_title = fields.chapter_fine_title,
        chapter_fine_index = fields.chapter_fine_index,
        page = fields.page, question = fields.question, style = fields.style,
    })
    end

    -- 写完立刻回查 index：append 的返回值只有成功与否，而现在 Button 需要精确定位。
    -- 用 turn_id 查而不是取 #entries：万一中间夹了别的写入（并发/其它入口），
    -- 位置会漂；id 不会。
    local index = Store:indexOfTurn(book_fp, turn_id, "assistant")
    if not index then return nil end
    return { book_fp = book_fp, index = index }
end

--[[--
结果卡片的分隔线。

三处坑，都是从真机与既有验收里来的：
  · 字符必须用 U+2014 中文破折号，不能选 ─ ━ 那类制表符：墨水屏字体缺字会渲染成方块；
  · 长度必须按屏幕宽度现算（KPW4 是 1072px，写死一串只占三分之一行；
    宽屏更差，600px 小屏反而会折成两行）；
  · 量不出来（无头 luajit 里 `Device.screen` 是 nil）就退回固定长度，绝不抛错。

TextViewer 的默认几何（frontend/ui/widget/textviewer.lua）：
    width = Screen:getWidth() - Screen:scaleBySize(30)
    文本区宽 = width - 2*text_padding - 2*text_margin   （Size.padding.large / Size.margin.small）
    face  = Font:getFace("x_smallinfofont")
这里照抄同一套公式，再用 Util.fillLine 按实际字形宽度换算字符个数。
**这段与 ui/chatdialog.lua 的 buildSeparator 必须保持一致**（含 0.96 的余量）。
--]]
local SEP_CHAR = "—"  -- U+2014
local SEP_FALLBACK = string.rep(SEP_CHAR, 24)

local function buildSeparator()
    local ok, sep = pcall(function()
        -- 四个 UI 模块有一个没拉起来（无头环境）就直接退回固定长度：
        -- 与其在下面某一行抛异常再兜，不如在这里就把意图写清楚
        if not (ok_dev and ok_font and ok_size and ok_rt) then return SEP_FALLBACK end
        local screen = Device.screen
        if not screen or not screen.getWidth then return SEP_FALLBACK end

        local face = Font:getFace("x_smallinfofont")
        local unit = RenderText:sizeUtf8Text(0, nil, face, SEP_CHAR, true, false)
        if type(unit) ~= "table" or type(unit.x) ~= "number" or unit.x <= 0 then
            return SEP_FALLBACK
        end

        -- 可用宽再打 4% 的折扣后才去排字符。为什么必须留余量：
        -- 用户实测"分隔线多出一个字符、被挤到下一行"——按几何算出来的可用宽比
        -- TextBoxWidget 实际断行用的宽度略大（字体回退、字距微调、scaleBySize 取整）。
        -- 压满到 100% 换来的是 1~2 个字符的观感，翻车代价是多出一行，不值。
        local usable = (screen:getWidth() - screen:scaleBySize(30)
                       - 2 * Size.padding.large - 2 * Size.margin.small) * 0.96
        local measure = function(s)
            local m = RenderText:sizeUtf8Text(0, nil, face, s, true, false)
            return type(m) == "table" and m.x or 0
        end

        local s = Util.fillLine(usable, unit.x, SEP_CHAR, measure)
        if s == "" then return SEP_FALLBACK end
        return s
    end)
    if ok and type(sep) == "string" and sep ~= "" then return sep end
    return SEP_FALLBACK
end

-- 结果卡片里引文最多展示多少个字符（超出部分在「我的问答收藏」的详情页里看得到全文）
local SEL_PREVIEW_CHARS = 120

--[[--
引文块（显示在问答**上方**）。

为什么必须走 `Util.preview`：中文 3 字节，裸 `string.sub` 会切在汉字中间变乱码。
`Util.preview` 返回**三个值**（正文 / 原文长度 / 是否截断），只用第一个接会把
后两个丢掉——本项目在 `ywbf/bookmeta.lua` 里踩过同一个坑。

为什么加「（共 N 字）」：截断而不说清楚，用户会以为原文就这么短。
--]]
function Asker.selectionBlock(selection)
    if type(selection) ~= "string" or selection == "" then return "" end
    local clean = Util.sanitizeForDisplay(selection)
    local shown, total, truncated = Util.preview(clean, SEL_PREVIEW_CHARS)
    if shown == "" then return "" end
    if truncated then
        shown = shown .. T(_("…（共 %1 字）"), tostring(total))
    end
    -- 标题走 Prompts 常量：与深聊对话页 / 收藏详情页 / 导出同一份文案（见那里）
    return Prompts.QUOTE_LABEL .. "\n" .. shown
end

--[[--
就地刷新结果卡片上的收藏按钮。

两个坑都是踩出来的：
  1. `Button:setText(text)` **不传 width** 时会走 `label_widget:free(); self:init()`
     把按钮重建一遍，而 KOReader 的按下/抬起反馈只把**按钮旧尺寸**那块区域排进刷新
     （`frontend/ui/widget/button.lua` 的 `_undoFeedbackHighlight`，波形还是 `fast`）。
     「收藏」→「取消收藏」变宽之后，多出来的像素没人重绘，墨水屏上就是残影。
     传 `width = 当前宽度` 走的是"只换文字、几何不动"那条分支，区域始终对得上。
  2. 换完文字必须**自己**排一次重绘，且不能用 `fast`：`fast` 是局部无闪波形，
     在墨水屏上正是留残影的那种刷法。这里按 `ui` 刷整张卡，代价是一次正常刷新。
--]]
function Asker.refreshFavoriteButton(viewer, btn_id, text)
    local btn = viewer and viewer.button_table
        and viewer.button_table:getButtonById(btn_id)
    if btn and btn.setText then
        btn:setText(text, btn.width)
    end
    --[[--
    这里**裸调** `UIManager:setDirty`，不再判空。

    之前那圈 `if UIManager and UIManager.setDirty then` 是给"离线 ui 桩只桩了
    show/close"打的补丁——但真机 UIManager 永远带 setDirty，桩缺这个不是生产代码
    该绕的坑，而是**桩不够**。桩补齐（`tools/eng_check_favorites.lua`
    的 ui/uimanager 桩已加 setDirty 记录仪）之后，这圈判空是死分支，
    而且会让"到底排没排重绘、波形对不对"这类断言失去意义——判空跳过时
    根本没有 setDirty 可断言。所以还原成裸调用。
    --]]
    UIManager:setDirty(viewer, "ui")
    return btn
end

--[[--
回答条目的定位信息（用于结果卡片挂收藏按钮）。

三种情况：
  · 刚真的发了请求：recordTurn 已经给了 { book_fp, index }；
  · 命中缓存：这一轮**不会再写历史**（否则同一个问题反复问会不断堆叠记录），
    于是用回答原文把之前那条记录找回来 —— 用户看到的还是那个回答，
    理应能收藏到同一条记录上（而不是"这次没法收藏"）；
  · 本地拦截 / 请求失败：根本没有记录，返回 nil。

@return table|nil
--]]
function Asker:locateStoredTurn(book_fp, answer, stored)
    if type(stored) == "table" and stored.book_fp and type(stored.index) == "number" then
        return stored
    end
    if not book_fp then return nil end
    local index = Store:indexOfContent(book_fp, answer, "assistant")
    if index then return { book_fp = book_fp, index = index } end
    return nil
end

--[==[
关掉结果卡片（**结果页所有"点按钮关闭"的出口都走这里**，不许各自裸
`UIManager:close(viewer)`）。

成因与修 6（深聊「结束」按钮卡住）**一模一样**，三步都在真机源码里：

  1. `UIManager:close(widget)` 不传 refreshtype ⇒ 末尾 `self:_refresh(nil, …)`，
     而 `_refresh` 第一行就是
         `if not mode then return end`
     （`frontend/ui/uimanager.lua:1139-1148`）⇒ **关窗这一次一次刷新都不排**；
  2. 而点按钮那一下，`Button:_undoFeedbackHighlight` 已经往刷新队列里排了一条
     只覆盖按钮小块的 **"fast"**（`button.lua:442` / `:468`）；
  3. 于是 `_repaint` 末尾"`_refresh_stack` 为空才补一次 partial"的兜底
     （`uimanager.lua:1308-1310`）**因为队列不空被跳过** ⇒ 整屏只有按钮那一小块
     被刷，而且波形是无闪的 `fast` ⇒ 卡片残留在屏上、反色清不掉。

所以关完必须自己排一次整屏刷新。`full` 而不是 `ui`：要清的是已经画进
framebuffer 的反色残影，`ui`（无闪）在墨水屏上仍可能留痕。

与 `ui/chatdialog.lua` 的 `closeConversation` 是**同形的一对**：两处都是
`close + setDirty(nil, "full")`。没合并成一个是因为它们各自守着自己的 viewer 生命周期，
硬凑一个公共函数要动刚过真机验收的深聊那三条出口 —— 不划算。
**改其中一处时另一处要跟着看一眼。**
--]==]
function Asker.closeResult(v)
    if not v then return end
    UIManager:close(v)
    -- 整屏、带闪：见上面第 3 步。第二个参数是波形，第三参数不传 = 整屏。
    UIManager:setDirty(nil, "full")
end

--[[--
结果展示（墨水屏：纯文本、可滚动、无渐变）。

@param title       string
@param content     string 回答正文
@param extra_note  string|nil 补充说明（例如"来自本地缓存"）
@param question    string|nil 提问。轻问/追问场景下必须带上——只显示回答不显示问题，
                   用户根本不知道这段回答是针对哪个问题说的。问题显示在回答上方。
@param ref         table|nil { book_fp, index } 这条回答在历史里的定位。
                   传了才挂「收藏 / 取消收藏」按钮；没传（比如这条已经不在历史里）
                   就不要挂个点了没反应的按钮。
@param selection   string|nil 当时引的那段原文（引文）。传了就显示在**问答上方**：
                   用户是先选了原文才问的，回想时认的是那段原文
                   （与收藏详情页、导出 Markdown 同一口径）。
                   放在参数表**末尾**——尾参不改变任何既有调用点的行为。
@param surface     string|nil 这次回答来自哪个**入口**（light / chat / explain / summary…）。
                   白名单制、**默认拒绝**：不在白名单里（含不传 = nil）一律不挂收藏按钮。
                   与 `kind` 分开的理由见 Asker.FAVORITE_SURFACES 的注释。
--]]
function Asker:showResult(title, content, extra_note, question, ref, selection, surface)
    -- 分隔线按屏幕宽度现算；量不出来会退回短兜底，绝不写死一串
    local sep = buildSeparator()
    local text = content or ""
    --[[--
    章末总结的排版（真机第 7 轮望仔）：小标题加粗、正文首行缩进、段间空一行。

    **只在这一条 surface 上做**：其余入口的回答是"一问一答"的形态，不是
    "小标题 + 段落"，套上去只会把好好的一段话拆碎。

    **PTF 标记只活在这一个局部变量里**。`content` 本身（要进历史与缓存的那一份）
    一个字节都没动——非法码点混进缓存键会白烧 token，混进收藏详情会变豆腐块。
    跟 `Util.quoteBlock` 那条"缩进绝不混进发给模型那一份"是同一条纪律。

    `PTF` 为 nil（老 KOReader）时排版照旧走完，只是不加粗——见上面那段注释。
    --]]
    if surface == "chapter_summary" then
        text = Util.layoutSummary(text, PTF)
    end
    --[[--
    目标顺序（从上到下）：引文 → 你的问题 → 回答 → 补充说明。

    注意拼接方向：这里是**从里往外**一层层往前面插，所以**最后插的在最外层**
    （也就是屏幕上的最上面）。原来先插引文、后插提问，结果提问跑到最上面、
    引文掉在中间——测试里"引文必须在提问之上"那条断言就是这么抓出来的。
    实现在下：先提问、后引文。
    --]]
    if question and question ~= "" then
        text = _("【你的问题】") .. "\n" .. question .. "\n\n" .. sep .. "\n\n" .. text
    end
    local sel_block = Asker.selectionBlock(selection)
    if sel_block ~= "" then
        text = sel_block .. "\n\n" .. sep .. "\n\n" .. text
    end
    if extra_note and extra_note ~= "" then
        text = text .. "\n\n" .. sep .. "\n" .. extra_note
    end

    local viewer
    local buttons_table = nil
    --[[--
    E：挂不挂收藏按钮 = "这条回答在历史里有据可查"（ref 有效）**且** "这次回答来自
    允许收藏的入口"（surface 在白名单里）。两条缺一不可：

      · ref 无效（这条已经不在历史里）→ 不挂。挂了也是点了没反应的死按钮。
      · surface 不在白名单里 → 不挂。这正是用户这次要拿掉的东西：
        「AI解释」「AI摘要」的卡片上不该出现收藏按钮。

    白名单是**默认拒绝**的：`surface == nil`（没传 / 历史遗留行既无 surface 也无 kind）
    同样不挂。这是 user 的硬要求"能收藏的只有轻问和深聊"的直接翻译——白名单语义下，
    "新加一个入口忘了传 surface"必须是**安全的那一侧**（不挂按钮），不能因为漏传就
    静默拿到一个收藏按钮（错挂比漏挂危险得多：漏挂用户还能在收藏列表里找到，
    错挂则直接把用户的硬要求破坏了，且没有声音）。

    真机上 4 个调用点都**显式**传了 surface（见 showResult 的调用点清单），
    所以默认拒绝在真机上不改变任何一条正常路径；它防的是将来和夹具。
    落进"默认拒绝"的两种情况都按 team-lead 定案处理，不特殊照顾：
      · 新入口忘了传 surface → 无按钮（正是想要的安全侧）；
      · 历史遗留行既无 surface 也无 kind → 无按钮（无法确认它是轻问还是深聊，就不给收藏）。
    --]]
    local can_favorite = type(ref) == "table" and ref.book_fp ~= nil
        and type(ref.index) == "number"
    if can_favorite and Asker.FAVORITE_SURFACES[surface] ~= true then
        can_favorite = false
    end
    if can_favorite then
        local favored = Store:isFavorite(ref.book_fp, ref.index)
        buttons_table = {
            {
                {
                    -- id 是给按钮 update 用的：TextViewer 的 ButtonTable 支持按 id 取到
                    -- 真正的 Button 实例（getButtonById），收藏状态变了才能只改按钮文字，
                    -- 不把整个结果页重建一遍（重建会丢滚动位置，用户正读到一半就跳回顶部）。
                    id = Asker.FAVORITE_BUTTON_ID,
                    text = favored and _("取消收藏") or _("收藏"),
                    callback = function()
                        --[[--
                        用建卡时算好的 `favored` 取反，**不再现读一次 `Store:isFavorite`**。

                        这条通路本来就是"整份 JSON 读进来 → 改一个字段 → 整份写回去"，
                        每次点击少一次整份读就是实打实的减负（真机实测 29KB 的历史文件上
                        一次 isFavorite ≈ 7ms，300KB 上 ≈ 71ms）。
                        --]]
                        local now = Store:setFavorite(ref.book_fp, ref.index, not favored)
                        if now == nil then
                            -- 记录被别的操作删掉了：说清楚，别让用户以为收藏成功了
                            self:notify(_("收藏没有生效：这条记录已经不在历史里了"))
                            return
                        end
                        favored = now
                        Asker.refreshFavoriteButton(viewer, Asker.FAVORITE_BUTTON_ID,
                            now and _("取消收藏") or _("收藏"))
                        self:notify(now and _("已收藏，可在「我的问答收藏」里找到") or _("已取消收藏"))
                    end,
                },
            },
            {
                {
                    text = _("关闭"),
                    callback = function() Asker.closeResult(viewer) end,
                },
            },
        }
    end

    viewer = TextViewer:new{
        title = title or _("远望书友"),
        text = text,
        buttons_table = buttons_table,
    }
    UIManager:show(viewer)
    return viewer
end

--[[--
即时提问并展示结果（释义/摘要/概念解释/深聊）。
--]]
function Asker:askAndShow(opts)
    local title = opts.title or _("远望书友")
    --[[--
    surface = 这次回答的入口。默认取 kind（长按菜单里的「AI解释」「AI摘要」就是
    kind=explain/summary，两者都不在收藏白名单里 → 卡片上不挂收藏按钮）。
    调用方可以显式传 surface 覆盖它（比如将来某个入口的 kind 与入口名不一致）。
    --]]
    opts.surface = opts.surface or opts.kind
    Trapper:wrap(function()
        Trapper:info(self:thinkingText())
        local content, err, from_cache, spoiler_hit, _truncated, stored = self:askSync(opts)
        if Trapper:isWrapped() then Trapper:clear() end
        if not content then
            UIManager:show(InfoMessage:new{ text = _("请求失败：") .. tostring(err) })
            return
        end
        local note = from_cache and _("（来自本地缓存，未消耗 token）") or nil
        -- 收藏按钮的前提是"这条回答在历史里有据可查"：命中缓存时不写新记录，
        -- 于是用回答原文把之前那条找回来（locateStoredTurn），找回不来就不挂按钮。
        local ref = self:locateStoredTurn(opts.book_fp, content, stored)
        -- 引文第五个位置之后传：不显示引文的话用户记不得这段回答是对哪段原文说的
        -- 第七个是 surface：这一路只可能是长按菜单里的 explain/summary（白名单外）
        self:showResult(title, content, note, opts.question, ref, opts.selected, opts.surface)
        if spoiler_hit then
            self:notify(_("已按防剧透规则屏蔽后续章节内容"))
        end
    end)
end

--[[--
轻问：提交即返回，回复异步送达（PRD F1.2：不打断阅读流）。
回复完成后只弹一条 Notification，并把结果存到 plugin.last_reply 供菜单查看。
--]]
function Asker:submitAsync(plugin, opts)
    local question = opts.question or ""
    --[[--
    surface 固定是 light：**这个入口本身就叫「轻问」**（UI 上的名字），
    哪怕用户把输入框留空、kind 退化成 explain（见 FAVORITE_SURFACES 的注释），
    他看到的卡片标题仍然是「远望书友-轻问回复」，所以这一路必须能收藏。
    存进历史也用它，免得"刚问完能收藏、回头在『查看最近回复』里又不能收藏"。
    --]]
    opts.surface = opts.surface or "light"
    logger.info("YWBF: submitAsync kind=", tostring(opts.kind), " sel_len=", #(opts.selected or ""))
    self:notify(T(_("已交给%1，回复稍后送达"), Prompts.PERSONA_NAME))

    -- Queue:process() 只把 fn 的第一个返回值传给 on_done，
    -- 防剧透命中标记和"这一轮存在历史里的位置"都用闭包变量带出去。
    local spoiler_hit = false
    local stored_row = nil

    Queue:submit({
        name = "light_" .. (opts.kind or "ask"),
        fn = function()
            logger.info("YWBF: queue task start")
            local content, err, from_cache, hit, _truncated, stored = self:askSync(opts)
            logger.info("YWBF: queue task done, ok=", content ~= nil, " err=", tostring(err))
            spoiler_hit = (hit == true)
            stored_row = stored
            if spoiler_hit then
                self:notify(_("已按防剧透规则屏蔽后续章节内容"))
            end
            return content, err
        end,
        on_done = function(content)
            -- ref 要在建 reply 之前算出来：reply 里要带上定位，
            -- 否则"查看最近回复"回退到历史读出来时挂不上收藏按钮。
            local ref = self:locateStoredTurn(opts.book_fp, content, stored_row)
            local reply = {
                content = content,
                kind = opts.kind or "light",
                -- 入口（决定"回头在『查看最近回复』里还挂不挂收藏按钮"），见 FAVORITE_SURFACES
                surface = opts.surface,
                title = opts.title or _("轻问回复"),
                ts = os.time(),
                selection = opts.selected or "",
                question = question,      -- 必须带上：只显示回答用户不知道问的是什么
                spoiler_hit = spoiler_hit,
                -- 定位信息带上之后，"查看最近回复"即使是从历史回退读出来的，
                -- 也能挂上收藏按钮（否则只有刚问完那一次能收藏，关掉书就不行了）。
                book_fp = opts.book_fp,
                index = ref and ref.index or nil,
            }
            plugin.last_reply = reply
            self:notify(T(_("%1回复已就绪"), Prompts.PERSONA_NAME))
            -- 用户要求「快速查看，不用去菜单里找」：默认直接弹出结果卡片，
            -- 问题显示在回答上方。可在设置里关掉，退回只发通知、不打断阅读。
            if Config:get("light_auto_popup") then
                local note = _("（轻问回复 · 关闭后可在设置里改为仅通知）")
                if spoiler_hit then
                    note = _("已按防剧透规则屏蔽未读内容") .. "\n" .. note
                end
                -- 轻问的回复同样可以收藏：用户刚刚花钱拿到的回答，
                -- 关掉通知就找不回来了，收藏是唯一留得住它的动作
                -- 引文取自 reply.selection（submitAsync 建 reply 时就把 opts.selected 带上了）
                -- 第七个位置是 surface：这一路恒为 light（见本函数开头）
                self:showResult(reply.title, content, note, question, ref, reply.selection,
                    reply.surface)
            end
        end,
        on_error = function(err)
            logger.warn("YWBF: submitAsync failed:", tostring(err))
            -- 拟人化，但 err 必须照旧带出来：用户要拿它判断是网络、Key 还是余额的问题
            self:notify(T(_("%1这边没能拿到回复："), Prompts.PERSONA_NAME) .. tostring(err))
        end,
    })

    -- 延后一点执行，先把控制权交还给阅读界面
    UIManager:scheduleIn(1, function()
        Trapper:wrap(function()
            Queue:process()
        end)
    end)
end

--[[--
章末总结（望仔拍板第 3 项：默认关 + 主菜单常驻手动入口）。

**为什么不复用 `askSync`**：它在 173 行用 `Context.fromSelection(page_text, selected, 800)`
构造上下文——那是"选中位置前后各 800 字"的窗口语义。章总结没有"选中内容"，
`fromSelection` 匹配不到会退化成空串，再被 `truncateWindow` 按"未读章节标题"剪一刀，
剪的位置也不是我们要的章边界。

**为什么不走 `submitAsync`**：它在 655 行写死 `opts.surface = opts.surface or "light"`，
会把章总结算成轻问 ⇒ 既进收藏白名单（冒出收藏按钮）又写进问答历史（污染收藏池）。

所以这里是**第三条路**，但每一道防剧透防线都照旧走，一道不省：
  · `Spoiler.withConfig` + `spoilerNote` + `spoilerHint`（system + user 双保险）
  · `DeepSeek:chat(..., { spoiler_progress = prog })` —— 防剧透管道的单点出口
  · 缓存出库同样过 `Spoiler.sanitizeAnswer`（缓存是历史泄漏路径）
外加一道别人没有的：**正文由调用方按"整章读完"取好才传进来**，
未读文本物理上根本没进过 payload。

@param opts { book_fp, chapter_key, chapter_label, chapter_text, progress }
@return content, err, from_cache, spoiler_hit, truncated
--]]
function Asker:summarizeChapter(opts)
    opts = opts or {}
    local prog = opts.progress
    if prog == nil then
        prog = self:fetchProgress()
        if prog == nil then
            logger.warn("YWBF: progress missing at chapter_summary")
        else
            logger.info("YWBF: progress recovered via provider at chapter_summary")
        end
    end
    prog = Spoiler.withConfig(prog, Spoiler.currentConfig())

    local chapter_text = type(opts.chapter_text) == "string" and opts.chapter_text or ""
    local model = Config:get("model")
    local style = Prompts.normalizeStyleKey(Config:get("reply_style"))

    --[[--
    缓存 seed **必须带章标识**。`Cache:keyFor` 的 seed 在别处是
    `selected .. "|" .. question`，章总结两个都没有；留空的话同一本书
    **每一章都会撞成同一个键**，表现为"每章都返回第一次的总结"——
    那不是省钱，是直接毁掉这个功能。
    --]]
    local cache_seed = "chapter:" .. tostring(opts.chapter_key or "")
    if style ~= Prompts.STYLE_DEFAULT then
        cache_seed = cache_seed .. "|style:" .. style
    end
    local cache_key = Cache:keyFor(opts.book_fp, cache_seed, "chapter_summary", model)

    if Config:get("cache_enabled") then
        local hit = Cache:get(cache_key)
        if hit then
            logger.info("YWBF: cache hit, kind=chapter_summary")
            local safe, was_hit = Spoiler.sanitizeAnswer(hit, prog)
            return safe, nil, true, was_hit, false
        end
    end

    local ctx = "【本章】" .. tostring(opts.chapter_label or "") .. "\n\n" .. chapter_text
    local messages = Prompts.build("chapter_summary", {
        context = ctx,
        spoiler_note = Prompts.spoilerNote(prog),
        spoiler_hint = Prompts.spoilerHint(prog),
        style = style,
    })

    local params = TASK_PARAMS.chapter_summary
    local res, err = DeepSeek:chat(messages, {
        model = model,
        temperature = Config:get(params.temperature),
        max_tokens = Config:get(params.max_tokens),
        spoiler_progress = prog,
    })
    if not res then return nil, err, false, false, false end

    local truncated = false
    local choice = type(res.raw) == "table" and type(res.raw.choices) == "table"
        and res.raw.choices[1] or nil
    if type(choice) == "table" and choice.finish_reason == "length" then
        truncated = true
        logger.warn("YWBF: output truncated by max_tokens, kind=chapter_summary")
    end

    -- 被输出长度截断的**不进缓存**：缓存命中那条 early return 走不到这里、
    -- 带不出 truncated，残句会被当成正常输出反复返回。
    if Config:get("cache_enabled") and not truncated then
        Cache:set(cache_key, res.content)
    end
    logger.info("YWBF: chapter summary ok, tokens=",
        tostring(res.usage and res.usage.total_tokens))
    -- **不写历史**：章总结不是一轮问答（与 ideas 同理），
    -- 写进 Store 会污染笔记/导出，也会让收藏池里多出一条没头没尾的 assistant 行。
    return res.content, nil, false, (res.spoiler_hit == true), truncated
end

--[[--
章末总结的异步外壳（一次总结 1–3 分钟，绝不能同步阻塞阅读器）。

照抄 `ui/settings.lua:281-300` 那套：进度提示**不带 timeout**，
结果回来**先 close 再 show**（`timeout=1` 的短提示会叠成好几层）。
--]]
function Asker:summarizeChapterAsync(plugin, opts)
    opts = opts or {}
    --[[--
    `on_done` 是**在途锁**的解锁钩子（main.lua 的手动入口节流要用）。

    成功和失败两条路都得调：锁是为了不让人连点出五份整章正文 + 五次真 API
    调用，只要这一次"结束了"（成不成都算结束）就该放人进来。放在调用方
    `pcall` 外面更保险，但 Trapper:wrap 里的异常不该把锁永久留在那儿 ——
    见 main.lua 里那道 TTL：超时之后锁自动失效。
    --]]
    local done = (type(opts.on_done) == "function") and opts.on_done or nil
    local function finish()
        if done then pcall(done) end
    end
    Trapper:wrap(function()
        Trapper:info(self:thinkingText())
        local content, err, from_cache, spoiler_hit, truncated = self:summarizeChapter(opts)
        if Trapper:isWrapped() then Trapper:clear() end
        if not content then
            UIManager:show(InfoMessage:new{ text = _("请求失败：") .. tostring(err) })
            finish()
            return
        end

        local note = type(opts.note) == "string" and opts.note or nil
        local function append(line)
            note = (note and note ~= "") and (note .. "\n" .. line) or line
        end
        if from_cache then append(_("（来自本地缓存，未消耗 token）")) end
        if truncated then append(_("（回答较长，结尾可能不完整）")) end

        --[[--
        第 5 参 ref 传 nil、第 7 参显式传 `surface = "chapter_summary"`：
          · surface 不在 `FAVORITE_SURFACES`（默认拒绝）⇒ 不挂收藏按钮；
          · ref 为 nil ⇒ 连按钮表都不会建。两道闸门，任一道单独成立就够了。
        --]]
        self:showResult(opts.title or _("本章总结"), content, note, nil, nil, nil,
            "chapter_summary")
        if spoiler_hit then
            self:notify(_("已按防剧透规则屏蔽后续章节内容"))
        end
        finish()
    end)
end

return Asker
