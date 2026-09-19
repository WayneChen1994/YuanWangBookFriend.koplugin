--[[--
全部 Prompt 模板集中管理（PRD §5.2）。

设计原则：
1. 输出长度硬约束（释义 ≤200 字、摘要 ≤300 字），直接压 token 成本；
2. 所有模板都带"只基于给定上下文"的约束，为 M3 防剧透留出一致入口；
3. 输出纯文本，不要求 Markdown（墨水屏渲染成本高）。
--]]--

local Context = require("ywbf/context")
local Spoiler = require("ywbf/spoiler")
local Util = require("ywbf/util")

local Prompts = {}

--[[--
AI 的角色名。
UI 上的「【答】」、菜单里的说明文案都从这里取，避免改名时各处漏改。
注意：BASE_SYSTEM 里仍然保留插件名「远望书友」（角色出自该插件），
单元测试里那条"system 含角色设定"的断言断言的就是这个词，不要删。
--]]
Prompts.PERSONA_NAME = "小望"

Prompts.BASE_SYSTEM = [[你是“小望”，一个嵌入在墨水屏阅读器中的 AI 阅读助手（远望书友插件里的那个搭子）。
行为准则：
· 只基于用户提供的上下文回答，不要臆造书中没有的内容
· 用简体中文回答，纯文本，不要 Markdown 语法、不要标题符号
· 墨水屏阅读，请尽量简短，能一句说清就不要写一段
· 用户会用“小望”称呼你，你也始终以“小望”这个身份说话，不要自称“助手”“AI”“模型”
· 就算要纠正用户、指出他说错了，也保持这个身份和口吻]]

--[[--
各功能的输出长度约束（字，不是 token）。

ideas 这一条是**总输出**的上限（4 条 × ≤20 字 = ≤80 字，留足冗余），
配合 Config 的 max_tokens_ideas = 300 一起把成本封死：
模板里写死"4 条、每条 ≤20 字"，模型就算想啰嗦也没有空间。
--]]
Prompts.LIMIT = {
    explain = 200,
    summary = 300,
    concept = 300,
    chat = 600,
    ideas = 300,
}

