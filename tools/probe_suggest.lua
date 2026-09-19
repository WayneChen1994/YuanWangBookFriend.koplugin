--[[--
探针：在 KPW4 上用真 luajit 验证 ywbf/suggest（「你可能想问」本地建议问题）。

单测是 QA 的活，这个探针的目的是证明"模块在真机上真的能跑、且产物合规"：
  1. 各种输入（nil / 空 / 短 / 长 / 对话 / 问号感叹号 / 脏字节）都不崩、不返回 nil；
  2. 返回的一定是数组，条数 ≤ max（非法 max 走回落）；
  3. 每条 ≤ 20 个中文字符、非空、无重复、无非法 UTF-8 字节；
  4. kind = explain / summary / chat / light 产出的提问角度确实不同；
  5. 未知 kind、非法 max 走回落而不是崩。

用法（先 ./tools/deploy_kpw4.sh 部署模块本体）：
  scp -i ~/.ssh/id_ywbf_kpw4 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -P 2222 tools/probe_suggest.lua root@192.168.3.89:/mnt/us/ywbf_dev/
  ssh -i ~/.ssh/id_ywbf_kpw4 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -p 2222 root@192.168.3.89 "cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
      ./luajit /mnt/us/ywbf_dev/probe_suggest.lua"
--]]

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR")
    or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"

-- 行缓冲：Windows 侧 ssh 回传常常丢最后一段输出，行缓冲能显著降低概率
io.stdout:setvbuf("line")

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

local Util = require("ywbf/util")
local Suggest = require("ywbf/suggest")

local failures = {}

