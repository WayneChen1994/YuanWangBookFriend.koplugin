--[[--
验证选中文本预览不再产生乱码。
对比「旧的按字节截断」和「新的按字符截断」的输出。

用法：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     ./luajit /mnt/us/ywbf_dev/check_preview.lua
--]]
package.path = "./?.lua;common/?.lua;frontend/?.lua;/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin/?.lua;" .. package.path

local Util = require("ywbf/util")

-- 模拟一段真实选中文本（含中文标点、换行、软连字符）
local selected = "我们要有一小块地，种苜蓿。" .. string.rep("莱尼反复念叨着这个梦想，乔治也渐渐被他说动。", 8)
selected = selected:gsub("苜蓿", "苜\194\173蓿")  -- 插入一个软连字符，模拟真实 epub

local PREVIEW = 100

local old_way = selected:gsub("%s+", " "):sub(1, PREVIEW)
local new_txt, total, cut = Util.preview(selected, PREVIEW)

print("原文字符数：", Util.utf8len(selected))
print("preview 总字数：", total, " 是否截断：", tostring(cut))
print("")
print("[旧] 按字节 sub(1,100)：")
print("  字节数=" .. #old_way .. "  字符数=" .. Util.utf8len(old_way) ..
      "  末3字节=" .. string.format("%02x %02x %02x",
          string.byte(old_way, #old_way - 2), string.byte(old_way, #old_way - 1), string.byte(old_way, #old_way)))
print("  -> " .. old_way)
print("")
print("[新] Util.preview(s,100)：")
print("  字节数=" .. #new_txt .. "  字符数=" .. Util.utf8len(new_txt) ..
      "  末3字节=" .. string.format("%02x %02x %02x",
          string.byte(new_txt, #new_txt - 2), string.byte(new_txt, #new_txt - 1), string.byte(new_txt, #new_txt)))
print("  -> " .. new_txt)
print("")

-- 判定：截断结果必须是合法 UTF-8 —— 逐字符解析后能完整还原
local rebuilt = {}
local pos = 1
while pos <= #new_txt do
    local b = string.byte(new_txt, pos)
    local step = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1
    if pos + step - 1 > #new_txt then
        print("FAIL: 尾部存在不完整的多字节序列（这就是乱码来源）")
        os.exit(1)
    end
    rebuilt[#rebuilt + 1] = new_txt:sub(pos, pos + step - 1)
    pos = pos + step
end
print("新方案：解析出 " .. #rebuilt .. " 个完整字符，无半截字节 ✓")

-- 软连字符必须被净化掉
if new_txt:find("\194\173", 1, true) then
    print("FAIL: 软连字符未清除")
    os.exit(1)
end
print("新方案：软连字符已清除 ✓")
print("PREVIEW OK")
