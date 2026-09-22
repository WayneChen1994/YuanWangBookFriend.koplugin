--[[--
书名化简与书籍元信息（真机反馈：列表里十几条全是同一长串书名，分不出是哪本书）。

从文件管理器拷进来的书，书名常常是「《红楼梦》人文社权威定本彩皮版XXXX……」——
后面那一串是**发布者加的修饰**，不是书名的一部分，可以从尾部剥掉。

三条不能让步的线：

1. **原始书名一个字节都不许改**。这里做的是"显示用短名"，全名仍然存在 books.json
   的 `title` 字段里。精简必须是可逆的：哪天规则改了还能重算，用户想看全名也还有。
2. **识别不出就返回 nil，不猜**。`authorOf` 认不出作者就是 nil，UI 那边"没有就不
   显示"——绝不出现孤零零一个"作者："。为了让测试变绿去猜，比留着 nil 更糟。
3. **一切按字符算**。Lua 的模式是**字节级**的：`[一-龥]` 实际等于"首字节在
   0xE4–0xE9 之间的单个字节"，`[^（）]` 会把 0x80（每个汉字的续字节都可能是它）
   排掉——两种写法都会把汉字从中间切开。这个坑在本项目里踩过三次（最早是 `[^？?]`），
   所以这里一律**先拆成字符数组**再处理，只在纯 ASCII 的场景才用模式。

纯逻辑：不 require 任何 KOReader UI 模块，能在无头 luajit 里直接 require。
LuaJIT = Lua 5.1 语义：无位运算符；循环变量一律 `_i`。
--]]--

local Util = require("ywbf/util")

local BookMeta = {}

-- 列表里书名最多显示多少个字符（超过就按字符边界截断）
BookMeta.MAX_TITLE_CHARS = 16

--[[--
取不到书名时的兜底。

`Store.UNKNOWN_BOOK` 在 store.lua 里**直接引用这个值**（store 会 require 本文件，
反过来本文件绝不能 require store——那会形成环，环上取常量拿到的是 `true` 而不是表，
`Store.UNKNOWN_BOOK` 会当场报 "attempt to index a boolean value"）。
所以这个字符串只有这一处定义。
--]]
BookMeta.FALLBACK_TITLE = "未知书"

-- ---------- 字符级小工具 ----------

