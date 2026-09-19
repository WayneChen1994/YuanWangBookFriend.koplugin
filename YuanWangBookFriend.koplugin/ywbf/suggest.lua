--[[--
「你可能想问」建议问题生成器（纯本地启发式）。

为什么是本地生成、不走 AI：
  这个功能本身就是给"不知道该问什么"的人用的。如果为了拿到几条建议
  还要先等一次 API 往返（KPW4 上动辄几秒到几十秒），等于把门槛又抬回去
  一次——本末倒置。而且设备是越狱 Kindle KPW4，用户对 token 消耗很敏感，
  建议问题绝不值得花 token。所以这里全部是零 API 调用的启发式：
  只读选中文本的形状（长度、引号、标点、人称），按 kind 换提问角度。

设计约束：
  1. 永远返回数组，绝不返回 nil，绝不抛异常（外层 pcall 兜底）；
  2. 每条 ≤ 20 个中文字符（墨水屏一行放得下，超了会被截断成丑陋的半句）；
  3. 输入可能带非法 UTF-8 字节（epub 正文常见，我们为此踩过 DeepSeek 400），
     生成前一律过 Util.sanitizeUtf8 / sanitizeForDisplay / collapseWhitespace；
  4. 不 require 任何 KOReader UI 模块，可直接在无头 luajit 里单测；
  5. LuaJIT = Lua 5.1：无 `~` 位运算、无 goto；循环变量一律 `_i`（`_` 会被
     文件顶部 `local _ = require("gettext")` 遮蔽成数字，进而让 `_()` 崩掉）。

对外 API：
  Suggest.list(opts) -> string[]          本地启发式建议（零 API 调用）
    opts.kind     "explain" | "summary" | "chat" | "light"（缺省/未知 → "chat"）
    opts.selected 用户选中的文本（可 nil、可含脏字节、可含换行）
    opts.context  选中位置前后的上下文（可 nil）
    opts.max      最多返回几条（缺省/非法 → 4，上限 6）
  Suggest.parseList(text, max) -> string[]  解析 AI 出题（kind = ideas）的返回文本
  Suggest.normalizeKind(kind) -> string
  Suggest.normalizeMax(n)     -> number

两个 list 的契约完全一致：永不返回 nil、永不抛异常。区别在于失败时的形态——
list 保证至少给 1 条（本地兜底池总能凑出来），parseList 允许返回空数组，
由 UI 层决定退回本地列表还是提示用户（AI 的输出没法凭空造）。
--]]--

local Util = require("ywbf/util")

local Suggest = {}

-- ---------- 可调常量（UI 层想改口径可以直接读这些） ----------
Suggest.MAX_LEN = 20          -- 单条问题最大字符数（中文字符，不是字节）
Suggest.DEFAULT_MAX = 4       -- 缺省返回条数
Suggest.MAX_LIMIT = 6         -- 硬上限：墨水屏一屏放不下更多
Suggest.SHORT_MAX = 12        -- ≤ 12 字视为"在问一个词/短语"
Suggest.LONG_MIN = 100        -- ≥ 100 字视为"整段"
Suggest.TERM_MAX = 8          -- 嵌入问题里的词最多几个字（给前后缀留位置）
Suggest.DEFAULT_KIND = "chat"

-- ---------- 启发式词表 ----------
-- 注意：中文是多字节，绝不能写成 s:find("[“”]") 这种字节字符类——
-- 0x80 这类续字节会被单独匹配到，导致"…"之类的字被误判成引号。
-- 这里全部用 plain find 逐个匹配。

-- 引号与对话痕迹
local DIALOG_MARKS = {
    "“", "”", "‘", "’", "「", "」", "『", "』", "\"", "'",
    "说道", "问道", "答道", "笑道", "喊道", "低声", "答曰", "回道",
}

-- 情绪/语气标记
local MOOD_MARKS = { "？", "！", "?", "!" }

-- 人称与称谓（简单启发式，覆盖常见中文叙事即可，不做人名识别）
local PERSON_WORDS = {
    "他", "她", "我", "你", "咱", "您",
    "父亲", "母亲", "爸爸", "妈妈",
    "哥哥", "姐姐", "弟弟", "妹妹",
    "先生", "太太", "夫人", "老爷", "少爷", "姑娘", "公子",
    "老师", "同学", "朋友", "师傅", "大人", "将军", "陛下",
}

