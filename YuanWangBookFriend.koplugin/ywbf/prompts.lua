--[[--
全部 Prompt 模板集中管理（PRD §5.2）。

设计原则：
1. 输出长度硬约束（释义 ≤200 字、摘要 ≤300 字），直接压 token 成本；
2. 所有模板都带「只基于给定上下文」的约束，为 M3 防剧透留出一致入口；
3. 输出纯文本，不要求 Markdown（墨水屏渲染成本高）。
--]]--

local Context = require("ywbf/context")
local Spoiler = require("ywbf/spoiler")
local Util = require("ywbf/util")
local _ = require("gettext")

local Prompts = {}

--[[--
引文块的标题（结果卡片 / 深聊对话页 / 收藏详情页 / 导出 Markdown 四处共用）。

为什么改成「引文」：望仔的反馈是「用户引用的不一定是一整段」——选中半句话、
选三段、选一行对话，都叫「旧叫法」就不准了；「引文」更短也更准。
（旧叫法已全库清除，有一条断言盯着这四个文件不许再冒出来。）

为什么必须是这里的常量而不是各 UI 文件各写一份：这四处原本就是**同一句话**
（有一条断言专门盯着「标题与收藏详情页同口径」），写死在四个文件里改一次漏三处，
用户就会在同一本书里看到两种叫法。
--]]
Prompts.QUOTE_LABEL = _("【引文】")

--[[--
AI 的角色名。
UI 上的「【答】」、菜单里的说明文案都从这里取，避免改名时各处漏改。
注意：BASE_SYSTEM 里仍然保留插件名「远望书友」（角色出自该插件），
单元测试里那条「system 含角色设定」的断言断言的就是这个词，不要删。
--]]
Prompts.PERSONA_NAME = "小望"

Prompts.BASE_SYSTEM = [[你是小望，远望书友插件里那个搭子，现在就装在这台墨水屏里。

一直要守的几条：
· 只认用户给的上下文。书里没写的，别编。
· 简体中文，纯文本，别用 Markdown，也别加标题符号。
· 屏幕小，能一句说完就别写一段。写的时候别端着，长短句混着来，
  不要「首先、其次、最后」那一套，也别拿「值得注意的是」「总的来说」垫场。
· 人家叫你小望，你就一直是小望，别自称助手、AI、模型。
· 就算要纠正他、指出他说错了，也还是这个口气，别换成老师的口气。]]

--[[--
各功能的输出长度约束（字，不是 token）。

ideas 这一条是**总输出**的上限（4 条 × ≤20 字 = ≤80 字，留足冗余），
配合 Config 的 max_tokens_ideas = 300 一起把成本封死：
模板里写死「4 条、每条 ≤20 字」，模型就算想啰嗦也没有空间。
--]]
Prompts.LIMIT = {
    explain = 200,
    summary = 300,
    concept = 300,
    chat = 600,
    ideas = 300,
    --[[--
    章末总结：用户要的是「详细、全面、多角度」，一章常态 3000–8000 字，
    ≤2200 字才铺得开几个角度。上限取的是**字**（不是 token），
    token 侧由 `max_tokens_chapter_summary` 兜（默认 4000）。
    别复用 `summary`（300）：那是给选中段落写的，一段说完，正好相反。

    为什么从 1500 抬到 2200：真机第 8 轮望仔反馈「结尾可能不完整」——
    1500 字的上限逼着模型在 5 个小标题里平均分配，写到最后一节必然撞线。
    本节正文源自 PM 的 v2 改稿：把「情节梳理」压到两三句、把省下的篇幅明确让给
    后三节；而本文件整份的版本一律称 **v3**（别再裸写「v2 模板」，会跟 commit
    标题里的 v3 打架）。
    总量不抬的话模型只会在更紧的格子里写更深的解读，截断照旧。
    2200 字配 4000 token 的预算（约 1:1.8），留出撞线余量。
    --]]
    chapter_summary = 2200,
}

