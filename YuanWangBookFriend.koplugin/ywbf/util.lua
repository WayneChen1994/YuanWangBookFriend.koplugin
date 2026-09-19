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
function Util.sanitizeForDisplay(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("%c", "")            -- 控制字符
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