--[[--
可选回复风格（用户可在「远望书友 → AI 回复风格」里切换）。

每条 = { key=配置值, text=菜单显示名, help=给用户看的人话说明（菜单 help_text），
instruction=注入 system 的语气指令 }

写指令时的两条原则：
1. 真的能改变语气 —— 只写"要活泼一点"这种形容词没用，必须落到可执行的说话方式
   （先说什么、允许什么、禁止什么）；
2. 每条都在最后一环自己兜住边界（不许人身攻击 / 联想必须标注 / 该给的答案要给），
   因为激进风格天然有越界的倾向，光靠 BASE_SYSTEM 压不住。
--]]
Prompts.STYLES = {
    {
        key = "professional",
        text = "专业严谨",
        help = "像查证过的注释：结论—依据—边界，用词准确度优先，没把握宁可不说。",
        instruction = [[· 语气克制客观，走「结论 → 依据 → 适用边界」的顺序
· 用词的准确度优先于通顺流畅，能用术语就用术语，不要为了好懂牺牲精确
· 不确定就说「原文没有明说」，不要用「大概是」「应该是」糊过去]],
    },
    {
        key = "friendly",
        text = "亲和友善",
        help = "像朋友在聊刚读到的这一段，先接住感受再讲内容，不端着也不客服腔。",
        instruction = [[· 语气像身边的朋友在聊刚读到的这一段，先接住用户的感受，再讲内容
· 允许口语词和短句（「其实」「你注意这里」），但不许客套寒暄，不要用「亲」「哦～」这类客服腔
· 遇到难点先说一句「这段确实绕」，再拆开讲，别让用户觉得自己问了个蠢问题]],
    },
    {
        key = "blunt",
        text = "直言不讳",
        help = "有话直说，先给判断不铺垫，也敢说这段写得不好；对事不对人。",
        instruction = [[· 有话直说，第一句就给结论和最关键的判断，不铺垫、不绕弯、不留缓冲句
· 敢于直接指出原文的逻辑漏洞、人物行为的不合理处，包括明确说「这段写得不好」
· 直接不等于粗鲁：批评只针对文本和观点，绝不针对用户]],
    },
    {
        key = "imaginative",
        text = "天马行空",
        help = "允许联想、类比和跨作品参照，但脱离原文的部分必须当场标明是联想。",
        instruction = [[· 允许联想、类比和跨作品参照，用它帮用户建立直观感受
· 凡是脱离原文的联想，必须当场标注是联想不是原文（例如先说「这是我的联想：」），不许和原文混着写
· 联想完一定拉回文本本身，说清楚这段原文实际写了什么]],
    },
    {
        key = "pragmatic",
        text = "高效务实",
        help = "一句话结论 + 一条理由就完事，用户没问的背景和引申一概不给。",
        instruction = [[· 第一句给结论，第二句给一条最关键的理由，其余一概省略
· 能用列表就不用段落，能用一个词就不用一句话
· 用户没问的背景、引申、评价都不给；他想要更多会自己追问]],
    },
    {
        key = "snarky",
        text = "毒舌吐槽",
        help = "犀利、反讽、玩笑都允许，笑点和刀子对准情节与写法，不针对用户。",
        instruction = [[· 允许犀利吐槽、反讽和玩笑，语言可以刻薄，重点是把话说透
· 吐槽对象只能是情节、写法、人物行为或观念，不得对用户做人身攻击，也不得羞辱真实作者
· 毒舌归毒舌，事实和边界不能破：该给的信息要给准，读不到的内容照样不能说]],
    },
    {
        key = "socratic",
        text = "启发引导",
        help = "先反问再把线索递过去，不直接摊答案；用户追着要答案时会痛快给。",
        instruction = [[· 先反问一个能把用户推向答案的问题，再给一条线索，不要直接把答案摊开
· 线索要锚在文本细节上（「注意他回答时刻意没提哪件事」），不要空泛地反问「你觉得呢」
· 用户明确说「直接说吧」或连着两轮没接上时，立刻给出完整答案，不许继续追问]],
    },
}

-- 默认风格：配置缺失、值非法、值类型不对时一律落到这里
Prompts.STYLE_DEFAULT = "professional"

-- key -> style 表的索引，build 时构造一次避免每次遍历
local STYLE_BY_KEY = {}
for _i, s in ipairs(Prompts.STYLES) do
    STYLE_BY_KEY[s.key] = s
end

--[[--
把任意输入归一成合法 style key。
@param key any
@return string 一定是 STYLES 里存在的 key（永不返回 nil）
--]]
function Prompts.normalizeStyleKey(key)
    if type(key) == "string" and STYLE_BY_KEY[key] then return key end
    return Prompts.STYLE_DEFAULT
end

--[[--
取风格的 system 指令。
@param key string|nil 非法或缺失时回落到 STYLE_DEFAULT
@return string 永不返回 nil；最坏情况也返回默认风格的指令
--]]
function Prompts.styleInstruction(key)
    local s = STYLE_BY_KEY[Prompts.normalizeStyleKey(key)]
    if type(s) ~= "table" or type(s.instruction) ~= "string" or s.instruction == "" then
        s = STYLE_BY_KEY[Prompts.STYLE_DEFAULT]
    end
    -- 连默认风格自己的 instruction 都缺失时也必须返回字符串：
    -- 回落到这里等于回落到自己，再取不到就会把 nil 交给 styleBlock 去拼 system，
    -- 结果是整次提问崩溃（QA 的 M3 变异实测：脚本连 RESULTS 都没跑出来）。
    -- "没有风格指令"只是语气平淡一点，绝不该变成一次请求失败。
    if type(s) ~= "table" or type(s.instruction) ~= "string" then return "" end
    return s.instruction