-- 句内断点：出现这些就不是"一个词"，而是一句话/一个分句。
-- 没有这条判断的话，「你当真不认得我了么？」会被当成术语问成
-- 「『你当真不认得我了么』这个词该怎么理解？」——一句完整的话这么问很别扭。
local BREAK_MARKS = {
    "。", "，", "、", "；", "：", "！", "？", "…",
    ".", ",", ";", ":", "!", "?",
    " ", "\t",
}

-- 句末标点：取"词"时剥掉，避免变成「望乡。」这种
local TAIL_PUNCT = {
    "。", "，", "、", "；", "：", "！", "？", "…", "”", "」", "』", "'", "\"",
    ".", ",", ";", ":", "!", "?",
}

-- ---------- 规则表 ----------
-- 每条规则：{ name, match(f)->bool, ask[kind] = string | function(f)->string }
-- 顺序即优先级：命中多条时按序取前 max 条，不会全部堆上去。
-- ask 支持函数，用于把选中词嵌进问题里（个性化）。
local RULES = {}

-- 1) 对话痕迹 → 人物关系 / 说话动机
RULES[#RULES + 1] = {
    name = "dialogue",
    match = function(f) return f.has_dialogue end,
    ask = {
        explain = "这段对话体现了两人什么关系？",
        summary = "这段对话的核心分歧是什么？",
        chat    = "两人此刻各怀什么心思？",
        light   = "这段对话最有意思的点在哪？",
    },
}

-- 2) 很短（像在问一个词）→ 这个词在当前语境里的具体所指
RULES[#RULES + 1] = {
    name = "term",
    -- 命中句内断点就说明这是个短语/句子，不该按"一个词"来问；
    -- 让位给 mood / person 这些规则（「你当真不认得我了么？」会落到"想达到什么效果"）
    match = function(f) return f.is_short and f.term ~= "" and not f.has_break end,
    ask = {
        explain = function(f) return "这里的「" .. f.term .. "」具体指什么？" end,
        summary = function(f) return "「" .. f.term .. "」在段落里起什么作用？" end,
        chat    = function(f) return "「" .. f.term .. "」这个词该怎么理解？" end,
        light   = function(f) return "「" .. f.term .. "」背后有什么讲究？" end,
    },
}

-- 3) 很长 → 段落主旨
RULES[#RULES + 1] = {
    name = "long_gist",
    match = function(f) return f.is_long end,
    ask = {
        explain = "这段话的核心意思是什么？",
        summary = "这段的主干信息是什么？",
        chat    = "这段想表达的是什么？",
        light   = "这段讲了件什么事？",
    },
}

-- 4) 很长 → 在全书结构里起什么作用
RULES[#RULES + 1] = {
    name = "long_role",
    match = function(f) return f.is_long end,
    ask = {
        explain = "这段在全书里起什么作用？",
        summary = "这段能归进哪个环节？",
        chat    = "这段为什么放在这里？",
        light   = "去掉这段会少点什么？",
    },
}

-- 5) 含问号/感叹号 → 说话人的情绪或意图
RULES[#RULES + 1] = {
    name = "mood",
    match = function(f) return f.has_mood end,
    ask = {
        explain = "说话人此刻是什么情绪？",
        summary = "这句话的情绪要点是什么？",
        chat    = "他这句话想达到什么效果？",
        light   = "这句为什么说得这么重？",
    },
}

-- 6) 含人称/称谓 → 这个人物的处境
RULES[#RULES + 1] = {
    name = "person",
    match = function(f) return f.has_person end,
    ask = {
        explain = "这个人此刻是什么处境？",
        summary = "这段里这个人的处境如何？",
        chat    = "这个人为什么这么做？",
        light   = "这个人物身上有什么看点？",
    },
}

-- 7) 有前后文 → 和前后文的联系（只有传了 context 才问，否则问了也答不上来）
RULES[#RULES + 1] = {
    name = "context",
    match = function(f) return f.has_context end,
    ask = {
        explain = "它和前后文有什么联系？",
        summary = "它和前后文怎么衔接？",
        chat    = "它和前后文有什么联系？",
        light   = "它和前后文有什么联系？",
    },
}

