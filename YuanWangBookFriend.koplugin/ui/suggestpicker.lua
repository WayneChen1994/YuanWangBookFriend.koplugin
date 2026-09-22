--[[--
「你可能想问」：给"不知道该问什么"的用户几条现成的问题。

两条来源，两条不同的成本：
  · 本地启发式（ywbf/suggest.lua）：零 API 调用、瞬时、但通用
    （"这段讲了什么""它和前后文有什么联系"——任何一段都能套）；
  · AI 出题（kind = ideas）：真实调一次 API（max_tokens 300，结果进缓存），
    但能问出"袭人为什么偏偏在这个时点提起宝玉的玉"这种只有读过这段才问得出口的问题。

AI 那条路默认开着，但必须让用户知道它花钱：按钮上写「用一次额度」，
设置里给一个开关关掉它，关掉后退回零开销的本地建议。

选中一条之后**只回填输入框、不直接发出**：
直接发出虽然少一步，但误触就是一次真实请求（花钱），
而且用户很可能想在建议的基础上改几个字。回填后由他显式点「发送」。

**弹层顺序的铁律（真机踩过的坑）**：
选择层绝不能叠在还开着的 InputDialog 上——InputDialog 连同它的虚拟键盘
会盖在上面，弹层点了没反应、也关不掉。
本文件里所有"先关当前弹层、再开下一个"的地方都是这个原因，改的时候别顺手改回去。
--]]

local Asker = require("ui/asker")
local Config = require("ywbf/config")
local Prompts = require("ywbf/prompts")
local Suggest = require("ywbf/suggest")
local Util = require("ywbf/util")

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local SuggestPicker = {}

--[[--
弹层标题。刻意不在模块加载期就调 `_()`：
那时翻译目录可能还没装好，提前固化成原文会让后续切语言失效。
--]]
function SuggestPicker:localTitle()
    return _("你可能想问：")
end

function SuggestPicker:aiTitle()
    return T(_("%1建议问："), Prompts.PERSONA_NAME)
end

function SuggestPicker:aiButtonText()
    return T(_("让%1来问（用一次额度）"), Prompts.PERSONA_NAME)
end

function SuggestPicker:thinkingText()
    return T(_("%1正在想问题…"), Prompts.PERSONA_NAME)
end

-- 默认开启：需要它的人往往不会主动去设置里打开它
function SuggestPicker:enabled()
    return Config:get("show_suggestions") ~= false
end

--[[--
AI 出题入口是否可用。

两个条件：设置开关没被关掉，且**真的有选中文本**——
没有选中文本时 AI 也没有可依据的段落，问出来只会是空话，
那就不如不给这个按钮（白花一次额度）。
@param opts table|nil
@return bool
--]]
function SuggestPicker:aiEnabled(opts)
    if Config:get("ai_suggestions") == false then return false end
    local o = type(opts) == "table" and opts or {}
    return not Util.isEmpty(o.selected)
end

--[[--
取本地建议问题列表。
整段 pcall 包住：拿不到建议只是少一个入口，绝不能让提问框打不开。
@return array（可能为空）
--]]
function SuggestPicker:list(opts)
    if not self:enabled() then return {} end
    local ok, list = pcall(Suggest.list, opts)
    if not ok or type(list) ~= "table" then
        logger.info("YWBF: suggest unavailable:", tostring(list))
        return {}
    end
    return list
end

