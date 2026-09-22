--[[--
通用小工具：哈希、书籍指纹、字符串处理。
--]]--

local ok_sha2, sha2 = pcall(require, "ffi/sha2")

local Util = {}

-- 低成本 FNV-1a（md5 不可用时的兜底）
function Util.fnv(s)
    local h = 2166136261
    for i = 1, #s do
        h = (h * 16777619) % 4294967296
        h = (h + string.byte(s, i) * 16777619) % 4294967296
    end
    return string.format("%08x", h)
end

function Util.md5(s)
    if ok_sha2 and sha2 and sha2.md5 then
        local ok, v = pcall(sha2.md5, s)
        if ok and type(v) == "string" then return v end
    end
    return Util.fnv(s)
end

--[[--
书籍指纹：不读全文（KPW4 扛不住百万字 hash），只用路径 + 大小 + 修改时间。
--]]
function Util.bookFingerprint(path, size, mtime)
    local raw = string.format("%s|%s|%s", tostring(path), tostring(size or 0), tostring(mtime or 0))
    return Util.md5(raw):sub(1, 16)
end

function Util.trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Util.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- 折叠空白字符（选中文本常常带换行与多余空格）
function Util.collapseWhitespace(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("%s+", " "))
end

--[[--
保留原文的段落结构（深聊引文用）。

`collapseWhitespace` 把 `\n` 一起压成空格——那正是"引文完整了却挤成一坨"的成因
（真机反馈第 6 项）。本函数是同一族的另一半：**只动多余空行，不动段落换行**。

四条规则，每条都有真机来由：
  · 换行一律保留 —— 用户要的是"保持原文一样的格式显示出来"；
  · 连续 3 个以上换行压成 2 个（即最多留一个空行）：epub 常为了排版塞一大串
    空行，照单全收会把整屏撑满，翻一页都看不完一段引文；
  · 每行首尾空白（空格与制表符）去掉，行内的空白**保持原样**（不折叠）；
  · 整段开头与结尾的纯空行去掉，块头块尾不留空隙。

**不再引入字数截断**：用户刚要求完整显示，截回去就是绕回去。

@param s 原文
@return string 保留段落结构的文本（非字符串输入返回 ""）
--]]
function Util.keepParagraphs(s)
    if type(s) ~= "string" then return "" end

    -- keep_breaks=true：只丢控制字符，把 \n 与 \t 留下（sanitizeForDisplay 默认
    -- 的 `%c` 是包含 \n 的，实测 ("a\nb"):gsub("%c","") == "ab"）。
    local clean = Util.sanitizeForDisplay(s, true)
    -- 换行符统一成 LF：不同 epub 混着 CRLF 与 CR，不统一的话空行压不齐
    clean = clean:gsub("\r\n", "\n"):gsub("\r", "\n")

    local lines = {}
    -- 末尾补一个 \n：否则最后一行没有换行结尾时会被 gmatch 漏掉
    for line in (clean .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("^[ \t]+", ""):gsub("[ \t]+$", ""))
    end

    local first = 1
    while first <= #lines and lines[first] == "" do first = first + 1 end
    local last = #lines
    while last >= first and lines[last] == "" do last = last - 1 end

    local out, blanks = {}, 0
    for _i = first, last do
        if lines[_i] == "" then
            blanks = blanks + 1
            -- 最多留一个空行；第二个及以后的空行整段丢掉
            if blanks <= 1 then out[#out + 1] = "" end
        else
            blanks = 0
            out[#out + 1] = lines[_i]
        end
    end
    return table.concat(out, "\n")
end

--[[--
引文的**显示**形态：每段首行缩进 2 个汉字，段与段之间恰好空出一个空行。

只给展示层用。`Util.keepParagraphs` 管"段落结构别丢"，这一层管"丢不了之后再排好看"，
两者是两件事，别合并：合并了就等于把排版空格也喂给模型。

**发送链一律不经过这里**（`Prompts.build` 的引文、`cache_seed`、存进历史的 `selected`
全走 `keepParagraphs`）：
  · 把缩进喂给模型是给 prompt 掺料，白白多吃 token，还可能让模型跟着学缩进；
  · `cache_seed = selected .. "|" .. question` 一旦跟着缩进变，用户只是重看一眼
    同一段引文就变成一次新的缓存键——缓存当场失效，等于白花一次 API 调用。

为什么缩进用两个**全角空格**（U+3000）而不是两个半角空格：墨水屏字体下半角空格的
推进宽度随字号/字体变，两个半角空格在有些字号下还顶不出一个字宽，看着像没缩进；
U+3000 的宽度恒等于一个汉字，"2 个汉字"这个口径在任意字号下都成立。

@param s 一般就是 `Util.keepParagraphs` 的产物（已规整过段落结构）
@return string 排好版的引文；空输入返回 ""
--]]
--[[--
段与段之间**空几行**。当前口径 = 1（两段之间恰好空出一行）。

数法（`table.concat(out, "\n")` 决定的，别凭感觉）：
  段甲末行、""、段乙首行  ⇒  中间 2 个 \n  ⇒  屏幕上**空 1 行**。

所以这个数就是"要插几条空行"，不是"要插几个 \n"。改之前是 2 ⇒ 屏幕上空
2 行；望仔真机反馈"间隔的空行有两行，我只希望显示一行空行"（真机第 4 项），
于是改成 1。

要再调松紧只改这一个数；两个分支（下面"有空行 / 没空行"）共用它，
免得"同样是两段引文、间隔不一样"。望仔说过"半行的高度也行"——半行要动
行高/padding，观感风险更大，先只做一行；他还嫌宽我们再来改这个数/改行高。
--]]
local QUOTE_PARA_GAP = 1
-- U+3000（表意空格）的 UTF-8 字节：宽度恒等于一个汉字
local QUOTE_INDENT = "\227\128\128\227\128\128"

--[[--
判"哪里算换段"：**先问文本里有没有空行**。

真机实测（data/history 里《卡拉马佐夫兄弟》那条多段引文，f7fb…json）：
crengine 交回来的多段选中原文，段与段之间是**单个** `\n`，**一个空行都没有**——

    "…又嚷起来。\n“阿历克赛·费多罗维奇，您说吧！…"

于是"看见空行才算换段"这条老判据在真机上**永远不成立**：整块被当成一段，
只有第一行吃到缩进、段间一个空行也不插——望仔原话"只有第一段有首行缩进，
后面的段落都没有""段与段之间没有肉眼可见的空行"，就是这个。

但反过来不能直接改成"见了 \n 就换段"：epub 正文里那种一段段原文**带空行**
（`\n\n`），那种情况下空行才是段边界，而单个 `\n` 只是段内被硬折出来的续行——
每行都顶头缩两格会变成锯齿，不是段落。

所以判据是二选一，看文本本身给没给空行这个信号：
  · **有空行** → 空行是段边界，单个 \n 是续行（老行为，一字不改）；
  · **没有空行** → 每个换行都是 crengine 的块边界，每一行都独立成段。
--]]
local function hasBlankLine(clean)
    return clean:find("\n[ \t]*\n") ~= nil
end

function Util.quoteBlock(s)
    if type(s) ~= "string" or s == "" then return "" end

    local clean = s:gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines = {}
    for line in (clean .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("^[ \t]+", ""):gsub("[ \t]+$", ""))
    end

    local first = 1
    while first <= #lines and lines[first] == "" do first = first + 1 end
    local last = #lines
    while last >= first and lines[last] == "" do last = last - 1 end
    if first > last then return "" end

    local blank_is_break = hasBlankLine(clean)
    local out = {}
    -- 只有**每段的第一行**吃缩进：段内被 epub 硬折出来的那些续行保持原样，
    -- 否则每一行都顶头缩两格，看着像锯齿而不是段落。
    local para_start = true
    local pending_gap = false
    local function openParagraph()
        for _k = 1, QUOTE_PARA_GAP do out[#out + 1] = "" end
        para_start = true
    end
    for _i = first, last do
        local ln = lines[_i]
        if ln == "" then
            -- 空行不直接输出：交给下一段开头统一补，这样连续空行不会叠加
            pending_gap = true
        else
            if pending_gap then
                openParagraph()
                pending_gap = false
            elseif not blank_is_break and not para_start then
                -- 没有空行可当标记 → 走到这一行就说明上一段结束了
                openParagraph()
            end
            if para_start then
                out[#out + 1] = QUOTE_INDENT .. ln
                para_start = false
            else
                out[#out + 1] = ln
            end
        end
    end
    return table.concat(out, "\n")
end

--[==[
章末总结的小标题：与 `Prompts.TEMPLATES.chapter_summary` 里点名的那 5 个角度
一字不差。

放在这里而不是 `Prompts`：**prompts.lua 反过来 require 了 util**，在这里 require
prompts 就是循环依赖（两边互相 require，先加载的那边拿到的是半张表）。
两头一致由 `tools/eng_check_chapter_summary.lua` 里那条扫描断言盯着——
模板里改了词那边会红，不会出现"模板换说法、排版认不出来"。
--]==]
Util.SUMMARY_HEADINGS = {
    "情节梳理",
    "人物动机",
    "关键细节与意象",
    "语言与写法",
    "本章内部的前后呼应",
}

--[==[
一行要被当成小标题的**最长字数**（按字算，不是字节）。

超过就不认：正文里偶尔会冒出以同一个词开头的长句（"情节梳理到这里其实…"），
那种是正文，加粗就画反了。宁可漏认（那行当普通段落处理，只是没加粗），
不可误认（把正文一句话加粗，比不加还乱）。
--]==]
local SUMMARY_HEADING_MAX_CHARS = 30

local function isSummaryHeading(line)
    if Util.utf8len(line) > SUMMARY_HEADING_MAX_CHARS then return false end
    for _i, h in ipairs(Util.SUMMARY_HEADINGS) do
        if line:sub(1, #h) == h then return true end
    end
    return false
end

--[==[
章末总结的排版（**只在显示层**：调用点是 `ui/asker.lua` 的 showResult）。

望仔要的三件事：小标题加粗、正文首行缩进、段落之间分开。

缩进与段距**一律复用** `QUOTE_INDENT` / `QUOTE_PARA_GAP`（现在 2 个 U+3000 +
恰好空一行）——那两个数刚过真机验收，这里再另起一套常量，早晚出现
"引文一个间距、总结另一个间距"。

@param text string 模型回的纯文本（输出契约里就禁止 Markdown，见 Prompts）
@param ptf  table|nil `TextBoxWidget` 的 PTF 内联标记
             `{ header = …, bold_start = …, bold_end = … }`。
             **nil 就是不加粗**，排版照旧走完——老 KOReader（< 2024.01）没有
             这三个常量，调用方取不到就传 nil，绝不能因为拿不到标记就少排一次版。
@return string 排好版、可直接进 TextViewer 的串；空输入返回 ""
--]==]
function Util.layoutSummary(text, ptf)
    if type(text) ~= "string" or Util.trim(text) == "" then return "" end

    -- 三个常量**全**是 string 才认：只传了一半的话宁可不加粗
    -- （`nil .. 文本` 会在真机上抛 attempt to concatenate nil，卡片当场崩）
    local bold = type(ptf) == "table"
        and type(ptf.header) == "string"
        and type(ptf.bold_start) == "string"
        and type(ptf.bold_end) == "string"

    local clean = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines = {}
    for line in (clean .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("^[ \t]+", ""):gsub("[ \t]+$", ""))
    end

    local first = 1
    while first <= #lines and lines[first] == "" do first = first + 1 end
    local last = #lines
    while last >= first and lines[last] == "" do last = last - 1 end
    if first > last then return "" end

    --[[--
    换段判据与 `Util.quoteBlock` **同一条**（真机已验收）：
    文本里给了空行 → 空行才是段边界、单个 \n 是段内续行；
    一个空行都没有 → 每个 \n 都是段边界。

    别只改这一处：`tools/eng_check_chapter_summary.lua` 里有一条
    "无小标题时 layoutSummary 与 quoteBlock 必须逐字节相同" 的断言盯着，
    单边改动会红——那正是"两边各写一套、迟早不一样"的保险。
    --]]
    local blank_is_break = hasBlankLine(clean)

    local out = {}
    local para_start = true
    local pending_gap = false
    local used_bold = false
    local function openParagraph()
        for _k = 1, QUOTE_PARA_GAP do out[#out + 1] = "" end
        para_start = true
    end

    for _i = first, last do
        local ln = lines[_i]
        if ln == "" then
            -- 空行不直接输出：交给下一段开头统一补，连续空行不会叠加
            pending_gap = true
        else
            local heading = isSummaryHeading(ln)
            if pending_gap then
                openParagraph()
                pending_gap = false
            elseif not para_start and (heading or not blank_is_break) then
                openParagraph()
            end
            if heading then
                -- 小标题顶头、不缩进（缩进就不是标题了），只有真的能加粗才套标记
                if bold then
                    out[#out + 1] = ptf.bold_start .. ln .. ptf.bold_end
                    used_bold = true
                else
                    out[#out + 1] = ln
                end
                -- 标题后面那行是正文，重新开一段（这样它才吃得到首行缩进）。
                -- 只置 pending_gap 不立刻补空行：标题若是最后一行，尾巴不会多出空行。
                para_start = true
                pending_gap = true
            elseif para_start then
                out[#out + 1] = QUOTE_INDENT .. ln
                para_start = false
            else
                out[#out + 1] = ln
            end
        end
    end

    local joined = table.concat(out, "\n")
    --[[--
    PTF 的**开关**（`header`）只在真的用上加粗时才挂在整串最前面：
    一篇总结里一个小标题都没认出来时，一个多余的码点都不带出去。

    这三个都是**非法 Unicode 码点**——它们只许活在这一个返回值里。
    混进历史 / 缓存 / 导出 / 收藏详情会变豆腐块，混进缓存键还会白烧 token。
    --]]
    if bold and used_bold then return ptf.header .. joined end
    return joined
end

function Util.isEmpty(s)
    return type(s) ~= "string" or Util.trim(s) == ""
end

--[[--
生成一条"铺满指定像素宽"的重复字符线（UI 分隔线用）。

为什么不写死一串破折号：墨水屏机型的屏幕宽度从 600 到 1900 像素都有，
固定长度在宽屏上只占一小截（用户看到的就是"分隔线没占满整行"），
在窄屏上又会折成两行。所以个数必须按"可用像素宽 ÷ 单字符宽"算出来。

纯函数：像素由调用方量好传进来，这里只负责算个数，可单测。

@param usable_px 可用像素宽（>0）
@param unit_px   单个字符的水平推进像素宽（>0）
@param char      重复使用的字符
@param measure   (可选) function(string) -> number，用于兜底校验：
                 连写出来的字符串可能因为字距微调而比 n*unit 略宽，
                 传了就逐次递减到确实放得下为止。
@return string  "" 表示参数不可用，调用方应退回固定长度
--]]
function Util.fillLine(usable_px, unit_px, char, measure)
    char = char or "-"
    if type(usable_px) ~= "number" or usable_px <= 0 then return "" end
    if type(unit_px) ~= "number" or unit_px <= 0 then return "" end

    local n = math.floor(usable_px / unit_px)
    if n > 500 then n = 500 end

    if type(measure) == "function" then
        -- 最多退 10 次：字距带来的偏差远不止 1 个字符时，说明测量本身不可信
        local guard = 0
        while n > 1 and guard < 10 do
            local ok_w, w = pcall(measure, string.rep(char, n))
            if not ok_w or type(w) ~= "number" or w <= usable_px then break end
            n = n - 1
            guard = guard + 1
        end
    end

    if n < 1 then return "" end
    return string.rep(char, n)
end

-- ---------- UTF-8 安全处理 ----------
-- 中文是 3 字节，string.sub 按字节切，切在汉字中间就会产生乱码方块。
-- 所有面向用户展示的截断都必须走这里。

-- 字符数（不是字节数）
function Util.utf8len(s)
    if type(s) ~= "string" then return 0 end
    local _, count = s:gsub("[^\128-\191]", "")
    return count
end

--[[--
按字符边界安全截取前 n 个字符。
@return string 保证是合法 UTF-8（不会切在多字节序列中间）
--]]
function Util.utf8sub(s, n)
    if type(s) ~= "string" or n <= 0 then return "" end
    local len = #s
    local pos = 1
    local count = 0
    while pos <= len and count < n do
        local b = string.byte(s, pos)
        local step
        if b >= 0xF0 then      step = 4
        elseif b >= 0xE0 then  step = 3
        elseif b >= 0xC0 then  step = 2
        else                   step = 1 end
        if pos + step - 1 > len then break end  -- 尾部是不完整序列，丢弃
        pos = pos + step
        count = count + 1
    end
    return s:sub(1, pos - 1)
end

--[[--
去掉在墨水屏上会渲染成方块/乱码的不可见字符：
控制字符、软连字符 U+00AD、零宽空格 U+200B、BOM、不换行空格等。
--]]
--[[--
@param s string|nil 原文
@param keep_breaks bool|nil true = **保留换行与制表符**（只丢其余控制字符）。
                   默认（不传/false）与以前一字不差：所有控制字符连同 `\n` 一起丢掉。
                   需要"保留原文段落结构"的调用方（深聊引文，见 Util.keepParagraphs）传 true。
--]]
function Util.sanitizeForDisplay(s, keep_breaks)
    if type(s) ~= "string" then return "" end
    if keep_breaks == true then
        -- `%c` 是包含 \n(0x0A) 与 \t(0x09) 的（实测 ("a\nb"):gsub("%c","") == "ab"），
        -- 想留段落结构就必须在这里把它们挑出来，不能整类丢掉。
        s = s:gsub("%c", function(c)
            if c == "\n" or c == "\t" then return c end
            return ""
        end)
    else
        s = s:gsub("%c", "")        -- 控制字符
    end
    s = s:gsub("\239\187\191", "")  -- BOM
    s = s:gsub("\226\128\139", "")  -- 零宽空格 U+200B
    s = s:gsub("\226\128\140", "")  -- 零宽连接符 U+200C
    s = s:gsub("\226\128\141", "")  -- 零宽非连接符 U+200D
    s = s:gsub("\194\173", "")      -- 软连字符 U+00AD
    s = s:gsub("\194\160", " ")     -- 不换行空格 → 普通空格
    return s
end

--[[--
严格 UTF-8 合法性净化：丢弃一切无法构成合法码点的字节。

为什么必须有这道：epub 正文里混着各种脏数据（截断的多字节序列、孤立的续字节、
UTF-16 代理对、超长编码、> U+10FFFF 的字节）。它们进到 json.encode 之后，
输出的 JSON 里就带着非法码点，DeepSeek 直接返回
  400 "Failed to parse the request body as JSON: ... invalid unicode code point"
——表现为"选到某段文字就报错"，而且是偶发的，取决于那段文字里有没有脏字节。

sanitizeForDisplay 只清了软连字符/零宽/BOM 那几个已知字符，管不了这些，
所以发送前必须单独走一遍本函数。

保留：\n（换行，段落结构要有）、\t、以及所有合法码点。
丢弃：非法序列的字节、控制字符（\n \t 除外）。
--]]
function Util.sanitizeUtf8(s)
    if type(s) ~= "string" or s == "" then return s end

    local out = {}
    local n = #s
    local i = 1
    while i <= n do
        local b = s:byte(i)
        if b < 0x80 then
            -- ASCII：保留换行与制表符，其余控制字符丢弃
            if b == 0x0A or b == 0x09 or (b >= 0x20 and b < 0x7F) then
                out[#out + 1] = s:sub(i, i)
            end
            i = i + 1
        elseif b >= 0xC2 and b <= 0xDF then
            local b2 = s:byte(i + 1)
            if b2 and b2 >= 0x80 and b2 <= 0xBF then
                out[#out + 1] = s:sub(i, i + 1)
                i = i + 2
            else
                i = i + 1  -- 残缺序列，丢弃首字节
            end
        elseif b >= 0xE0 and b <= 0xEF then
            local b2, b3 = s:byte(i + 1), s:byte(i + 2)
            if b2 and b3 and b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF
                and not (b == 0xE0 and b2 < 0xA0)       -- 超长编码
                and not (b == 0xED and b2 >= 0xA0) then -- UTF-16 代理对（非法）
                out[#out + 1] = s:sub(i, i + 2)
                i = i + 3
            else
                i = i + 1
            end
        elseif b >= 0xF0 and b <= 0xF4 then
            local b2, b3, b4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
            if b2 and b3 and b4 and b2 >= 0x80 and b2 <= 0xBF
                and b3 >= 0x80 and b3 <= 0xBF and b4 >= 0x80 and b4 <= 0xBF
                and not (b == 0xF0 and b2 < 0x90)       -- 超长编码
                and not (b == 0xF4 and b2 >= 0x90) then -- 超过 U+10FFFF
                out[#out + 1] = s:sub(i, i + 3)
                i = i + 4
            else
                i = i + 1
            end
        else
            -- 孤立续字节(0x80-0xBF)、超长起始(0xC0/0xC1)、非法起始(0xF5-0xFF)
            i = i + 1
        end
    end
    return table.concat(out)
end

--[[--
递归净化要发出去的消息表：所有字符串字段（content / name 等）都过 sanitizeUtf8。
放在请求出口做兜底，比要求每个调用点自觉可靠。
--]]
function Util.sanitizeMessages(messages)
    if type(messages) ~= "table" then return messages end
    for _, m in ipairs(messages) do
        if type(m) == "table" then
            for k, v in pairs(m) do
                if type(v) == "string" then
                    m[k] = Util.sanitizeUtf8(v)
                end
            end
        end
    end
    return messages
end

--[[--
生成用于 UI 展示的预览文本：净化 → 折叠空白 → 按字符边界截断。
@param s 原文
@param max_chars 最多保留多少个字符
@return preview_text, total_chars, truncated
--]]
function Util.preview(s, max_chars)
    if type(s) ~= "string" or s == "" then return "", 0, false end
    local clean = Util.collapseWhitespace(Util.sanitizeForDisplay(s))
    local total = Util.utf8len(clean)
    if total <= max_chars then
        return clean, total, false
    end
    return Util.utf8sub(clean, max_chars), total, true
end

return Util