-- ---------- 通用兜底池 ----------
-- 任何输入都靠它补齐；没命中任何启发式时（比如空选中）整份返回就是它。
local GENERIC = {
    explain = {
        "这段在讲什么？",
        "作者为什么这样写？",
        "它和前后文有什么联系？",
        "这里有没有隐含的意思？",
    },
    summary = {
        "这段讲了什么？",
        "这段的主干是什么？",
        "有哪些信息可以略过？",
        "它和前后文有什么联系？",
    },
    chat = {
        "这段在讲什么？",
        "它和前后文有什么联系？",
        "作者这样写有什么讲究？",
        "你对这段有什么看法？",
    },
    light = {
        "这段讲了什么？",
        "这里最耐人寻味的是什么？",
        "作者这样写有什么讲究？",
        "如果换你来写会怎么写？",
    },
}

-- pcall 都失败时的最后一道静态兜底（模块加载期就建好，不依赖任何输入）
local FALLBACK = {
    "这段在讲什么？",
    "它和前后文有什么联系？",
    "作者这样写有什么讲究？",
    "这段最值得留意的是什么？",
}

local KNOWN_KINDS = { explain = true, summary = true, chat = true, light = true }

-- ---------- 内部小工具 ----------

-- 净化输入：脏字节 → 折叠空白 → 去首尾空白。返回值一定是合法 UTF-8 字符串。
local function cleanText(s)
    if type(s) ~= "string" then return "" end
    local ok, v = pcall(function()
        return Util.trim(Util.collapseWhitespace(Util.sanitizeForDisplay(Util.sanitizeUtf8(s))))
    end)
    if ok and type(v) == "string" then return v end
    return ""
end

-- 多字节安全：逐个 plain find（绝不构造多字节字符类）
local function containsAny(s, list)
    if s == "" then return false end
    for _i, w in ipairs(list) do
        if s:find(w, 1, true) then return true end
    end
    return false
end