--[[--
真正弹选择层（内部实现，show / showAi 都走这里）。

@param list      string[] 已经算好的问题列表（非空）
@param title     string   弹层标题（区分本地建议与 AI 建议）
@param opts      table    透传给 showAi 的原始 opts
@param on_pick   function(question)
@param on_cancel function()
@param allow_ai  bool 是否显示「让小望来问」按钮
@return bool 是否真的弹出
--]]
function SuggestPicker:_showList(list, title, opts, on_pick, on_cancel, allow_ai)
    if type(list) ~= "table" or #list == 0 then return false end

    local dialog
    local rows = {}
    for _i, q in ipairs(list) do
        rows[#rows + 1] = {
            {
                text = q,
                callback = function()
                    UIManager:close(dialog)
                    if on_pick then on_pick(q) end
                end,
            },
        }
    end

    -- AI 出题入口。文案必须写「用一次额度」：这是真实付费请求，
    -- 不能让用户点下去才发现扣了钱。
    if allow_ai then
        rows[#rows + 1] = {
            {
                text = self:aiButtonText(),
                callback = function()
                    -- 先关再开：叠在还开着的弹层之上会点不动也关不掉
                    UIManager:close(dialog)
                    self:showAi(opts, on_pick, on_cancel)
                end,
            },
        }
    end

    rows[#rows + 1] = {
        {
            text = _("返回"),
            callback = function()
                UIManager:close(dialog)
                if on_cancel then on_cancel() end
            end,
        },
    }

    dialog = ButtonDialog:new{
        title = title,
        buttons = rows,
        -- 点空白处也会关闭，同样要交给 on_cancel 兜住
        tap_close_callback = function()
            if on_cancel then on_cancel() end
        end,
    }
    UIManager:show(dialog)
    return true
end