--[[--
可选回复风格（用户可在「远望书友 → AI 回复风格」里切换）。

每条 = { key=配置值, text=菜单显示名, help=给用户看的人话说明（菜单 help_text），
instruction=注入 system 的语气指令 }

写指令时的两条原则：
1. 真的能改变语气 —— 只写「要活泼一点」这种形容词没用，必须落到可执行的说话方式
   （先说什么、允许什么、禁止什么）；
2. 每条都在最后一环自己兜住边界（不许人身攻击 / 联想必须标注 / 该给的答案要给），
   因为激进风格天然有越界的倾向，光靠 BASE_SYSTEM 压不住。
--]]
Prompts.STYLES = {
    {
        key = "professional",
        text = "专业严谨",
        help = "像一条查过资料的注释：先给结论，再给依据，末了说适用到哪为止。没把握宁可不说。",
        instruction = [[· 先给结论，接着摆依据，末了补一句这话管到哪为止
· 术语该用就用，别为了读着顺把精度磨掉
· 拿不准就直说「原文没明说」，不许用「大概是」「应该是」糊过去]],
    },
    {
        key = "friendly",
        text = "亲和友善",
        help = "像朋友聊起刚看完的那几页：先接一句你的感受，再往下讲，不端着，也没有客服腔。",
        instruction = [[· 开口先接住他的感受，觉得绕、觉得闷、觉得妙，先认这个，再讲内容
· 口语词和短句随便用（「其实」「你注意这儿」），但不许寒暄，不许「亲」「哦～」那套客服腔
· 碰上难啃的地方，先丢一句「这段确实绕」，再拆开讲，别让他觉得自己问了个蠢问题]],
    },
    {
        key = "blunt",
        text = "直言不讳",
        help = "判断先扔出来，不铺垫；这段写得烂就直说写得烂。刀子对准事，不对准人。",
        instruction = [[· 第一句就把结论和最要紧的判断扔出来，不铺垫、不绕弯、不留缓冲
· 原文的漏洞、人物行为说不通的地方，照说不误，包括明说「这段写得不好」
· 冲的是文本和观点，不是提问题的这个人；对事可以狠，对人不行]],
    },
    {
        key = "imaginative",
        text = "天马行空",
        help = "可以跑出去联想、比附别的小说，但凡是原文里没有的，当场说清那是你想的。",
        instruction = [[· 类比、跨作品参照随便用，目的是让他一下子有画面
· 原文里没有的部分，先标一句「这是我的联想」再往下说，不许和原文混着写
· 跑出去记得跑回来：说清楚这段原文究竟写了什么]],
    },
    {
        key = "pragmatic",
        text = "高效务实",
        help = "结论一句话，理由一条，收工。没问的背景和引申一概不送。",
        instruction = [[· 第一句结论，第二句给最要紧的那条理由，多的没有
· 能用列表就别写段落，能一个词说清就别写一句
· 他没问的来龙去脉、评价、引申全砍掉；想要更多，他会自己追问]],
    },
    {
        key = "snarky",
        text = "毒舌吐槽",
        help = "刻薄、反讽、玩笑都行，笑点和刀子都冲着情节与写法去，不冲着人。",
        instruction = [[· 嘴可以毒，话要说到点上，别为了毒而毒
· 能吐槽的只有情节、写法、人物行为和观念；不许人身攻击，也不许羞辱真实作者
· 毒归毒，事实和边界照旧：该给的信息要给准，读不到的照样不能说]],
    },
    {
        key = "socratic",
        text = "启发引导",
        help = "先反问一句，再把线索递过去，答案不直接摊开；你要答案时会痛快给。",
        instruction = [[· 先抛一个能把他推向答案的问题，再递一条线索，别把答案直接端出来
· 线索得钉在文本细节上（「他回答时刻意没提哪件事」这种），别空泛地问「你觉得呢」
· 他明说「直接说吧」、或者连着两轮没接上，立刻把完整答案给全，不许再追着问]],
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
    -- 「没有风格指令」只是语气平淡一点，绝不该变成一次请求失败。
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
    -- 否则 styleBlock 拼 「回复风格：」 .. nil 会崩
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
拼一段完整的「风格块」，供 build 追加到 system 末尾。

抬头为什么必须写：这批指令排在 BASE_SYSTEM 和防剧透说明**之后**生效，
模型对越靠后的指令越敏感；没有这句抬头，「毒舌一点」「可以联想」这类要求
会被当成对前面限制的放宽，把「只基于上下文、不要臆造」和防剧透说明稀释掉。

抬头里刻意不出现「防剧透」三个字：未开启防剧透时 system 里不该凭空多出这个词
（既有单测断言了「未传 note 时 system 不含防剧透」），
而「上面已经给出的任何约束」讲的本来就是同一回事。
@param key string|nil
@return string 永不返回 nil
--]]
Prompts.STYLE_HEADER = [[%s
照这个风格说话。它只管怎么表达，不动上面已经定下的任何约束。
两边打架的时候，听上面的：]]

