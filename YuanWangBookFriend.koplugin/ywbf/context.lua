--[[--
上下文窗口截取（PRD F2.1/F2.2，§4.3 token 控制）。

取选中位置前后各 N 字符（默认 800，可配 400–2000），
并尽量按段落边界对齐，避免把句子从中间切断。
--]]--

local Util = require("ywbf/util")

local Context = {}

Context.DEFAULT_RADIUS = 800
Context.MIN_RADIUS = 400
Context.MAX_RADIUS = 2000

-- 在 [from, to] 区间内找分隔符，找到就返回新位置，否则返回 fallback
local function snap_boundary(text, from, to, prefer_after)
    local seg = nil
    if prefer_after then
        -- 向前找第一个换行，返回其后一位
        local idx = text:find("\n", from, true)
        if idx and idx <= to then seg = idx + 1 end
    else
        -- 向后找最后一个换行，返回其位置（不含换行本身）
        local best = nil
        local i = from
        while true do
            local idx = text:find("\n", i, true)
            if not idx or idx > to then break end
            best = idx
            i = idx + 1
        end
        if best then seg = best end
    end
    return seg
end

--[[--
截取上下文窗口。
@param text 全文（当前章节/当前页纯文本）
@param sel_start 选中起点（1-based，含）
@param sel_end 选中终点（1-based，含）
@param radius 前后各取多少字符
@return { before, selected, after }
--]]
function Context.window(text, sel_start, sel_end, radius)
    if type(text) ~= "string" or text == "" then
        return { before = "", selected = "", after = "" }
    end
    radius = Util.clamp(radius or Context.DEFAULT_RADIUS, Context.MIN_RADIUS, Context.MAX_RADIUS)
    sel_start = Util.clamp(math.floor(sel_start or 1), 1, #text + 1)
    sel_end = Util.clamp(math.floor(sel_end or sel_start), sel_start - 1, #text)

    local selected = text:sub(sel_start, sel_end)

    -- 前文
    local b_start = math.max(1, sel_start - radius)
    local before = ""
    if b_start < sel_start then
        if b_start > 1 then
            local snapped = snap_boundary(text, b_start, math.min(b_start + 200, sel_start - 1), true)
            if snapped and snapped < sel_start then b_start = snapped end
        end
        before = text:sub(b_start, sel_start - 1)
    end

    -- 后文
    local a_end = math.min(#text, sel_end + radius)
    local after = ""
    if a_end > sel_end then
        if a_end < #text then
            local snapped = snap_boundary(text, math.max(sel_end + 1, a_end - 200), a_end, false)
            if snapped and snapped > sel_end then a_end = snapped - 1 end
        end
        after = text:sub(sel_end + 1, a_end)
    end

    return { before = before, selected = selected, after = after }
end

-- 简单截断（超长保护），优先在句号/换行处断开
function Context.truncate(text, max_chars)
    if type(text) ~= "string" then return "" end
    max_chars = max_chars or 4000
    if #text <= max_chars then return text end
    -- 按字符边界截断：中文 3 字节，string.sub 按字节切会切出半个汉字
    local cut = Util.utf8sub(text, max_chars)
    local last_end = 0
    for _, pat in ipairs({ "。", "！", "？", "\n", "；" }) do
        local idx_end = nil
        local i = 1
        while true do
            local f = cut:find(pat, i, true)
            if not f then break end
            -- 取到标点结尾（标点是多字节，只取到起始位置会切出半个字）
            idx_end = f + #pat - 1
            i = idx_end + 1
        end
        if idx_end and idx_end > last_end then last_end = idx_end end
    end
    if last_end > #cut * 0.5 then
        return cut:sub(1, last_end)
    end
    return cut
end

--[[--
从"当前页文本 + 选中文本"直接构造上下文窗口。
匹配策略：先按原文精确匹配；失败则折叠空白后匹配（EPUB 文本常有换行/多空格差异）。
都失败时退化为只有选中内容（功能仍可用，只是没有前后文）。
--]]
function Context.fromSelection(page_text, selected, radius)
    selected = selected or ""
    if Util.isEmpty(page_text) then
        return { before = "", selected = selected, after = "" }
    end

    local s = page_text:find(selected, 1, true)
    if s then
        return Context.window(page_text, s, s + #selected - 1, radius)
    end

    -- 退化：折叠空白后再找（用于 window 的文本是归一化后的，可接受）
    local norm_page = Util.collapseWhitespace(page_text)
    local norm_sel = Util.collapseWhitespace(selected)
    local s2 = norm_page:find(norm_sel, 1, true)
    if s2 then
        return Context.window(norm_page, s2, s2 + #norm_sel - 1, radius)
    end

    return { before = "", selected = selected, after = "" }
end

-- 组装成给模型的上下文片段
function Context.buildPayload(before, selected, after)
    local parts = {}
    if not Util.isEmpty(before) then parts[#parts + 1] = "【前文】\n" .. before end
    if not Util.isEmpty(selected) then parts[#parts + 1] = "【选中内容】\n" .. selected end
    if not Util.isEmpty(after) then parts[#parts + 1] = "【后文】\n" .. after end
    return table.concat(parts, "\n\n")
end

return Context
