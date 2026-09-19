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

local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Asker = {}

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

    -- 截断的 ideas **不进缓存**：缓存命中那条 early return 走不到这里、带不出
    -- truncated 标志，残句会被当成正常输出再收一次。不缓存 = 下次真的重发一次，
    -- 那次拿到的多半是完整输出（而且 ideas 才 300 token，重试成本可接受）。
    if Config:get("cache_enabled") and not (truncated and kind == "ideas") then
        Cache:set(cache_key, res.content)
    end
    -- ideas 不进历史：它不是一轮问答，只是"帮你把问题想出来"的中间产物。
    -- 写进 Store 会污染笔记/对话导出（用户会看到一堆自己没问过的问题），
    -- 也会让"继续追问"的上下文里混进莫名其妙的 assistant 发言。
    -- 缓存照存（那是省钱的，上面那句把"截断"的排除了），历史不落。
    if opts.book_fp and kind ~= "ideas" then
        Store:append(opts.book_fp, { role = "assistant", content = res.content, kind = kind, selection = selected })
        if not Util.isEmpty(opts.question) then
            Store:append(opts.book_fp, { role = "user", content = opts.question, kind = kind, selection = selected })
        end
    end
    logger.info("YWBF: ask ok, kind=", kind, " tokens=", tostring(res.usage and res.usage.total_tokens))
    -- 第五个返回值 truncated：只有真正走了请求才有意义。
    -- 缓存命中的 early return 不带它（nil = false），语义正确：
    -- 能进缓存的都是完整输出，被截断的那次我们根本没存。
    return res.content, nil, false, (res.spoiler_hit == true), truncated
end

--[[--
结果展示（墨水屏：纯文本、可滚动、无渐变）。

@param question 可选。轻问/追问场景下必须带上——只显示回答不显示问题，
用户根本不知道这段回答是针对哪个问题说的。问题显示在回答上方。
--]]
function Asker:showResult(title, content, extra_note, question)
    local text = content or ""
    if question and question ~= "" then
        text = _("【你的问题】") .. "\n" .. question .. "\n\n———\n\n" .. text
    end
    if extra_note and extra_note ~= "" then
        text = text .. "\n\n———\n" .. extra_note
    end
    local viewer = TextViewer:new{
        title = title or _("远望书友"),
        text = text,
    }
    UIManager:show(viewer)
    return viewer
end

--[[--
即时提问并展示结果（释义/摘要/概念解释/深聊）。
--]]
function Asker:askAndShow(opts)
    local title = opts.title or _("远望书友")
    Trapper:wrap(function()
        Trapper:info(_("AI 思考中…"))
        local content, err, from_cache, spoiler_hit = self:askSync(opts)
        if Trapper:isWrapped() then Trapper:clear() end
        if not content then
            UIManager:show(InfoMessage:new{ text = _("请求失败：") .. tostring(err) })
            return
        end
        local note = from_cache and _("（来自本地缓存，未消耗 token）") or nil
        self:showResult(title, content, note)
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
    logger.info("YWBF: submitAsync kind=", tostring(opts.kind), " sel_len=", #(opts.selected or ""))
    self:notify(_("已提交给 AI，回复稍后送达"))

    -- Queue:process() 只把 fn 的第一个返回值传给 on_done，
    -- 防剧透命中标记用闭包变量带出去。
    local spoiler_hit = false

    Queue:submit({
        name = "light_" .. (opts.kind or "ask"),
        fn = function()
            logger.info("YWBF: queue task start")
            local content, err, from_cache, hit = self:askSync(opts)
            logger.info("YWBF: queue task done, ok=", content ~= nil, " err=", tostring(err))
            spoiler_hit = (hit == true)
            if spoiler_hit then
                self:notify(_("已按防剧透规则屏蔽后续章节内容"))
            end
            return content, err
        end,
        on_done = function(content)
            local reply = {
                content = content,
                kind = opts.kind or "light",
                title = opts.title or _("轻问回复"),
                ts = os.time(),
                selection = opts.selected or "",
                question = question,      -- 必须带上：只显示回答用户不知道问的是什么
                spoiler_hit = spoiler_hit,
            }
            plugin.last_reply = reply
            self:notify(_("AI 回复已就绪"))
            -- 用户要求「快速查看，不用去菜单里找」：默认直接弹出结果卡片，
            -- 问题显示在回答上方。可在设置里关掉，退回只发通知、不打断阅读。
            if Config:get("light_auto_popup") then
                local note = _("（轻问回复 · 关闭后可在设置里改为仅通知）")
                if spoiler_hit then
                    note = _("已按防剧透规则屏蔽未读内容") .. "\n" .. note
                end
                self:showResult(reply.title, content, note, question)
            end
        end,
        on_error = function(err)
            logger.warn("YWBF: submitAsync failed:", tostring(err))
            self:notify(_("AI 请求失败：") .. tostring(err))
        end,
    })

    -- 延后一点执行，先把控制权交还给阅读界面
    UIManager:scheduleIn(1, function()
        Trapper:wrap(function()
            Queue:process()
        end)
    end)
end

return Asker