--[[--
弹出选择页，选中后把问题回填进调用方的输入框。

**调用前必须先把输入框关掉**（由调用方负责）：
选择层不能叠在还开着的 InputDialog 上——InputDialog 连同它的虚拟键盘
会盖在上面，弹层点了没反应、也关不掉（真机实测就是这个症状）。
正确顺序是：关闭输入框 → 弹选择层 → 选中后用问题重新打开输入框。

@param opts        传给 Suggest.list：{ kind, selected, context, max }；
                   另外可带 page_text / book_fp / progress —— 只有 AI 出题那条路用得上，
                   缺了也不会崩（防剧透会退化到"拿不到进度"的告警路径）
@param on_pick     function(question) 选中回调（由调用方决定怎么回填）
@param precomputed 可选：调用方已经算好的列表。传了就直接用，不再算第二遍——
                   按钮上显示的条数必须和弹出来的条数是同一份，否则会自相矛盾。
@param on_cancel   可选：点了「返回」或点空白处关闭时的回调。
                   调用方通常在这里把输入框重新打开，否则用户就被晾在半路了。
@param allow_ai    可选：强制决定要不要挂「让小望来问」按钮。
                   不传（nil）= 按 aiEnabled(opts) 自己判断；
                   传 false = 明确不挂（AI 出题刚失败、再点也拿不到新东西时用）。
@return bool       是否真的弹出了（没有建议时 false，调用方据此禁用入口按钮）
--]]
function SuggestPicker:show(opts, on_pick, precomputed, on_cancel, allow_ai)
    local o = type(opts) == "table" and opts or {}
    local list = (type(precomputed) == "table" and #precomputed > 0)
        and precomputed or self:list(o)
    if #list == 0 then return false end
    local allow = (allow_ai == nil) and self:aiEnabled(o) or (allow_ai == true)
    return self:_showList(list, self:localTitle(), o, on_pick, on_cancel, allow)
end

--[[--
让 AI 针对当前选中的段落现出几条问题（kind = ideas）。

**调用前必须先把当前弹层关掉**（与 show 同一条铁律）：本函数会先走一次
网络请求（Trapper 弹"正在想问题"），期间任何还开着的弹层都会挡住它。

失败时绝不把用户晾在半路：报错之后用本地列表重新弹一层选择页，
用户至少还能选一条本地建议继续。

防剧透：走 Asker:askSync 同一条管道，progress 由调用方从 opts 里带进来，
拿不到时 askSync 自己会向 main.lua 注册的 provider 再取一次并打 warn。

@param opts      { selected, page_text|context, book_fp, progress, max }
@param on_pick   function(question)
@param on_cancel function()
--]]
function SuggestPicker:showAi(opts, on_pick, on_cancel)
    local o = type(opts) == "table" and opts or {}
    local selected = o.selected or ""

    Trapper:wrap(function()
        Trapper:info(self:thinkingText())
        -- 第五个返回值 truncated：输出被 max_tokens 截断时为 true。
        -- 必须往下传给 parseList —— 被截断时最后一行几乎必然是半句话，
        -- 而"漏写问号的完整句子"和"被截断的残句"在文本上长得一样，本地判不了。
        local content, err, from_cache, _spoiler_hit, truncated = Asker:askSync({
            kind = "ideas",
            selected = selected,
            page_text = o.page_text or o.context,
            book_fp = o.book_fp,
            progress = o.progress,
        })
        if Trapper:isWrapped() then Trapper:clear() end

        -- parseList 的契约是"永不返回 nil、永不抛异常"，但那份契约是 suggest.lua
        -- 里的代码在维持的；这里若对自己的调用方零防御，等于把整条路径挂在别人的
        -- 自律上。QA 的 M4 变异实测过：那边一返回 nil，这里 #list 直接抛异常，
        -- UI 表现是"点了没反应、也不报错"——比明确报错更难排查。
        -- 一行兜底：拿不到表就当没有解析结果，走下面的本地列表兜底路径。
        local parsed = nil
        if type(content) == "string" then
            parsed = Suggest.parseList(content, o.max, truncated)
        end
        local list = type(parsed) == "table" and parsed or {}
        logger.info(string.format("YWBF: ideas parsed %d from %d chars (cache=%s truncated=%s)",
            #list, type(content) == "string" and #content or 0,
            tostring(from_cache), tostring(truncated)))

        if #list > 0 then
            -- AI 结果页不再挂「让小望来问」：那是第二次付费，且大概率得到同一批问题
            self:_showList(list, self:aiTitle(), o, on_pick, on_cancel, false)
            return
        end

        -- 失败或解析不出东西：说清楚原因，再用本地列表重新弹一层
        local reason
        if content == nil then
            reason = _("请求失败：") .. tostring(err)
        else
            reason = _("AI 这次没给出可用的问题，下面是本地建议：")
        end
        UIManager:show(InfoMessage:new{ text = reason })

        --[[--
        失败之后还要不要给「让小望来问」这个入口？

        判据只有一条：**这次重试会不会拿到新东西**。会就留，不会就摘。

          · 请求失败（content == nil，网络/超时/Key 出问题）：缓存里没有东西，
            再点是真重试、有可能成功 —— 保留。按钮写着「用一次额度」，没骗人。
          · 有内容但解析不出（content ~= nil 却 0 条），**且缓存开着**：
            那份内容已经进缓存（asker 的 Cache:set 就在这次调用里），
            再点必然命中同一份、拿到同样的空结果 —— 点了也白点；
            更要命的是按钮写着「用一次额度」却因为命中缓存根本没花，
            文案和事实不符，比不给更误导 —— 摘掉。
          · 有内容但解析不出，**且缓存关着**：什么都没存下来，再点会真发一次
            新请求（temperature 0.7，可能抽出能解析的结果），那次额度**真的会被扣**
            —— 按钮说的和发生的是一回事，没有理由摘 —— 保留。
          · 有内容但解析不出，**且这次是截断输出**（finish_reason == "length"）：
            asker 明确不给截断结果进缓存，所以再点同样是真请求、真扣额度 —— 保留。
            这条必须单列：cache_enabled 是开着的，可这份内容偏偏没进缓存，
            只按配置判断会得到"点了也白点"的错误结论，把用户的重试权摘掉。

        所以摘按钮的唯一理由是"再点也拿到同一份东西"，其余一律保留用户的重试权。
        判据取自事实（请求失败 / 没进缓存），不是我拍脑袋判断"这次没戏"。
        --]]
        local allow_ai = (content == nil)
            or (truncated == true)
            or not Config:get("cache_enabled")

        -- 连本地建议都弹不出来（例如开关关掉了）时，也要把输入框还给用户——
        -- 否则他就停在一条报错上，哪都去不了
        if not self:show(o, on_pick, nil, on_cancel, allow_ai) then
            if on_cancel then on_cancel() end
        end
    end)
end

return SuggestPicker
