--[[--
AI 回复风格探针：在设备上用 luajit 直接跑，检查 system prompt 的真实产物。

检查项：
  1. 7 种风格下 system 都含"小望"（角色名）；
  2. 风格指令确实随 key 变化（不是同一段）；
  3. 非法 key（nil / "" / 拼错 / 数字 / 表）一律回落到 professional；
  4. explain / summary / light / concept 等非 chat 的 kind 也带角色名和风格；
  5. 风格块的位置在防剧透说明之后，且自带"冲突以上面约束为准"的兜底。

用法（tools/deploy_kpw4.sh 之后）：
  scp -i ~/.ssh/id_ywbf_kpw4 -P 2222 tools/check_style.lua \
      root@192.168.3.89:/mnt/us/ywbf_dev/check_style.lua
  ssh -i ~/.ssh/id_ywbf_kpw4 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -p 2222 root@192.168.3.89 "cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
      ./luajit /mnt/us/ywbf_dev/check_style.lua"
--]]
local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR")
    or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"

-- 行缓冲：EXIT=1 时不会因为 stdout 没刷新而丢输出（Windows 侧 ssh 回传更容易丢）
io.stdout:setvbuf("line")

-- cpath 那行不能省：common/json 依赖 lpeg.so，少了它是「module 'lpeg' not found」
-- 而不是脚本本身的错误。
package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

local Prompts = require("ywbf/prompts")

local failures = {}