--[[--
拆成字符数组。

UTF-8 的首字节高几位就说明了这个字符占几个字节，按它跳即可；
不这么做而用 `string.sub(s, i, i)` 的话，中文会被切成一个个孤立字节。
@return table 每个元素是一个完整字符（可能是多字节串）
--]]
local function toChars(s)
    local out = {}
    local i, len = 1, #s
    while i <= len do
        local b = string.byte(s, i)
        local w = 1
        if b >= 0xF0 then w = 4
        elseif b >= 0xE0 then w = 3
        elseif b >= 0xC0 then w = 2 end
        out[#out + 1] = s:sub(i, i + w - 1)
        i = i + w
    end
    return out
end

local function charsLen(s)
    return Util.utf8len(s)
end

-- 取字符数组的 [1, n] 段并拼回字符串
local function sliceChars(chars, from_idx, to_idx)
    local out = {}
    for i = from_idx, to_idx do out[#out + 1] = chars[i] end
    return table.concat(out)
end

--[[--
字段之间的分隔符。作者/出版社/译者都是从"两个分隔符之间"抠出来的，
认不清边界的话，"上海译文出版社"里的"译"会被当成译者标记。
--]]
local DELIMS = {
    [","] = true, ["，"] = true, [";"] = true, ["；"] = true, ["、"] = true,
    ["("] = true, ["（"] = true, [")"] = true, ["）"] = true,
    ["["] = true, ["【"] = true, ["]"] = true, ["】"] = true,
    ["/"] = true, ["|"] = true, ["·"] = true, [" "] = true,
    ["\t"] = true, ["_"] = true, ["-"] = true,
}

local CLOSERS = { ["）"] = true, [")"] = true, ["】"] = true, ["]"] = true }
local OPENERS = { ["（"] = true, ["("] = true, ["【"] = true, ["["] = true }

--[[--
名字尾部的"身份后缀"：抠到的是"曹雪芹著"，要的是"曹雪芹"。
只放**单字**——下面是一层一层剥的（"李玉民校注" -> 剥"注" -> 剥"校" -> "李玉民"），
放多字词反而永远匹配不上，看着像有用其实是死条目。
--]]
local NAME_SUFFIX = { ["著"] = true, ["撰"] = true, ["编"] = true, ["作"] = true,
                      ["译"] = true, ["注"] = true, ["批"] = true, ["校"] = true }

--[[--
去掉名字尾部的身份后缀（一层一层剥，"李玉民校注" -> "李玉民"）。
--]]
local function stripNameSuffix(name)
    local chars = toChars(name)
    while #chars > 1 do
        local last = chars[#chars]
        if NAME_SUFFIX[last] then
            chars[#chars] = nil
        else
            break
        end
    end
    return table.concat(chars)
end

--[[--
从 `at` 位置往前抠一段名字：遇到分隔符就停，返回剥掉身份后缀的结果。
@return string 可能是空串
--]]
local function nameBefore(chars, at)
    local j = at - 1
    -- "曹雪芹 著" 中间有空格：先跳过空格再开始抠，否则抠出来是空串
    while j >= 1 and (chars[j] == " " or chars[j] == "\t") do j = j - 1 end
    local stop = j
    while stop >= 1 and not DELIMS[chars[stop]] do stop = stop - 1 end
    local out = sliceChars(chars, stop + 1, j)
    return stripNameSuffix(out)
end

--[[--
从 `at` 位置往后抠一段名字（给"作者：XXX"这种写法用）。
@return string 可能是空串
--]]
local function nameAfter(chars, at)
    local j = at + 1
    while j <= #chars and (chars[j] == ":" or chars[j] == "：" or chars[j] == " "
                           or chars[j] == "\t" or DELIMS[chars[j]]) do
        j = j + 1
    end
    local stop = j
    while stop <= #chars and not DELIMS[chars[stop]] do stop = stop + 1 end
    return stripNameSuffix(sliceChars(chars, j, stop - 1))
end

-- 在字符数组里找第一个等于 `target` 的位置
local function indexOfChar(chars, target, from_idx)
    for i = from_idx or 1, #chars do
        if chars[i] == target then return i end
    end
    return nil
end

-- ---------- 单项识别 ----------

--[[--
ISBN。

只认 13 位（978 / 979 开头）或 10 位，归一化成纯数字串（去掉 `-` 和空格）。
归一化是必要的：书里写 `978-7-02-000220-7` 和 `9787020002207` 是同一个号，
不归一的话存储里会出现两个"看起来不同"的 ISBN。

**两档都要求候选是独立的数字串**（左右邻居都不是数字）：`1234567890123` 这种
普通编号会被截出前 10 位、`9781234567890123` 会被截出前 13 位——
返回的都是编出来的假 ISBN。同一个缺陷的两个入口，两处都得堵。

@return string|nil 纯数字串；认不出返回 nil
--]]

--[[--
10 位这一档必须是**独立的数字串**：左右相邻字符都不是数字。

不校验的话，`1234567890123`（13 位但不是 978/979 开头）会被 `(%d%d%d%d%d%d%d%d%d%d)`
截出前 10 位 `1234567890` 当 ISBN——那串只是个普通编号，返回它就是编了个假 ISBN。
（Lua 5.1 没有 `%f` 前沿模式，所以老老实实回查左右邻居。）

@param s string 已经归一化（去掉 - 和空格）的串
@param from number 候选串的起始下标
@param to number 候选串的结束下标
@return boolean
--]]
local function isStandaloneDigits(s, from, to)
    local before = (from > 1) and s:sub(from - 1, from - 1) or ""
    local after = (to < #s) and s:sub(to + 1, to + 1) or ""
    local digit_before = (before ~= "") and (before:match("%d") ~= nil) or false
    local digit_after = (after ~= "") and (after:match("%d") ~= nil) or false
    return (not digit_before) and (not digit_after)
end

function BookMeta:isbnOf(s)
    if type(s) ~= "string" then return nil end
    -- 只去掉 ASCII 的 - 和空格：这个类是纯 ASCII，不会误伤中文
    local cleaned = s:gsub("[%- ]", "")
    --[[--
    两档都是同一个套路：`match` 只回字符串不回位置，所以用 `find` 拿下标再判邻居；
    判不过就跳过这一段继续往后找（一串长数字后面也许还跟着独立的一段）。
    --]]
    local pos = 1
    while true do
        local from, to = cleaned:find("97[89]%d%d%d%d%d%d%d%d%d%d", pos)
        if type(from) ~= "number" or type(to) ~= "number" then break end
        if isStandaloneDigits(cleaned, from, to) then return cleaned:sub(from, to) end
        pos = to + 1
    end
    pos = 1
    while true do
        local from, to = cleaned:find("%d%d%d%d%d%d%d%d%d%d", pos)
        if type(from) ~= "number" or type(to) ~= "number" then break end
        if isStandaloneDigits(cleaned, from, to) then return cleaned:sub(from, to) end
        pos = to + 1
    end
    return nil
end

--[[--
作者。认三种写法：`作者：曹雪芹` / `曹雪芹 著` / `(清)曹雪芹著`。

@return string|nil
--]]
function BookMeta:authorOf(s)
    if type(s) ~= "string" then return nil end
    local chars = toChars(s)

    -- ① "作者：XXX"
    local i = indexOfChar(chars, "作")
    while i do
        if chars[i + 1] == "者" then
            local name = nameAfter(chars, i + 1)
            if name ~= "" then return name end
        end
        i = indexOfChar(chars, "作", i + 1)
    end

    -- ② "XXX著" / "XXX撰"（从后往前抠，"（清）曹雪芹著" 里的括号是天然边界）
    for k = 2, #chars do
        if chars[k] == "著" or chars[k] == "撰" then
            local name = nameBefore(chars, k)
            if name ~= "" and charsLen(name) <= 20 then return name end
        end
    end
    return nil
end

--[[--
译者 / 注者 / 批者。

为什么不能直接找"译"字：**"上海译文出版社"里就有一个"译"**，
照字面找会把"上海"当成译者。所以遇到"译"时要看它后面是不是"者/文/作"
（那些是别的词的组成部分），是就跳过。

@return string|nil
--]]
function BookMeta:translatorOf(s)
    if type(s) ~= "string" then return nil end
    local chars = toChars(s)

    -- ① "译者：XXX"
    local i = indexOfChar(chars, "译")
    while i do
        if chars[i + 1] == "者" then
            local name = nameAfter(chars, i + 1)
            if name ~= "" then return name end
        end
        i = indexOfChar(chars, "译", i + 1)
    end

    -- ② "XXX译" / "XXX注" / "XXX批"
    for k = 2, #chars do
        local c = chars[k]
        if c == "译" or c == "注" or c == "批" then
            -- "译文"/"译作"/"译林" 这类是别的词，跳过
            local skip = (c == "译" and chars[k + 1] ~= nil
                          and (chars[k + 1] == "者" or chars[k + 1] == "文"
                               or chars[k + 1] == "作" or chars[k + 1] == "林"))
            if not skip then
                local name = nameBefore(chars, k)
                --[[--
                **至少 2 个字**：`陀思妥耶夫斯基作品集_上译` 的尾巴是出版社短名"上译"，
                `译` 又在串尾，照字面抠出来的是"上"——于是"译者：上"，
                disambiguate 会拿它当区分值，展示名变成 `陀思妥耶夫斯基作品集（上）`。
                中文译者名不会只有 1 个字，抠出单字就是抠错了，宁可返回 nil
                （这里返回 nil 之后，消歧会走到 publisher 维度，认出"上译"这个出版社）。
                --]]
                if charsLen(name) >= 2 and charsLen(name) <= 20 then return name end
            end
        end
    end
    return nil
end

--[[--
出版社短名：`书名_上海译文`、`书名_上译` 这种尾部段。

只放**真机书库里真实出现过**的。凭空加一串想当然的社名会误伤人名——
`西方哲学史_邓晓芒` 的"邓晓芒"是作者不是出版社，认出来就变成"出版社：邓晓芒"了
（fixtures 的硬用例里有这三条人名对照）。

放在 `publisherOf` **之前**是因为它也要用：Lua 的 local 只对它**之后**的代码可见，
写在"精简书名"那一节的话这里拿到的是 nil。
--]]
local PUBLISHER_SHORT = {
    ["上海译文"] = true, ["上译"] = true, ["人民文学"] = true,
    ["人文社"] = true, ["译林"] = true, ["河北教育"] = true,
    ["商务印书馆"] = true, ["中华书局"] = true, ["三联书店"] = true,
    ["上海古籍"] = true, ["浙江文艺"] = true, ["湖南文艺"] = true,
    ["长江文艺"] = true, ["岳麓书社"] = true, ["新星"] = true,
    ["中信"] = true,
}

--[[--
最后一个分隔符的位置（`罪与罚_曾思艺译本` 里那个 `_`）。

@param chars table 字符数组
@return number|nil 找不到分隔符时返回 nil
--]]
local function lastDelim(chars)
    local last = nil
    for i = 1, #chars do
        if DELIMS[chars[i]] then last = i end
    end
    return last
end

--[[--
出版社。

两种写法都认：
  ① `…人民文学出版社…` —— 连"出版社"三个字一起返回（"人民文学出版社"，不是"人民文学"）；
  ② `书名_上海译文` —— 尾部段命中出版社短名，返回**短名本身**（不补"出版社"三个字，
     补了就是假信息：人家文件名上写的是"上海译文"）。

② 是给 `disambiguate` 用的：`陀思妥耶夫斯基作品集_上海译文` 和 `..._上译` 化简后
同名，靠出版社区分时三个维度必须至少有一个有值，否则展示名会退化成
`陀思妥耶夫斯基作品集（陀思妥耶夫斯基作品集_上海译文）` 这种废话。

@return string|nil
--]]
function BookMeta:publisherOf(s)
    if type(s) ~= "string" then return nil end
    local chars = toChars(s)
    local i = indexOfChar(chars, "出")
    while i do
        if chars[i + 1] == "版" and chars[i + 2] == "社" then
            -- 往前找到上一个分隔符：出版社名从那儿开始
            local stop = i - 1
            while stop >= 1 and not DELIMS[chars[stop]] do stop = stop - 1 end
            local name = sliceChars(chars, stop + 1, i - 1)
            if name ~= "" then return name .. "出版社" end
        end
        i = indexOfChar(chars, "出", i + 1)
    end
    -- ① 没认出来才试 ②：写全了"出版社"三个字的时候以那个为准
    local last = lastDelim(chars)
    if last then
        local seg = sliceChars(chars, last + 1, #chars)
        if seg ~= "" and PUBLISHER_SHORT[seg] then return seg end
    end
    return nil
end

-- ---------- 精简书名 ----------

--[[--
尾部修饰词（发布者加的包装，不是书名的一部分）。

两条踩过的坑：

* **长词优先**（下面按字符数倒序排）：不排的话，"人民文学出版社"会先被"出版社"
  命中，剩一个孤零零的"人民文学"挂在书名尾巴上——比不剥还难看。
* **不收"全集 / 文集 / 作品集 / 选集 / 套装 / 脂评本 / 程甲本"这类词**。
  它们是**书名的一部分**：`郑渊洁童话全集` 剥成 `郑渊洁童话`、`陀思妥耶夫斯基作品集`
  剥成 `陀思妥耶夫斯基`，都是把两本不同的书并成同一本——用户要的正是"分得清是哪本"。
  team-lead 按真机书库裁定的硬用例（`tools/fixtures_book_titles.lua`）里这两条都要求
  原样保留。
--]]
local MODIFIERS = {
    "人民文学出版社", "上海译文出版社", "无障碍阅读版", "出版社", "人文社",
    "权威定本", "精装版", "平装版", "典藏版", "珍藏版", "纪念版", "修订版",
    "插图版", "青少年版", "白话版", "上下册", "全二册", "全三册", "新版",
    "最新版", "定本", "彩皮版", "足本", "全本",
}
table.sort(MODIFIERS, function(a, b) return charsLen(a) > charsLen(b) end)

-- 去掉尾部一段（模式只用在纯 ASCII 的场景，中文一律走字符数组）
local function stripTailPattern(s, pattern)
    local new_s, n = s:gsub(pattern .. "$", "")
    if n > 0 and new_s ~= s then return new_s end
    return nil
end

-- 尾部括号段：`（…）` / `(…)` / `【…】` / `[…]`
local function stripTailBracket(s)
    local chars = toChars(s)
    if #chars < 2 then return nil end
    if not CLOSERS[chars[#chars]] then return nil end
    for i = #chars - 1, 1, -1 do
        if OPENERS[chars[i]] then
            return sliceChars(chars, 1, i - 1)
        end
    end
    return nil
end

local function stripTailModifier(s)
    for _i, m in ipairs(MODIFIERS) do
        if #s > #m and s:sub(-#m) == m then
            return s:sub(1, #s - #m)
        end
    end
    -- "第2版" / "2018版" / "2018年版"
    local v = stripTailPattern(s, "%d+版")
    if v then return v end
    v = stripTailPattern(s, "%d%d%d%d年版")
    if v then return v end
    return nil
end

--[[--
尾部"编号尾巴"：≥6 位、且含 ≥4 个数字的字母数字串（就是用户说的那一长串）。

为什么必须要求"含数字"：纯字母的长尾巴很可能是英文书名的一部分
（"HarryPotterAndTheChamberOfSecrets"），剥掉它就是把书名剥没了。
宁可剥不掉（后面还有字数上限兜着），也不能把真书名切掉。
--]]
local function stripTailCode(s)
    local tail = s:match("(%w+)$")
    if type(tail) ~= "string" or #tail < 6 then return nil end
    local digits = 0
    for d in tail:gmatch("%d") do digits = digits + 1 end
    if digits < 4 then return nil end
    return s:sub(1, #s - #tail)
end

--[[--
尾部"同一个字符刷屏"：`……彩皮版XXXXXXXXXXXXXXXXXX`。

真书名不会以四个一模一样的字符收尾，这种只可能是编号 / 占位垃圾。
（为什么不写成"≥6 位字母数字就剥"：`HarryPotterAndTheChamberOfSecrets` 这种英文书名
会被整段剥没——上面 `stripTailCode` 坚持要"含 ≥4 个数字"也是同一个道理。）

`gsub` 返回两个值，这里只要第一个（替换次数无关），用一个变量接住即可。
--]]
local function stripTailRepeat(s)
    local tail = s:match("(%w+)$")
    if type(tail) ~= "string" or #tail < 4 then return nil end
    local first = tail:sub(1, 1)
    local rest = tail:gsub(first, "")
    if rest ~= "" then return nil end
    return s:sub(1, #s - #tail)
end

--[[--
尾部段是不是"元信息"（出版社 / 译者），而不是书名的一部分。

@param seg string 最后一个分隔符之后的那一整段
--]]
local function isMetaTailSegment(seg)
    if seg == "" then return false end
    if PUBLISHER_SHORT[seg] then return true end
    local chars = toChars(seg)
    if #chars >= 3 and sliceChars(chars, #chars - 2, #chars) == "出版社" then
        return true
    end
    if #chars >= 2 then
        local tail2 = sliceChars(chars, #chars - 1, #chars)
        if tail2 == "译本" or tail2 == "译著" then return true end
    end
    return false
end

--[[--
剥掉尾部的元信息段（`罪与罚_曾思艺译本` -> `罪与罚`）。

为什么按"整段"剥、而不是"以译本结尾就剥掉'译本'两个字"：只剥两个字会留下
`罪与罚_曾思艺`——比不剥还难认。整段剥掉才是对的，也才对得上 fixtures 的期望值。

@return string|nil
--]]
local function stripTailMetaSegment(s)
    local chars = toChars(s)
    local last = lastDelim(chars)
    if last == nil then return nil end
    if not isMetaTailSegment(sliceChars(chars, last + 1, #chars)) then return nil end
    return Util.trim(sliceChars(chars, 1, last - 1))
end

--[[--
副标题：冒号（或 Calibre 风格的 ` _ `）后面那半段整段丢掉。

为什么不干脆取《》里那段：`雪隐鹭鸶：《金瓶梅》的声色与虚无` 里的《金瓶梅》是
**另一本书**，照书名号取会把这本认成那本（fixtures 里明写了这条）。所以书名号只有
在**串的最前面**时才当本体用，其余情况一律按副标题分隔符切。
--]]
local function stripHeadSubtitle(s)
    local chars = toChars(s)
    for i = 1, #chars do
        local cut = nil
        if chars[i] == "：" or chars[i] == ":" then
            cut = i
        elseif chars[i] == " " and chars[i + 1] == "_" and chars[i + 2] == " " then
            -- Calibre 导出的命名里 " _ " 和 "：" 是同一个意思
            cut = i
        end
        if cut then
            local head = Util.trim(sliceChars(chars, 1, cut - 1))
            if charsLen(head) >= 2 then return head end
            return nil
        end
    end
    return nil
end

--[[--
精简书名。

**只做语义化简，不做显示截断**——截断是 `shortTitle` 的事。
为什么不在这里截：`皮皮鲁传_鲁西西传_大灰狼罗克传_舒克贝塔传` 是四本合集，化简结果
有 22 个字，但它是**一个完整的书名**；在这里截成 16 个字，存储里就再也拼不回去了
（fixtures 里这条的期望值就是完整的 22 字）。列表里显示多长由 `shortTitle` 决定。

顺序（每一步都可单测）：
  ① 串**以** `《…》` 开头时，取书名号里那段（≥2 字才采用）；
  ② 反复剥离直到某一轮下来什么都没剥掉：副标题 → 尾部括号段 → 尾部元信息段
     （`_上海译文` / `_曾思艺译本`）→ 尾部修饰词 → ISBN → 尾部分隔符 →
     编号尾巴 → 同一字符刷屏；
  ③ **每一步剥完若不足 2 字就放弃这一步**（否则《红楼梦》会被剥成"红"）。

@return string 永不返回 nil、永不返回空串
--]]
function BookMeta:simplify(title)
    if type(title) ~= "string" then
        return Util.preview(tostring(title), BookMeta.MAX_TITLE_CHARS)
    end
    local trimmed = Util.trim(title)
    if trimmed == "" then
        local p = Util.preview(title, BookMeta.MAX_TITLE_CHARS)
        if p == "" then return BookMeta.FALLBACK_TITLE end
        return p
    end

    local base = trimmed
    -- 书名号只在**最前面**才当本体：出现在副标题里的《…》多半是另一本书
    local inner = base:match("^《(.-)》")
    if type(inner) == "string" then
        local t = Util.trim(inner)
        if charsLen(t) >= 2 then base = t end
    end

    local changed = true
    while changed do
        changed = false
        local candidate = stripHeadSubtitle(base)
        if candidate == nil then candidate = stripTailBracket(base) end
        if candidate == nil then candidate = stripTailMetaSegment(base) end
        if candidate == nil then candidate = stripTailModifier(base) end
        if candidate == nil then
            candidate = stripTailPattern(base, "[%s_%-%.]*97[89][%d%s%-]+")
        end
        if candidate == nil then candidate = stripTailPattern(base, "[%s%-%_%.]+") end
        if candidate == nil then candidate = stripTailCode(base) end
        if candidate == nil then candidate = stripTailRepeat(base) end

        if candidate ~= nil then
            local next_base = Util.trim(candidate)
            -- 剥完只剩 1 个字（或没了）就放弃这一步：宁可留着长的，也不能把书名剥残
            if charsLen(next_base) >= 2 then
                base = next_base
                changed = true
            end
        end
    end

    return base
end

--[[--
把原始书名拆成结构化信息。

**一律从原始完整书名提取**：`simplify` 会把作者、出版社、ISBN 这些剥掉，
从精简后的串里再认一遍什么都认不出来。

@return table { title, publisher, author, translator, isbn }
       识别不出的字段是 nil，但 `title` 永不为空
--]]
function BookMeta:parse(full)
    return {
        title = self:simplify(full),
        publisher = self:publisherOf(full),
        author = self:authorOf(full),
        translator = self:translatorOf(full),
        isbn = self:isbnOf(full),
    }
end

--[[--
列表显示用的短书名。
@param x string|table 原始书名，或 books.json 里的记录（取它的 title）
@return string 永不为空
--]]
function BookMeta:shortTitle(x)
    local raw = x
    if type(x) == "table" then raw = x.title_short or x.title end
    return Util.preview(self:simplify(raw), BookMeta.MAX_TITLE_CHARS)
end

--[[--
详情界面用的元信息行。

**没有的字段不出行、也不出空标签**——屏幕上出现一个孤零零的"作者："比什么都不写更糟。

@param x string|table 原始书名，或 books.json 里的记录
@return table 行数组，至少有一行（书名那一行）
--]]
function BookMeta:metaLines(x)
    local info = type(x) == "table" and x or self:parse(x)

    local title = type(info.title) == "string" and info.title ~= "" and info.title or nil
    local parsed = nil
    -- 记录里缺的字段，回退到书名里再认一次（老数据只有 title 一个字段）
    local function field(name)
        local v = info[name]
        if type(v) == "string" and v ~= "" then return v end
        if title then
            if parsed == nil then parsed = self:parse(title) end
            local pv = parsed[name]
            if type(pv) == "string" and pv ~= "" then return pv end
        end
        return nil
    end

    local short = (type(info.title_short) == "string" and info.title_short ~= "")
        and info.title_short
        or self:shortTitle(title or BookMeta.FALLBACK_TITLE)

    local lines = { "《" .. short .. "》" }

    local author = field("author")
    local translator = field("translator")
    if author and translator then
        lines[#lines + 1] = author .. " · " .. translator
    elseif author then
        lines[#lines + 1] = author
    elseif translator then
        lines[#lines + 1] = translator
    end

    local publisher = field("publisher")
    if publisher then lines[#lines + 1] = publisher end

    local isbn = field("isbn")
    if isbn then lines[#lines + 1] = "ISBN " .. isbn end

    return lines
end

--[[--
撞名消歧：化简后同名的书，给展示名补一个能区分的后缀。

为什么要它：用户抱怨的是"**分不出是哪本书**"。书名化简只解决了"太长"，
`罪与罚_曾思艺译本` / `_朱海观王汶译本` / `_臧仲伦译本` 化简完都是 `罪与罚`——
长度问题没了，同名问题还在。

**顺序不能反**：先 `Util.preview(simplify(t), MAX_TITLE_CHARS)` 得到 base，
**再**拼后缀。`陀思妥耶夫斯基作品集` 正好 16 字，先拼后缀再截断的话
`（上海译文）` 会被切掉，等于白做——那正是用户抱怨的那件事。

后缀用全角括号、里面放**裸值**（`曾思艺` 不是"曾思艺 译"）：夹具里的断言是
按 `find(hint)` 找裸值的，加角色词就找不到了；屏幕上"《罪与罚（曾思艺）》"
本来就够读，再加"译"是噪音。

**唯一的例外是第 5 步**（三个维度都认不出时）：那种情况不拼括号，
直接给原始书名按 24 字预览——拼括号会得到
`陀思妥耶夫斯基（陀思妥耶夫斯基 _ 作家与他的时）` 这种被切断的废话。

@param titles table 原始书名数组（**未经 simplify** 的）
@return table map：`原始书名 -> 展示名`
--]]
function BookMeta:disambiguate(titles)
    local out = {}
    if type(titles) ~= "table" then return out end

    -- 第 1 步：base。**16 字上限在这里就用掉**，后面拼的后缀在它之外
    local raws, base_of, parsed_of = {}, {}, {}
    for _i, t in ipairs(titles) do
        --[[--
        只收字符串。写成"不是 table 就收"的话，数组里混进一个 nil 会在后面
        往 map 里写展示名那一步当场报 "table index is nil"——整个列表页打不开，
        比少显示一本书糟得多。

        （顺带一个坑：这段注释里原来拿一句带下标取值的代码举例子，里面那两个连续的
        右方括号正好把长注释提前关掉，luajit 把错报在举例子那一行，看着像代码写错，
        其实是注释写错。所以长注释里不写带连续右方括号的代码片段。）
        --]]
        if type(t) == "string" then
            raws[#raws + 1] = t
            base_of[#base_of + 1] = Util.preview(self:simplify(t), BookMeta.MAX_TITLE_CHARS)
            parsed_of[#parsed_of + 1] = nil
        end
    end
    if #raws == 0 then return out end

    -- 第 2 步：按 base 分组（组内保持入参顺序，兜底序号才稳定）
    local groups, group_of = {}, {}
    for _i, base in ipairs(base_of) do
        local g = groups[base]
        if g == nil then
            g = {}
            groups[base] = g
            group_of[#group_of + 1] = { base = base, members = g }
        end
        g[#g + 1] = _i
        out[raws[_i]] = base
    end

    --[[--
    第 4 步的"维度"：依次试 `translator` → `publisher` → `author`。

    维度可用 = 组内取值**两两不等**，且**最多一条没有值**（空串当没有）。
    可用时：有值的拼 `（值）`，那条没有值的**不加后缀**——
    `白痴` / `白痴_臧仲伦译本` 于是得到 `白痴` 和 `白痴（臧仲伦）`，
    既两两不等，也符合人的直觉（有译本的那本才标译者）。
    --]]
    local function valueAt(idx, field_name)
        if parsed_of[idx] == nil then parsed_of[idx] = self:parse(raws[idx]) end
        local v = parsed_of[idx][field_name]
        if type(v) ~= "string" or v == "" then return nil end
        return v
    end

    local DIMENSIONS = { "translator", "publisher", "author" }

    for _i, g in ipairs(group_of) do
        local members = g.members
        -- 第 3 步：组内 1 条 → 展示名就是 base，一个字都不许加
        if #members >= 2 then
            local solved = false
            for _d, field_name in ipairs(DIMENSIONS) do
                local values, nil_count, usable = {}, 0, true
                for _m = 1, #members do
                    local v = valueAt(members[_m], field_name)
                    values[_m] = v
                    if v == nil then
                        nil_count = nil_count + 1
                        if nil_count > 1 then usable = false end
                    end
                end
                if usable then
                    for _m = 2, #members do
                        for _n = 1, _m - 1 do
                            if values[_m] ~= nil and values[_m] == values[_n] then
                                usable = false
                            end
                        end
                    end
                end
                if usable then
                    for _m = 1, #members do
                        local idx = members[_m]
                        if values[_m] == nil then
                            out[raws[idx]] = g.base
                        else
                            out[raws[idx]] = g.base .. "（" .. values[_m] .. "）"
                        end
                    end
                    solved = true
                    break
                end
            end
            --[[--
            第 5 步：三个维度都不行 → **直接用原始书名本身**，只是按更宽的上限（24 字）预览。

            为什么不拼 `base（原始书名）`：真机书库里 `陀思妥耶夫斯基 _ 作家与他的时代`
            和 `陀思妥耶夫斯基：作家与他的时代` 是**同一本书的两种文件命名**，
            化简后都叫 `陀思妥耶夫斯基`、三个维度全 nil，拼出来就是
            `陀思妥耶夫斯基（陀思妥耶夫斯基 _ 作家与他的时）` —— 括号里被 16 字切断，
            又丑又没信息量，而这条用户**一定看得到**。

            也不取"原文与 base 不同的那一段"（那两段的差异段都是 `作家与他的时代`，
            照样撞名，最后还得靠第 6 步补序号）。直接给原始名最实在：
            它本来就是这本书在文件管理器里叫的名字，用户认得出来。

            `Util.preview` 返回三个值（clean / total / truncated），老实用一个变量接住
            第一个，不要直接 return 出去把后两个值也带给调用方。
            --]]
            if not solved then
                for _m = 1, #members do
                    local idx = members[_m]
                    local v = Util.preview(tostring(raws[idx]), BookMeta.MAX_TITLE_CHARS + 8)
                    -- 预览出空串（原始名是空串 / 不可显示）时退回 base，绝不显示空行
                    out[raws[idx]] = (type(v) == "string" and v ~= "") and v or g.base
                end
            end
        end
    end

    --[[--
    第 6 步：最终兜底。前几步**不保证**够用（两本书连 24 字预览都撞成一样），
    所以这里按组内次序**追加** `（2）`、`（3）`，把"两两不等"钉死。
    是追加不是替换：第 5 步给的是原始书名的 24 字预览，那是用户认得出来的名字，
    换成 `base（2）` 反而把信息丢了。
    原始书名**逐字节相同**的两条允许同名——那是标题层面真的分不出，硬造一个尾巴反而是假信息。
    --]]
    for _i, g in ipairs(group_of) do
        local members = g.members
        if #members >= 2 then
            local seen, first_of_raw = {}, {}
            for _m = 1, #members do
                local idx = members[_m]
                local raw = tostring(raws[idx])
                if first_of_raw[raw] ~= nil then
                    out[raws[idx]] = out[raws[first_of_raw[raw]]]
                else
                    first_of_raw[raw] = idx
                    local name = out[raws[idx]]
                    local original = name
                    local n = 1
                    while seen[name] do
                        n = n + 1
                        name = original .. "（" .. tostring(n) .. "）"
                    end
                    out[raws[idx]] = name
                    seen[name] = true
                end
            end
        end
    end

    return out
end

return BookMeta