-- 剥掉末尾标点（最多剥 4 个，避免整句被吃光）
local function stripTail(s, list)
    local guard = 0
    while guard < 4 do
        local changed = false
        for _i, p in ipairs(list) do
            if #s >= #p and s:sub(-#p) == p then
                s = s:sub(1, #s - #p)
                changed = true
                break
            end
        end
        if not changed then break end
        guard = guard + 1
    end
    return s
end

--[[--
归一化 kind：只认四种，其余（nil / "" / 拼错 / 数字 / 表）一律回落 chat。
@param kind any
@return string 一定是 KNOWN_KINDS 里的一个
--]]
function Suggest.normalizeKind(kind)
    if type(kind) == "string" and KNOWN_KINDS[kind] then return kind end
    return Suggest.DEFAULT_KIND
end

--[[--
归一化 max：非数字、NaN、<1、无穷大都回落 DEFAULT_MAX；超过上限压到 MAX_LIMIT。
@param n any
@return number 一定在 [1, MAX_LIMIT]
--]]
function Suggest.normalizeMax(n)
    if type(n) ~= "number" then return Suggest.DEFAULT_MAX end
    if n ~= n then return Suggest.DEFAULT_MAX end           -- NaN
    if n == math.huge or n == -math.huge then return Suggest.DEFAULT_MAX end
    local v = math.floor(n)
    if v < 1 then return Suggest.DEFAULT_MAX end
    if v > Suggest.MAX_LIMIT then return Suggest.MAX_LIMIT end
    return v
end

-- 单条问题的收口：净化 → 去空白 → 按字符边界截到 MAX_LEN
local function fit(s)
    if type(s) ~= "string" then return "" end
    local q = cleanText(s)
    if q == "" then return "" end
    if Util.utf8len(q) > Suggest.MAX_LEN then
        q = Util.utf8sub(q, Suggest.MAX_LEN)
    end
    return q
end

-- ask 的值可能是字符串，也可能是 function(f)
local function resolveAsk(v, f)
    if type(v) == "function" then
        local ok, s = pcall(v, f)
        if ok and type(s) == "string" then return s end
        return nil
    end
    if type(v) == "string" then return v end
    return nil
end

--[[--
生成建议问题（真正干活的那一层，被 list() 用 pcall 包住）。
@param opts table
@return string[] 至少 1 条，最多 max 条
--]]
local function build(opts)
    local o = type(opts) == "table" and opts or {}

    local kind = Suggest.normalizeKind(o.kind)
    local limit = Suggest.normalizeMax(o.max)

    local selected = cleanText(o.selected)
    local context = cleanText(o.context)

    local len = Util.utf8len(selected)
    local term = ""
    if not Util.isEmpty(selected) then
        term = Util.utf8sub(stripTail(selected, TAIL_PUNCT), Suggest.TERM_MAX)
    end

    local f = {
        selected = selected,
        sel_len = len,
        term = term,
        is_short = (len > 0 and len <= Suggest.SHORT_MAX),
        is_long = (len >= Suggest.LONG_MIN),
        has_dialogue = containsAny(selected, DIALOG_MARKS),
        has_mood = containsAny(selected, MOOD_MARKS),
        has_break = containsAny(selected, BREAK_MARKS),
        has_person = containsAny(selected, PERSON_WORDS),
        has_context = (context ~= ""),
    }

    local out = {}
    local seen = {}

    -- 收口：去空、去重、按 MAX_LEN 截断、不超过 limit
    local function push(q)
        if #out >= limit then return end
        q = fit(q)
        if q == "" then return end
        if seen[q] then return end
        seen[q] = true
        out[#out + 1] = q
    end

    for _i, rule in ipairs(RULES) do
        local ok_m, hit = pcall(rule.match, f)
        if ok_m and hit then
            local q = resolveAsk(rule.ask[kind], f)
            if q == nil then q = resolveAsk(rule.ask[Suggest.DEFAULT_KIND], f) end
            push(q)
        end
    end

    local pool = GENERIC[kind] or GENERIC[Suggest.DEFAULT_KIND]
    for _i, g in ipairs(pool) do
        push(g)
    end

    -- 兜底池也为空的极端情况（不该发生，但绝不返回空数组）
    if #out == 0 then
        for _i, g in ipairs(FALLBACK) do
            push(g)
        end
    end

    return out
end

--[[--
「你可能想问」建议问题列表。

纯函数 + 零副作用 + 零 API 调用，可以放心在 UI 每次弹窗时同步调用。

@param opts table|nil  { kind=, selected=, context=, max= }，字段都可缺省
@return string[] 建议问题数组；绝不返回 nil，绝不抛异常，条数 ∈ [1, max]
--]]
function Suggest.list(opts)
    local ok, res = pcall(build, opts)
    if ok and type(res) == "table" and #res > 0 then
        return res
    end

    -- pcall 失败（或返回空）时的静态兜底：不使用任何输入，不可能再出错
    local out = {}
    local limit = Suggest.DEFAULT_MAX
    if type(opts) == "table" then limit = Suggest.normalizeMax(opts.max) end
    for _i, g in ipairs(FALLBACK) do
        if #out >= limit then break end
        out[#out + 1] = g
    end
    if #out == 0 then out[1] = FALLBACK[1] end
    return out
end

-- ---------- AI 引导式提问（kind = ideas）的返回解析 ----------
--[[--
为什么还要一个 parser：
  AI 出题（ui/suggestpicker.lua 的 showAi）拿到的是一段自由文本，
  直接把整段当一个按钮用显然不行，必须切成一行一条。
  但它是**模型的输出**，不是我们自己的结构化数据：
  说好不要编号它可能还是编了，说好不要 Markdown 它可能还是带了 "- "，
  偶尔还会先来一句"好的，以下是我的建议："，或者干脆 4 条挤在一行不换行。
  所以这里全部按"尽力解析"处理，解析不出来就返回空数组让上层退回本地列表，
  绝不把半句话或开场白塞进按钮里（那比没有建议更糟）。

  三条铁律与 list 一致：
   1. 永不返回 nil、永不抛异常（最外层 pcall）；
   2. 每条 ≤ MAX_LEN 个**字符**，且以问号结尾（不带问号的补一个）；
   3. 绝不用裸 string.sub 切中文（用 Util.utf8sub）。
--]]

-- 短于这个字数不可能是个完整问句（"好的"之类）
Suggest.MIN_IDEA_LEN = 4

-- 行首的项目符号与装饰线（多字节，逐个 plain 前缀比较，绝不进 Lua 字符类：
-- [—] 这种写法在 Lua 里是"三个字节的并集"，会把含这些字节的汉字切坏）
local LEAD_SYMBOLS = {
    "•", "·", "・", "-", "*", ">", "—", "–", "⁃", "■", "□", "●", "○", "▪", "◦",
}
--[[--
包裹引号（首尾成对时才剥）。

为什么不能"看到行首有引号就剥"：中文引号经常只裹住中间的一个词
（「仔细」二字是在提醒谁？），剥掉开头的 「 会留下一个孤儿 」，
按钮上就是「仔细」二字… 这种怪东西。所以只有首尾确实成对时才剥。
--]]
local QUOTE_PAIRS = {
    { "“", "”" }, { "‘", "’" }, { "「", "」" }, { "『", "』" }, { "《", "》" },
    { "\"", "\"" }, { "'", "'" },
}
-- 编号与正文之间的分隔符（plain 前缀比较，多字节安全）
local NUM_SEPARATORS = { ".", "、", ")", ":", "：", "]", "】", "》" }
-- 括号型编号：(1) （1） [1] 【1】
local BRACKET_PAIRS = {
    { "(", ")" }, { "（", "）" }, { "[", "]" }, { "【", "】" },
}
-- 问号结尾（全角/半角）
local END_MARKS = { "？", "?" }
-- 以冒号结尾的一定是开场白（"以下是我的建议："），不是问题
local LEADIN_TAILS = { "：", ":" }

--[[--
净化 AI 返回的整段文本，**保留换行**：行结构就是问题条数。

这里不能用 cleanText：它内部走 Util.sanitizeForDisplay，而 sanitizeForDisplay
会 gsub("%c", "") 把 \n 一起吃掉，整段塌成一行 → 只能解析出 1 条问题。
--]]
local function cleanBlock(s)
    if type(s) ~= "string" then return "" end
    local ok, v = pcall(function()
        -- sanitizeUtf8 只丢非法码点，保留 \n 与 \t（\r 会被当成控制字符丢掉，正好）
        local t = Util.sanitizeUtf8(s)
        t = t:gsub("\239\187\191", "")  -- BOM
        t = t:gsub("\226\128\139", "")  -- 零宽空格 U+200B
        t = t:gsub("\194\173", "")      -- 软连字符 U+00AD
        t = t:gsub("\194\160", " ")     -- 不换行空格 → 普通空格
        return t
    end)
    if ok and type(v) == "string" then return v end
    return ""
end

-- plain 查找（多字节安全）
local function hasAny(s, list)
    if type(s) ~= "string" or s == "" then return false end
    for _i, m in ipairs(list) do
        if s:find(m, 1, true) then return true end
    end
    return false
end

-- plain 后缀判断
local function endsWithAny(s, list)
    if type(s) ~= "string" or s == "" then return false end
    for _i, m in ipairs(list) do
        if #s >= #m and s:sub(-#m) == m then return true end
    end
    return false
end

--[[--
剥掉行首的编号 / 项目符号 / 引号。

难点是"别误伤正文"：中文里数字开头很常见（"2024年他回到故乡"），
所以只有数字后面确实跟着分隔符时才剥，否则原样返回。
--]]
local function stripLead(s)
    local guard = 0
    while guard < 8 do
        local before = s
        s = Util.trim(s)

        local stripped = false

        -- ① 括号型编号：(1) （1） [1] 【1】
        for _i, p in ipairs(BRACKET_PAIRS) do
            local op, cl = p[1], p[2]
            if s:sub(1, #op) == op then
                local rest = s:sub(#op + 1)
                local digits = rest:match("^(%d+)")
                if digits and rest:sub(#digits + 1, #digits + #cl) == cl then
                    s = Util.trim(rest:sub(#digits + #cl + 1))
                    stripped = true
                    break
                end
            end
        end

        -- ② 裸数字序号：1. / 1、/ 1) / 1：
        if not stripped then
            local digits = s:match("^(%d+)")
            if digits then
                local rest = s:sub(#digits + 1)
                for _i, sep in ipairs(NUM_SEPARATORS) do
                    if rest:sub(1, #sep) == sep then
                        s = Util.trim(rest:sub(#sep + 1))
                        stripped = true
                        break
                    end
                end
                -- "1 为什么…"：数字后直接跟空格也算序号
                if not stripped and rest:sub(1, 1) == " " then
                    s = Util.trim(rest)
                    stripped = true
                end
                -- 数字后什么都没有（"2024年…"）→ 是正文，到此为止
            end
        end

        -- ③ 项目符号（引号不在这里剥：见 QUOTE_PAIRS 的说明）
        if not stripped then
            for _i, m in ipairs(LEAD_SYMBOLS) do
                if s:sub(1, #m) == m then
                    s = Util.trim(s:sub(#m + 1))
                    stripped = true
                    break
                end
            end
        end

        if not stripped or s == before then break end
        guard = guard + 1
    end
    return Util.trim(s)
end

-- 剥掉首尾成对的包裹引号（最多 4 层）
local function stripWrapQuotes(s)
    local guard = 0
    while guard < 4 do
        local changed = false
        for _i, p in ipairs(QUOTE_PAIRS) do
            local op, cl = p[1], p[2]
            if #s >= (#op + #cl) and s:sub(1, #op) == op and s:sub(-#cl) == cl then
                s = Util.trim(s:sub(#op + 1, #s - #cl))
                changed = true
                break
            end
        end
        if not changed then break end
        guard = guard + 1
    end
    return s
end

--[[--
单条问题的收口：净化 → 按字符边界截到 MAX_LEN → 保证以问号结尾。

为什么要补问号：AI 偶尔漏写，变成陈述句的"问题"放在按钮上很怪。

为什么补问号**绝不许删字**（真机实测翻过车）：
MAX_LEN 是"内容"的上限，句尾问号是标点、不计入它。
早期版本为了给问号腾位置，会削掉最后一个字——用户实测「…偏偏在这一天」
被削成「…偏偏在这一？」。代价很具体：这条残掉的问句做成按钮，
用户点下去就是**花一次额度去问一句自己没问完的话**。
宁可让它变成 21 个字符（20 字 + 一个问号），也绝不让问句少一个字。
--]]
local function fitIdea(s)
    local q = fit(s)
    if q == "" then return "" end
    if not hasAny(q, END_MARKS) then
        q = q .. "？"
    end
    return q
end

--[[--
按问号把整段切成若干片段（用于"AI 没换行"的兜底）。

不能写成 flat:gmatch("[^？?]+")：Lua 的字符类是**字节**集合，
"？" 的三个字节里有两个是常见的 UTF-8 续字节，这么写会把含这些字节的
汉字（比如"原"= E5 8E 9F，末字节就是 9F）从中间劈开，直接产出乱码。
所以用 plain find 逐个定位。
--]]
local function splitQuestions(block)
    local out = {}
    local s = block or ""
    local guard = 0
    while guard < 40 do
        guard = guard + 1
        local p1 = s:find("？", 1, true)
        local p2 = s:find("?", 1, true)
        local pos, mlen
        if p1 and (not p2 or p1 <= p2) then
            pos, mlen = p1, 3
        elseif p2 then
            pos, mlen = p2, 1
        else
            break
        end
        out[#out + 1] = s:sub(1, pos - 1)
        s = s:sub(pos + mlen)
    end
    --[[--
    最后一个问号之后的"余料"**不再收进来**（早期版本是收的，改掉了）。

    正常输出里每条都以问号结尾，不该有余料；有余料基本只有两种来源：
      1. 开场白的碎屑（"好的：为什么…？" 里问号后面的那半句）；
      2. AI 输出被 max_tokens 截断留下的残句。
    第 2 种尤其危险：它是**半句话**，做成按钮点了就是花一次额度问一句没问完的话，
    和 fitIdea 那条"补问号不许删字"是同一类错误。
    宁可少收一条，也不收半句——少一条最多是这次额度白花，
    收半句则是让用户自己花钱去问一句他自己都读不通的话。
    --]]
    return out
end

--[[--
把一段原始文本收成一条合规问题并 push 进去（不合规就静默丢弃）。

超长的一律**丢弃**而不是截断：20 字对"一个问题"已经很宽裕，超了基本说明
这不是一行问题而是整段话（AI 没按格式输出）。硬切成 20 字会得到半句话，
做成按钮比不给更糟——那半句话被点中就是又一次真实请求。
宁可让上层退回本地建议。

@return bool 是否收下
--]]
local function pushIdea(out, seen, raw, limit)
    if #out >= limit then return false end
    local text = stripLead(Util.collapseWhitespace(Util.trim(raw or "")))
    if text == "" then return false end
    -- "以下是我的建议：" 这类开场白不是问题
    if endsWithAny(text, LEADIN_TAILS) then return false end
    text = stripWrapQuotes(Util.trim(text))
    if text == "" then return false end
    if Util.utf8len(text) > Suggest.MAX_LEN then return false end
    local q = fitIdea(text)
    if q == "" then return false end
    if Util.utf8len(q) < Suggest.MIN_IDEA_LEN then return false end
    if seen[q] then return false end
    seen[q] = true
    out[#out + 1] = q
    return true
end

--[[--
解析 AI 出题（kind = ideas）的返回文本，切成可直接上按钮的问题列表。

输入可以是任何东西：nil、空串、数字、表、含非法 UTF-8 的字节流、
带编号的一坨、完全不换行的一整段。任何情况都不抛异常、不返回 nil。

@param text any   AI 返回的原始文本（通常是 DeepSeek 的 content）
@param max  any   最多要几条（缺省/非法 → DEFAULT_MAX，上限 MAX_LIMIT）
@param truncated any 输出是否被 max_tokens 截断（上游 finish_reason == "length"）。
                 **可选参数**：不传（nil / false）时行为与此前完全一致，
                 旧调用方和旧断言不受影响。
@return string[]  合规问题数组；解析不出任何一条时返回**空数组**（不是 nil），
                  由调用方决定退回本地列表还是提示用户
--]]
function Suggest.parseList(text, max, truncated)
    local limit = Suggest.normalizeMax(max)
    local out, seen = {}, {}
    local ok = pcall(function()
        local block = cleanBlock(text)
        if block == "" then return end

        local lines = {}
        for line in (block .. "\n"):gmatch("([^\n]*)\n") do
            lines[#lines + 1] = line
        end

        --[[--
        被截断时最后一行几乎必然是半句话 —— 用户点它 = 花一次额度问一句没问完的话。
        判据只有一条：**这行到底有没有写问号**。
          · 没写问号 → 是残句，丢掉；
          · 写了问号 → 它本身是一条完整问句，照收（后面没输出完不影响这一条）。

        口径（已定稿）：**宁可一条都不剩，也不留残句**。
        只有一行、且这行没写问号时，丢掉它就一条不剩 → 解析出 0 条 →
        上层退回本地建议页：那儿有 4 条零成本、文法完整的通用建议，
        外加一个真会重发的「让小望来问」（截断那次特意不进缓存，再点是真请求、
        真扣额度，按钮写着「用一次额度」并不骗人）。用户拿不到定制问题，
        但既没被晾住、也没被喂半句话。
        反过来硬留下它，用户看到的就是一个明显的半句，点下去等于花钱问一句
        自己读不通的话 —— 那才是要避免的结局。

        所以这里是"留一条残句"和"给 4 条能用的建议 + 一次真重试"之间选，
        不是"留一条"和"什么都不给"之间选 —— 后一种说法漏掉了回落地那一份，
        看着像两难，其实不是。

        为什么必须靠这个标志而不是文本规则：「漏写问号的完整句子」和「被截断的残句」
        文本上一模一样，本地分不开（QA 实测）。
        --]]
        if truncated and #lines > 0 then
            local last = lines[#lines]
            if not (last:find("？", 1, true) or last:find("?", 1, true)) then
                table.remove(lines)
            end
        end

        -- 逐行切；每行再按问号切一次（AI 最常见的两种跑偏：
        -- 加编号 / 4 条挤在一行不换行，都能在这两步里救回来）。
        -- 一行里没有问号时整行当一条（模型漏写句尾问号很常见，补就是了）。
        for _i, line in ipairs(lines) do
            local frags = splitQuestions(line)
            if #frags == 0 then frags = { line } end
            for _j, frag in ipairs(frags) do
                pushIdea(out, seen, frag, limit)
                if #out >= limit then break end
            end
            if #out >= limit then break end
        end
    end)
    if not ok or #out == 0 then return {} end
    return out
end

return Suggest