function Prompts.styleBlock(key)
    local style_key = Prompts.normalizeStyleKey(key)
    local text = Prompts.styleText(style_key)
    local instruction = Prompts.styleInstruction(style_key)
    -- 指令缺失时整块都不拼：只留「回复风格：某某」这个抬头、下面没有内容，
    -- 等于给模型一句空话，还不如不写（QA 的 KNOWN 探针钉住过这个现象）
    if instruction == "" then return "" end
    return string.format(Prompts.STYLE_HEADER, "回复风格：" .. text) .. "\n" .. instruction
end

local TEMPLATES = {
    explain = [[结合上下文，说说下面这段“选中内容”在这儿到底指什么。

· 讲它在这段话里的意思，不是搬词典释义
· 要是指代，就点明它代的是谁、是啥
· %d 字以内，开口就给结论，别把原文复述一遍%s]],
    summary = [[把下面这段文字压成几句。

· 留主干，细节丢掉
· %d 字以内，一段收住%s]],
    concept = [[说说下面这个术语 / 典故 / 事件。

· 先一句定义，再补跟这本书有关的背景
· %d 字以内%s]],
    --[[--
    引导式提问（kind = ideas）：替「提不出问题」的读者问出几个问题。

    三条硬性要求，缺一条这个功能的价值就没了：
      1. 必须锚在这段文本里**已经出现过**的东西上 —— 问「这个人为何在此时提这事」
         才有用，问「这段讲了什么」是放之四海皆准的空话，本地启发式已经会给；
      2. 一行一条、不要任何编号和 Markdown 符号 —— 输出要能被 Suggest.parseList
         直接切成按钮，多一个「1.」就要靠正则去猜；
      3. 不得涉及尚未读到的内容 —— 这是防剧透的底线，和别处一样靠
         Prompts.spoilerNote / spoilerHint 在 system 与 user 两侧同时声明，
         这里再钉一遍是因为「帮我提问」天然有往后剧透的倾向（问「后来呢」最省事）。

    模板里写死的「4 条」「20 字」和 ywbf/suggest.lua 的 Suggest.DEFAULT_MAX /
    MAX_LEN 是同一套口径（那边按 4 条、每条 ≤20 字来切按钮），改一处要一起改。
    --]]
    ideas = [[替一个刚读到这儿的人，就下面这段文字问出 4 个他多半想问的问题。

· 一行一句问句，一共 4 条。别编号、别加引号、别用任何 Markdown 符号
  （「-」「*」「#」和数字序号都不要），每行就是一个完整问句，问号结尾
· 每条不超过 20 字，单独拿出来也成立，别出现「如上」「这一段」这类指代
· 只盯着这段文字里已经出现的人物、情节、动作、细节问：
  要问「他为什么偏偏在这个时点说这句话」这种只有读过才问得出口的，
  别问「这段讲了什么」「作者为什么这样写」这种放哪段都成立的空话
· 只问这段文字撑得起的问题；不得涉及尚未读到的内容，
  不得暗示后面的走向，也不要用「后来」「结果」「最终」这类往后看的字眼
· 全部输出 %d 字以内；只给这 4 行问题，
  不要开场白、不要说明、不要总结、不要结尾客套%s]],
    --[[--
    章末总结（kind = chapter_summary）。

    与 `summary` 是两回事，不要合并：`summary` 是「概括你选中的那一段」，
    要求「一段说完」；这里是「总结这一章，往深处挖，别停在复述情节上」——
    整章、往深处挖，**不是**把情节再讲一遍（「情节梳理」已经被压到两三句，
    篇幅让给后面几节的解读）。

    模板里这段**防剧透条款是重点**，不是套话。张力是真实的：你让模型
    「多角度展开」，它最爱展开的方向恰好就是「这一幕预示着后来的…」
    「这个细节为 X 埋下伏笔」——那正是剧透。所以这里把「允许往哪展开」
    和「禁止往哪看」两条都写死，不留暗示空间：
      · 允许：情节梳理 / 人物动机 / 关键细节与意象 / 语言与写法 / **本章内部**的前后呼应；
      · 禁止：任何向后看的表述，并点了四个最典型的句式。

    但**不要指望 prompt 拦住**：物理上「整章读完才取正文」是第 1 道，
    `Spoiler.sanitizeAnswer` 是最后一道（唯一不依赖模型自觉的那道）。
    这一层只是中间那道。
    --]]
    chapter_summary = [[下面是某一章完整的正文。总结这一章，往深处挖，别停在复述情节上。

· 5 个小标题一个都不能少：情节梳理 / 人物动机 / 关键细节与意象 /
  语言与写法 / 本章内部的前后呼应。某一角度本章确实没有，就写「本章没有涉及」，
  别硬凑，也别跳过
· 「情节梳理」两三句就够：说清这一章发生了什么、停在哪一步。不许照着原文讲一遍，
  不许按时间一句一句记流水账。省下的篇幅留给后面几节
· 「人物动机」一个人占一段：名字打头，说他在这一步上想要什么、被什么卡住、
  为什么这么动。有几个人就写几段，别挤成一坨
· 剩下三节才是重头戏，往透里写：这个细节为什么搁在这儿、这样写起了什么作用、
  这一章里哪儿和哪儿呼应上了。字数不用在这儿省
· 只许依据下面给出的本章正文。不得使用你对该书其它任何部分的知识，
  包括结局、后文情节、人物后来的命运，以及你从训练语料里知道的这部作品的内容
· 「多角度」只许在本章内部展开。禁止任何向后看的表述，典型如
  「这预示着…」「为后文埋下伏笔」「他后来…」「读者读到后面才知道…」
· 不得出现本章正文里没有出现过的人名、地名、事件名
· 本章正文回答不了的问题，写「本章没有给出」，不要推测、不要补全
· 纯文本，别上 Markdown，也别用「#」「*」这类符号
· 总长 %d 字以内%s]],
}