end

--[[--
取风格的菜单显示名（永不返回 nil）。
@param key string|nil
@return string
--]]
function Prompts.styleText(key)
    local s = STYLE_BY_KEY[Prompts.normalizeStyleKey(key)]
    if type(s) ~= "table" or type(s.text) ~= "string" or s.text == "" then
        s = STYLE_BY_KEY[Prompts.STYLE_DEFAULT]
    end
    -- 同 styleInstruction：默认风格自身缺失时也要返回字符串，
    -- 否则 styleBlock 拼 "回复风格：" .. nil 会崩
    if type(s) ~= "table" or type(s.text) ~= "string" then return "" end
    return s.text
end

--[[--
取风格给用户的说明（菜单 help_text 用，永不返回 nil）。
@param key string|nil
@return string
--]]
function Prompts.styleHelp(key)
    local s = STYLE_BY_KEY[Prompts.normalizeStyleKey(key)]
    if type(s) ~= "table" or type(s.help) ~= "string" or s.help == "" then
        s = STYLE_BY_KEY[Prompts.STYLE_DEFAULT]
    end
    if type(s) ~= "table" or type(s.help) ~= "string" then return "" end
    return s.help
end

--[[--
拼一段完整的"风格块"，供 build 追加到 system 末尾。

抬头为什么必须写：这批指令排在 BASE_SYSTEM 和防剧透说明**之后**生效，
模型对越靠后的指令越敏感；没有这句抬头，"毒舌一点""可以联想"这类要求
会被当成对前面限制的放宽，把"只基于上下文、不要臆造"和防剧透说明稀释掉。

抬头里刻意不出现"防剧透"三个字：未开启防剧透时 system 里不该凭空多出这个词
（既有单测断言了"未传 note 时 system 不含防剧透"），
而"上面已经给出的任何约束"讲的本来就是同一回事。
@param key string|nil
@return string 永不返回 nil
--]]
Prompts.STYLE_HEADER = [[%s
按这个风格说话；它只改变表达方式，不改变上面已经给出的任何约束。
两者冲突时一律以上面的约束为准：]]

function Prompts.styleBlock(key)
    local style_key = Prompts.normalizeStyleKey(key)
    local text = Prompts.styleText(style_key)
    local instruction = Prompts.styleInstruction(style_key)
    -- 指令缺失时整块都不拼：只留"回复风格：某某"这个抬头、下面没有内容，
    -- 等于给模型一句空话，还不如不写（QA 的 KNOWN 探针钉住过这个现象）
    if instruction == "" then return "" end
    return string.format(Prompts.STYLE_HEADER, "回复风格：" .. text) .. "\n" .. instruction
end