local function fail(msg)
    failures[#failures + 1] = msg
    print("  FAIL: " .. msg)
end

local function pass(msg)
    print("  ok: " .. msg)
end

print("========== 0. 基本信息 ==========")
print("PERSONA_NAME = " .. tostring(Prompts.PERSONA_NAME))
print("STYLE_DEFAULT = " .. tostring(Prompts.STYLE_DEFAULT))
print("风格数量 = " .. tostring(#Prompts.STYLES))
print("")

local PERSONA = Prompts.PERSONA_NAME
local QUESTION = "他为什么不肯明说？"

print("========== 1. 7 种风格：system 全文 ==========")
local seen_instruction = {}
local seen_by_instruction = {}
for _i, s in ipairs(Prompts.STYLES) do
    local msgs = Prompts.build("chat", {
        question = QUESTION,
        style = s.key,
    })
    local system = msgs[1].content
    print(string.rep("-", 72))
    print(string.format("[%s] key=%s", s.text, s.key))
    print(system)
    print("")

    -- ① 每种都要带角色名
    if not system:find(PERSONA, 1, true) then
        fail(s.key .. "：system 里没有角色名 " .. PERSONA)
    end
    -- 每种都要真的带上自己那条风格指令（取第一行判存不够，整段比对）
    local ins = Prompts.styleInstruction(s.key)
    if system:find(ins, 1, true) then
        pass(s.key .. "：system 已注入本风格指令")
    else
        fail(s.key .. "：system 里找不到本风格指令")
    end

    -- ② 指令必须各不相同
    local instr = Prompts.styleInstruction(s.key)
    if seen_by_instruction[instr] then
        fail(s.key .. " 与 " .. tostring(seen_by_instruction[instr]) .. " 的 instruction 完全相同")
    else
        seen_by_instruction[instr] = s.key
        seen_instruction[#seen_instruction + 1] = instr
    end
end
print("不同指令条数 = " .. tostring(#seen_instruction)
    .. " / 风格数 = " .. tostring(#Prompts.STYLES))
print("")

print("========== 2. 非法 key 回落 ==========")
local ref = Prompts.styleInstruction(Prompts.STYLE_DEFAULT)
-- 注意：不能用 ipairs 遍历含 nil 的列表——遇到第一个 nil 就停了，
-- 那个为 nil 的用例会被静默跳过（探针自己假过最要命）。逐个显式测。
local bad_keys = { "", "nope", "PROFESSIONAL", " professional", 123, {}, true }
local function check_key(k)
    local got_ins = Prompts.styleInstruction(k)
    local got_key = Prompts.normalizeStyleKey(k)
    local got_text = Prompts.styleText(k)
    local got_help = Prompts.styleHelp(k)
    local got_block = Prompts.styleBlock(k)
    print(string.format("  key=%-16s -> normalize=%-12s text=%s",
        tostring(k), tostring(got_key), tostring(got_text)))
    if type(got_ins) ~= "string" or got_ins == "" then
        fail("styleInstruction(" .. tostring(k) .. ") 返回 nil/空")
    end
    if got_ins ~= ref then
        fail("styleInstruction(" .. tostring(k) .. ") 没回落到 professional")
    end
    if got_key ~= Prompts.STYLE_DEFAULT then
        fail("normalizeStyleKey(" .. tostring(k) .. ") = " .. tostring(got_key))
    end
    if type(got_text) ~= "string" or got_text == "" then fail("styleText 返回空: " .. tostring(k)) end
    if type(got_help) ~= "string" or got_help == "" then fail("styleHelp 返回空: " .. tostring(k)) end
    if type(got_block) ~= "string" or got_block == "" then fail("styleBlock 返回空: " .. tostring(k)) end
end
check_key(nil)   -- 配置还没写过时 Config:get 返回的就是 nil
for _i, k in ipairs(bad_keys) do
    check_key(k)
end
pass("非法/缺失 key 全部回落到 " .. Prompts.STYLE_DEFAULT .. "，且返回值均非 nil")
print("")

print("========== 3. 其他 kind 也生效 ==========")
local kinds = { "explain", "summary", "concept", "chat", "light" }
for _i, kind in ipairs(kinds) do
    local msgs = Prompts.build(kind, {
        context = "【选中内容】\n贾宝玉听了，低头不语。",
        question = (kind == "chat" or kind == "light") and QUESTION or nil,
        style = "snarky",
    })
    local system = msgs[1].content
    local has_persona = system:find(PERSONA, 1, true) ~= nil
    local has_style = system:find("毒舌吐槽", 1, true) ~= nil
    print(string.format("  %-8s 消息数=%d  角色名=%s  风格标注=%s",
        kind, #msgs, tostring(has_persona), tostring(has_style)))
    if not has_persona then fail(kind .. " 的 system 缺角色名") end
    if not has_style then fail(kind .. " 的 system 缺风格标注") end
end
print("")

print("========== 4. 风格块 vs 防剧透：顺序与兜底 ==========")
local note = "【进度声明】我只读到第 3 / 10 章，未读章节的内容不得引用。"
local msgs = Prompts.build("chat", {
    question = QUESTION,
    spoiler_note = note,
    style = "snarky",
})
local system = msgs[1].content
local i_note = system:find(note, 1, true)
local i_style = system:find("回复风格：", 1, true)
print("  防剧透说明位置 = " .. tostring(i_note) .. " ，风格块位置 = " .. tostring(i_style))
if not i_note then fail("防剧透说明没进 system") end
if not i_style then fail("风格块没进 system") end
if i_note and i_style and i_style < i_note then
    fail("风格块排在防剧透说明之前——后写的内容容易被当成更晚的指示，反过来才安全")
else
    pass("风格块位于防剧透说明之后")
end
if system:find("以上面的约束为准", 1, true) then
    pass("风格块自带冲突兜底条款")
else
    fail("风格块缺少「冲突以上面约束为准」的兜底条款")
end
if system:find("只基于用户提供的上下文", 1, true) then
    pass("BASE_SYSTEM 的核心约束仍在 system 里")
else
    fail("BASE_SYSTEM 的核心约束丢失")
end
print("")

print("========== 5. 不传 style 时的默认行为 ==========")
local d = Prompts.build("chat", { question = QUESTION })
local dsys = d[1].content
print(dsys)
if dsys:find("专业严谨", 1, true) then
    pass("未传 style 时默认注入「专业严谨」")
else
    fail("未传 style 时没有默认风格")
end
print("")

print("========== 结论 ==========")
if #failures == 0 then
    print("STYLE CHECK OK")

    -- 退出码必须为 0
    os.exit(0)
end
print(string.format("STYLE CHECK FAILED：%d 项", #failures))
for _i, m in ipairs(failures) do
    print("  - " .. m)
end
os.exit(1)