--[[--
防剧透 user 侧提示模板（双保险：system 一条 + user 一条）。
system 侧文案由 Spoiler.buildNote 生成，这里只管 user 侧那句短提醒。
--]]
Prompts.SPOILER_HINT_TEMPLATE = "\n\n（我只读到%s，这之后的内容别提。）"

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
        -- 合集：声明「第几部」，其余各部前后都算未读
        where = string.format("合集第 %d / %d 部", prog.work_index, prog.work_total)
        if type(prog.work_title) == "string" and prog.work_title ~= "" then
            where = where .. "（" .. prog.work_title .. "）"
        end
    elseif prog.granularity == Spoiler.GRANULARITY_PERCENT and type(prog.percent) == "number" then
        where = string.format("全书 %.0f%%", prog.percent)
    elseif type(prog.chapter_index) == "number" and prog.chapter_index >= 1
        and type(prog.chapter_total) == "number" then
        -- chapter_index == 0 = 还没进第 1 章，此时改报百分比，不说「第 0 章」
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
    -- 风格写丢了只会变成「稍微正式一点的默认回答」，而不会漏管。
    -- 位置固定放在防剧透说明之后：styleBlock 自带「冲突以上面为准」的兜底，
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
        -- 循环变量不能写 `_`：本文件顶部 `local _ = require("gettext")` 会被遮蔽
        for _i, h in ipairs(params.history) do
            if h and h.role and h.content then
                messages[#messages + 1] = { role = h.role, content = h.content }
            end
        end
    end

    local user
    -- ideas 与释义/摘要/词条同一组：它同样要拼 context、同样走双保险防剧透声明。
    -- 这是刻意的——AI 出题是最容易往后剧透的动作（问「后来呢」最省事），
    -- 让它走同一条管道，等于免费拿到全部四道防线。
    --
    -- 一个反直觉的点（QA 变异实测）：把 ideas 从这里摘掉**并不会**让四道防线失效
    -- ——system 侧的 spoilerNote 由调用方传进来、user 侧的 hint 在 build 末尾统一追加、
    -- 物理截断发生在 askSync 里，三者都不看 kind。真正会丢的是**输出契约**：
    -- 「一行一条、一共 4 条、每条 ≤20 字、不要开场白」。丢了以后 AI 很可能回一段散文，
    -- parseList 收不出几条，等于白花一次额度。动这一行之前先想清楚这个差别。
    -- chapter_summary 与释义/摘要/词条同一组：同样拼 context、同样吃 system+user
    -- 双保险防剧透声明、同样按 `%d 字以内` 收口。刻意不另开分支——
    -- 另开就等于把「防剧透 hint 追加」这件事复制一份，迟早改一处忘一处。
    if kind == "explain" or kind == "summary" or kind == "concept" or kind == "ideas"
        or kind == "chapter_summary" then
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