local function fail(msg)
    failures[#failures + 1] = msg
    print("  FAIL: " .. msg)
end

-- 合法 UTF-8 且不含控制字符（脏字节进到 UI 上就是方块/乱码）
local function isCleanUtf8(s)
    if type(s) ~= "string" then return false end
    if s:find("%c") then return false end
    return Util.sanitizeUtf8(s) == s
end

-- ---------- 用例素材 ----------
local SHORT_SEL = "玻璃匣子"

local LONG_SEL = "贾宝玉听了这话，先是怔了一怔，随即低下头去，半晌不肯言语。"
    .. "屋外雨声渐密，檐下的铁马被风吹得叮当作响，屋里却静得连一根针落在地上都听得见。"
    .. "他心里明白，这一去只怕再难回头，可嘴上仍旧不肯说出半句软话来。"
    .. "窗纸被风掀起一角，露出外面黑沉沉的夜色，他却没有抬头去看一眼。"

local DIALOG_SEL = "“你当真不认得我了么？”她低声问道，眼里却带着三分笑意。"

local MOOD_SEL = "他猛地站起身来：“这事我绝不管！”"

local PERSON_SEL = "父亲站在门口，久久没有进来。"

-- 非法 UTF-8：孤立续字节 0x80 + UTF-16 代理对 ED A0 80
local DIRTY_SEL = "A\128B\237\160\128玻璃匣子\128"

-- ---------- 校验主体 ----------
--[[--
跑一个用例并逐条断言。
@param name string   用例名
@param opts table    传给 Suggest.list 的参数（可能是 nil）
@param want_max number 期望的条数上限（已折算回落规则）
--]]
local function check(name, opts, want_max)
    print(string.rep("-", 72))
    local kind_raw = (type(opts) == "table") and opts.kind or nil
    local max_raw = (type(opts) == "table") and opts.max or nil
    print(string.format("[%s] kind=%s max=%s (期望上限 %d)",
        name, tostring(kind_raw), tostring(max_raw), want_max))

    local ok, res = pcall(Suggest.list, opts)
    if not ok then
        fail(name .. "：Suggest.list 抛异常 -> " .. tostring(res))
        return
    end
    if type(res) ~= "table" then
        fail(name .. "：返回类型不是 table -> " .. tostring(res))
        return
    end

    -- ① 是数组：1..#res 无空洞，元素全是字符串
    local is_array = true
    for _i = 1, #res do
        if type(res[_i]) ~= "string" then is_array = false end
    end
    if not is_array then
        fail(name .. "：不是纯字符串数组（有空洞或非字符串）")
    else
        print(string.format("  ok: 是数组，条数=%d", #res))
    end

    -- ② 条数上限
    if #res > want_max then
        fail(string.format("%s：条数 %d 超过上限 %d", name, #res, want_max))
    else
        print(string.format("  ok: 条数 %d ≤ %d", #res, want_max))
    end

    -- ③ 至少 1 条（永远有兜底，绝不返回空）
    if #res < 1 then
        fail(name .. "：返回空数组（应至少有兜底问题）")
    end

    -- ④ 逐条检查
    local seen = {}
    for _i, q in ipairs(res) do
        local L = Util.utf8len(q)
        print(string.format("    %d) [%2d字] %s", _i, L, q))

        if Util.trim(q) == "" then
            fail(name .. "：第 " .. _i .. " 条是空串/纯空白")
        end
        if L > Suggest.MAX_LEN then
            fail(string.format("%s：第 %d 条 %d 字，超过 %d 字上限", name, _i, L, Suggest.MAX_LEN))
        end
        if not isCleanUtf8(q) then
            fail(name .. "：第 " .. _i .. " 条含非法 UTF-8 字节或控制字符")
        end
        if q:find("\n") or q:find("\t") then
            fail(name .. "：第 " .. _i .. " 条含换行/制表符")
        end
        if seen[q] then
            fail(name .. "：第 " .. _i .. " 条重复 -> " .. q)
        end
        seen[q] = true
    end

    -- ⑤ 脏字节用例：额外确认脏字节确实被挡在门外
    -- 注意：不能写成 q:find("\128")——0x80 是合法的 UTF-8 续字节，
    -- "一" 就是 E4 B8 80，这么查会把正常的中文全判成脏字节（假阳性）。
    -- 只能查"不可能出现在合法 UTF-8 里的序列"，再配合上面的 isCleanUtf8。
    if type(opts) == "table" and opts.selected == DIRTY_SEL then
        local bad_seqs = { "\237\160\128" }  -- UTF-16 代理对 ED A0 80
        local leaked = false
        for _i, q in ipairs(res) do
            for _j, bad in ipairs(bad_seqs) do
                if q:find(bad, 1, true) then leaked = true end
            end
        end
        if leaked then
            fail(name .. "：脏字节泄漏进了建议问题")
        else
            print("  ok: 脏字节未泄漏进建议问题（A/B 之间与末尾的非法字节已被剥离）")
        end
    end
end

-- ---------- 开跑 ----------
print("========== 0. 常量与素材长度 ==========")
print("MAX_LEN = " .. tostring(Suggest.MAX_LEN))
print("DEFAULT_MAX = " .. tostring(Suggest.DEFAULT_MAX))
print("MAX_LIMIT = " .. tostring(Suggest.MAX_LIMIT))
print("SHORT_MAX = " .. tostring(Suggest.SHORT_MAX) .. " / LONG_MIN = " .. tostring(Suggest.LONG_MIN))
print(string.format("短句长度 = %d 字", Util.utf8len(SHORT_SEL)))
print(string.format("长段长度 = %d 字（需 ≥ %d）", Util.utf8len(LONG_SEL), Suggest.LONG_MIN))
if Util.utf8len(LONG_SEL) < Suggest.LONG_MIN then
    fail("探针自身的长段素材不足 100 字，长段用例会假过")
end
-- 非空洞校验：脏字节素材必须真的脏，否则第 8 组用例是假过
if Util.sanitizeUtf8(DIRTY_SEL) == DIRTY_SEL then
    fail("探针自身的脏字节素材不含非法字节，第 8 组用例会假过")
else
    print(string.format("脏字节素材：净化前 %d 字节 -> 净化后 %d 字节（确实含非法字节）",
        #DIRTY_SEL, #Util.sanitizeUtf8(DIRTY_SEL)))
end
print("")

print("========== 1. 空输入（绝不崩、绝不返回 nil） ==========")
check("opts=nil", nil, 4)
check("opts={}", {}, 4)
check("selected=''", { selected = "" }, 4)
check("selected=纯空白", { selected = "   \n\t  " }, 4)
print("")

print("========== 2. 只有 selected：短句 ==========")
check("短句-默认kind", { selected = SHORT_SEL }, 4)
check("短句-带context", { selected = SHORT_SEL, context = "前文略。后文略。" }, 4)
print("")

print("========== 3. 只有 selected：长段（≥100字） ==========")
check("长段-默认kind", { selected = LONG_SEL }, 4)
print("")

print("========== 4. 含对话引号 ==========")
check("对话", { selected = DIALOG_SEL }, 4)
check("称谓", { selected = PERSON_SEL }, 4)
print("")

print("========== 5. 含问号/感叹号 ==========")
check("感叹号", { selected = MOOD_SEL }, 4)
check("问号", { selected = "你当真不认得我了么？" }, 4)
print("")

print("========== 6. 四种 kind 各来一遍（同一段长文本） ==========")
check("kind=explain", { kind = "explain", selected = DIALOG_SEL }, 4)
check("kind=summary", { kind = "summary", selected = DIALOG_SEL }, 4)
check("kind=chat", { kind = "chat", selected = DIALOG_SEL }, 4)
check("kind=light", { kind = "light", selected = DIALOG_SEL }, 4)
print("")

print("========== 7. max 相关 ==========")
check("max=2", { selected = LONG_SEL, max = 2 }, 2)
check("max=1", { selected = LONG_SEL, max = 1 }, 1)
check("max=6", { selected = LONG_SEL, max = 6 }, 6)
check("max=999(压到上限)", { selected = LONG_SEL, max = 999 }, Suggest.MAX_LIMIT)
check("max=0(回落4)", { selected = LONG_SEL, max = 0 }, 4)
check("max=-1(回落4)", { selected = LONG_SEL, max = -1 }, 4)
check("max='abc'(回落4)", { selected = LONG_SEL, max = "abc" }, 4)
check("max={}(回落4)", { selected = LONG_SEL, max = {} }, 4)
print("")

print("========== 8. 非法 UTF-8 字节 ==========")
check("脏字节", { selected = DIRTY_SEL }, 4)
check("脏字节+explain+max=3", { kind = "explain", selected = DIRTY_SEL, max = 3 }, 3)
print("")

print("========== 9. 未知 kind 回落 ==========")
check("kind=concept(回落chat)", { kind = "concept", selected = SHORT_SEL }, 4)
check("kind=nope(回落chat)", { kind = "nope", selected = SHORT_SEL }, 4)
check("kind=123(回落chat)", { kind = 123, selected = SHORT_SEL }, 4)
check("kind={}(回落chat)", { kind = {}, selected = SHORT_SEL }, 4)
print("")

print("========== 10. 极端入参类型（不该崩） ==========")
check("selected=number", { selected = 12345 }, 4)
check("selected=table", { selected = {} }, 4)
check("context=nil/selected=nil", { context = "只有上下文" }, 4)
print("")

print("========== 11. 个性化抽查：不同选中应产出不同建议 ==========")
local a = Suggest.list({ selected = SHORT_SEL })
local b = Suggest.list({ selected = LONG_SEL })
local c = Suggest.list({ selected = DIALOG_SEL })
print("短句首条: " .. tostring(a[1]))
print("长段首条: " .. tostring(b[1]))
print("对话首条: " .. tostring(c[1]))
if a[1] == b[1] and b[1] == c[1] then
    fail("三种不同选中产出完全相同的首条建议——没有做任何个性化")
else
    print("  ok: 不同选中产出了不同的建议问题")
end
local all_same = true
for _i = 1, math.min(#a, #b) do
    if a[_i] ~= b[_i] then all_same = false end
end
if all_same then
    fail("短句与长段的建议列表完全相同")
else
    print("  ok: 短句/长段建议列表不同")
end
print("")

print("========== 结论 ==========")
if #failures == 0 then
    print("PROBE_SUGGEST OK")
    os.exit(0)
end
print(string.format("PROBE_SUGGEST FAILED：%d 项", #failures))
for _i, m in ipairs(failures) do
    print("  - " .. m)
end
os.exit(1)