local TEMPLATES = {
    explain = [[请结合上下文，解释下面“选中内容”的含义。

要求：
· 解释它在**当前语境**中的意思，而不是给词典定义
· 如果是代词或指代，说明它指代的是什么
· 控制在 %d 字以内，直接给结论，不要复述原文%s]],
    summary = [[请概括下面这段文字。

要求：
· 抓住主要信息，忽略细节
· 控制在 %d 字以内，一段说完%s]],
    concept = [[请解释下面这个术语/典故/事件。

要求：
· 先给一句定义，再补充与当前书籍相关的背景
· 控制在 %d 字以内%s]],
    --[[--
    引导式提问（kind = ideas）：替"提不出问题"的读者问出几个问题。

    三条硬性要求，缺一条这个功能的价值就没了：
      1. 必须锚在这段文本里**已经出现过**的东西上 —— 问"这个人为何在此时提这事"
         才有用，问"这段讲了什么"是放之四海皆准的空话，本地启发式已经会给；
      2. 一行一条、不要任何编号和 Markdown 符号 —— 输出要能被 Suggest.parseList
         直接切成按钮，多一个"1."就要靠正则去猜；
      3. 不得涉及尚未读到的内容 —— 这是防剧透的底线，和别处一样靠
         Prompts.spoilerNote / spoilerHint 在 system 与 user 两侧同时声明，
         这里再钉一遍是因为"帮我提问"天然有往后剧透的倾向（问"后来呢"最省事）。

    模板里写死的「4 条」「20 字」和 ywbf/suggest.lua 的 Suggest.DEFAULT_MAX /
    MAX_LEN 是同一套口径（那边按 4 条、每条 ≤20 字来切按钮），改一处要一起改。
    --]]
    ideas = [[请根据下面这段文字，替读到这里的读者提出 4 个他很可能想问的问题。

要求：
· 一行一个问句，一共 4 条。不要编号、不要引号、不要用任何 Markdown 符号
  （"-"、"*"、"#"、数字序号都不要），每行就是一个完整的问句，以问号结尾
· 每条不超过 20 个字，必须自己能独立成立，不要出现"如上""这一段"这类指代
· 必须紧扣这段文字里**已经出现过**的人物、情节、动作或细节：
  要问"他为什么偏偏在这个时点说这句话"这种只有读过这段才问得出口的问题，
  不要问"这段讲了什么""作者为什么这样写"这种任何一段都能套的空话
· 只问这段文字本身能支撑的问题；不得涉及尚未读到的内容，
  不得暗示后面的走向，也不要用"后来""结果""最终"这类往后看的字眼
· 全部输出控制在 %d 字以内；只输出这 4 行问题，
  不要任何开场白、说明、总结和结尾客套%s]],
}

--[[--
防剧透 user 侧提示模板（双保险：system 一条 + user 一条）。
system 侧文案由 Spoiler.buildNote 生成，这里只管 user 侧那句短提醒。
--]]
Prompts.SPOILER_HINT_TEMPLATE = "\n\n（提醒：我只读到%s，请不要引用这之后的内容。）"

--[[--
生成 user 侧的防剧透提醒（与 system 侧的 spoiler_note 构成双保险）。
@param prog 进度表（Spoiler.readProgress 的产物）
@return string 空串表示不注入
--]]
function Prompts.spoilerHint(prog)
    if type(prog) ~= "table" or prog.enabled == false then return "" end
    local where = nil
    if type(prog.work_index) == "number" and prog.work_index >= 1
        and type(prog.work_total) == "number" then
        -- 合集：声明"第几部"，其余各部前后都算未读
        where = string.format("合集第 %d / %d 部", prog.work_index, prog.work_total)
        if type(prog.work_title) == "string" and prog.work_title ~= "" then
            where = where .. "（" .. prog.work_title .. "）"
        end
    elseif prog.granularity == Spoiler.GRANULARITY_PERCENT and type(prog.percent) == "number" then
        where = string.format("全书 %.0f%%", prog.percent)
    elseif type(prog.chapter_index) == "number" and prog.chapter_index >= 1
        and type(prog.chapter_total) == "number" then
        -- chapter_index == 0 = 还没进第 1 章，此时改报百分比，不说"第 0 章"
        where = string.format("第 %d / %d 章", prog.chapter_index, prog.chapter_total)
    elseif type(prog.percent) == "number" then
        where = string.format("全书 %.0f%%", prog.percent)
    end
    if not where then return "" end
    return string.format(Prompts.SPOILER_HINT_TEMPLATE, where)
end

--[[--
生成 system 侧的防剧透说明（文案模板在 Spoiler.buildNote 里，此处只做参数装配）。
@param prog 进度表
@param cfg 可选 { enabled=bool, granularity=string }
@return string 空串表示不注入
--]]
function Prompts.spoilerNote(prog, cfg)
    if type(prog) ~= "table" then return "" end
    local merged = (type(cfg) == "table") and Spoiler.withConfig(prog, cfg) or prog
    if merged.enabled == false then return "" end
    return Spoiler.buildNote({
        enabled = true,
        granularity = merged.granularity,
        book = merged.book,
        chapter = merged.chapter,
        chapter_index = merged.chapter_index,
        chapter_total = merged.chapter_total,
        percent = merged.percent,
        work_index = merged.work_index,
        work_total = merged.work_total,
        work_title = merged.work_title,
    })
end

--[[--
构建消息数组。
@param kind explain | summary | concept | chat | light | ideas
@param params { context=string(已组装的上下文), selected=string, question=string,
                spoiler_note=string, spoiler_hint=string, history=table,
                style=string(可选，默认 professional) }
@return messages
--]]
function Prompts.build(kind, params)
    params = params or {}
    local messages = {}
    local system = Prompts.BASE_SYSTEM
    if params.spoiler_note and params.spoiler_note ~= "" then
        system = system .. "\n" .. params.spoiler_note
    end
    -- 风格对所有 kind 生效（释义/摘要/词条/深聊/轻问），不传就用默认风格：
    -- 风格写丢了只会变成"稍微正式一点的默认回答"，而不会漏管。
    -- 位置固定放在防剧透说明之后：styleBlock 自带"冲突以上面为准"的兜底，
    -- 让后追加的语气指令压不过前面的硬性约束。
    local style_block = Prompts.styleBlock(params.style)
    if style_block ~= "" then
        system = system .. "\n" .. style_block
    end
    if params.system_extra and params.system_extra ~= "" then
        system = system .. "\n" .. params.system_extra
    end
    messages[#messages + 1] = { role = "system", content = system }

    -- 多轮历史（仅 chat/light）
    if (kind == "chat" or kind == "light") and type(params.history) == "table" then
        for _, h in ipairs(params.history) do
            if h and h.role and h.content then
                messages[#messages + 1] = { role = h.role, content = h.content }
            end
        end
    end

    local user
    -- ideas 与释义/摘要/词条同一组：它同样要拼 context、同样走双保险防剧透声明。
    -- 这是刻意的——AI 出题是最容易往后剧透的动作（问"后来呢"最省事），
    -- 让它走同一条管道，等于免费拿到全部四道防线。
    --
    -- 一个反直觉的点（QA 变异实测）：把 ideas 从这里摘掉**并不会**让四道防线失效
    -- ——system 侧的 spoilerNote 由调用方传进来、user 侧的 hint 在 build 末尾统一追加、
    -- 物理截断发生在 askSync 里，三者都不看 kind。真正会丢的是**输出契约**：
    -- "一行一条、一共 4 条、每条 ≤20 字、不要开场白"。丢了以后 AI 很可能回一段散文，
    -- parseList 收不出几条，等于白花一次额度。动这一行之前先想清楚这个差别。
    if kind == "explain" or kind == "summary" or kind == "concept" or kind == "ideas" then
        local limit = Prompts.LIMIT[kind] or 300
        local extra = params.question and ("\n· 用户追问：" .. params.question) or ""
        local tmpl = TEMPLATES[kind] or TEMPLATES.explain
        user = string.format(tmpl, limit, extra)
        if not Util.isEmpty(params.context) then
            user = user .. "\n\n" .. params.context
        end
    elseif kind == "light" or kind == "chat" then
        user = params.question or ""
        if not Util.isEmpty(params.context) then
            user = "（相关上下文）\n" .. params.context .. "\n\n（我的问题）\n" .. user
        end
    else
        user = params.question or params.context or ""
    end

    -- 双保险：system 里那条之外，user 消息尾巴再钉一句进度提醒
    if params.spoiler_hint and params.spoiler_hint ~= "" then
        user = user .. params.spoiler_hint
    end

    messages[#messages + 1] = { role = "user", content = user }
    return messages
end

-- 便捷封装：从窗口结果直接构造上下文串
function Prompts.contextFromWindow(win)
    if type(win) ~= "table" then return "" end
    return Context.buildPayload(win.before, win.selected, win.after)
end

return Prompts
