--[[--
截断处理（finish_reason == "length"）的定向自测。

为什么单独一份脚本：
  parseList 的第三参数 truncated 是"上游传下来的事实"，不是本地能从文本里
  推出来的。所以不能只测 parseList 本身，必须测"DeepSeek 回 length → askSync
  第五个返回值 → parseList 少收一行 → 这份结果不进缓存"这一整条链。
  断在任何一环，UI 表现都是"用户点到一个半句"——真机已经翻过一次车。

在 KPW4 上跑：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     YWBF_PLUGIN_DIR=/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin \
     YWBF_TEST_DIR=/mnt/us/ywbf_dev/trunc_data \
     ./luajit /mnt/us/ywbf_dev/tools/eng_check_trunc.lua

不发网络、不烧 token：HttpClient.post 换成记账用的替身。
LuaJIT = Lua 5.1 语义：无位运算符；循环变量一律 _i。
--]]--

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR")
    or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"
local TEST_DIR = os.getenv("YWBF_TEST_DIR") or "/mnt/us/ywbf_dev/trunc_data"

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

-- ---------- ① 先装替身，再 require（顺序不能反） ----------
package.loaded["gettext"] = function(s) return s end
package.loaded["logger"] = {
    info = function() end, warn = function() end,
    dbg = function() end, err = function() end,
}
package.loaded["ui/widget/infomessage"] = {}
package.loaded["ui/widget/notification"] = {
    SOURCE_ALWAYS_SHOW = 1, notify = function() end,
}
package.loaded["ui/widget/textviewer"] = {}
package.loaded["ui/trapper"] = {}
package.loaded["ui/uimanager"] = {}

local store_calls = 0
package.loaded["ywbf/store"] = {
    append = function()
        store_calls = store_calls + 1
    end,
}

-- ---------- ② 网络替身：内容/结束原因都可在用例里换 ----------
local NEXT_CONTENT = ""
local NEXT_FINISH = "stop"
local http_calls = 0

package.loaded["ywbf/httpclient"] = {
    post = function(_url, _headers, _body, _timeout)
        http_calls = http_calls + 1
        local json = require("json")
        local reply = {
            choices = {
                {
                    message = { content = NEXT_CONTENT },
                    finish_reason = NEXT_FINISH,
                },
            },
            usage = { prompt_tokens = 100, completion_tokens = 40, total_tokens = 140 },
        }
        return json.encode(reply), 200, "OK", nil
    end,
    get = function()
        return nil, 0, "", "check_trunc: no network"
    end,
}

-- ---------- ③ 现在才 require 真模块 ----------
local Asker = require("ui/asker")
local Cache = require("ywbf/cache")
local Config = require("ywbf/config")
local DeepSeek = require("ywbf/deepseek")
local Suggest = require("ywbf/suggest")
local Util = require("ywbf/util")

local passed, failed = 0, 0
local function ok(cond, name, extra)
    if cond then
        passed = passed + 1
        print("  PASS  " .. name)
    else
        failed = failed + 1
        print("  FAIL  " .. name .. (extra and ("  -> " .. tostring(extra)) or ""))
    end
end
local function eq(a, b, name)
    ok(a == b, name, string.format("got=%s want=%s", tostring(a), tostring(b)))
end

-- ---------- ④ 环境：一律写测试目录，绝不动插件自己的 data/ ----------
Config:init(TEST_DIR)
Cache:init()
DeepSeek:setApiKey("sk-check-trunc-fake-key")
ok(DeepSeek:getApiKey() ~= nil, "假 API Key 装好了（不出网，只为走通 pipeline）")

--[[--
基线钉死。
`Config:set` 是**同步落盘**的（立刻写 settings.json），这一点 QA 踩过一次：
某节把 cache_enabled 设成 false 后中途抛异常，false 就留在盘上，下一个进程
开局带着它跑，于是"为什么这批断言红了"完全查不出来。
本脚本的 d 组恰恰依赖 cache_enabled == true，而且依赖方式很阴：
一旦它是 false，d3/d4（"截断不进缓存"）会**假绿**——缓存整体关了当然不命中，
那两条断言就失去了牙齿；只有 d7/d8 对照组会红。
所以这里显式把它钉成 true，把隐式前提变成显式断言。

注：本脚本全程不调用 Config:set，唯一的写盘动作是 setApiKey，
落在 TEST_DIR（/mnt/us/ywbf_dev/trunc_data）里，不碰插件自己的 data/。
--]]
Config:set("cache_enabled", true)
eq(Config:get("cache_enabled"), true,
    "基线：cache_enabled == true（d 组对照组依赖它，别被上一轮脚本的残留带偏）")

-- 上一轮跑完会留下缓存，必须清掉：否则第一次调用就命中缓存，
-- 一个请求都发不出去，"这次有没有真的发请求"这条根本测不到（真踩过）。
Cache:clear()
ok(Cache:count() == 0, "起始缓存为空（否则后面的 http 计数没有意义）",
    "count=" .. tostring(Cache:count()))

-- ---------- ⑤ 素材 ----------
local L1 = "袭人为什么偏偏在这时提起那块玉？"
local L2 = "宝玉为何没有立刻接话？"
local L3 = "「仔细」二字是在提醒谁？"
local L4N = "这屋里的沉默说明了什么"      -- 末行没写问号：截断残句的样子
local L4Q = "这屋里的沉默说明了什么？"    -- 末行写了问号：本身是完整问句

--[[--
素材自检：残句样本必须**短于** MAX_LEN。
否则挡住它的会是长度门槛（pushIdea 里那条 `utf8len > MAX_LEN → 丢弃`），
不是截断逻辑，于是"残句被丢"这条断言变成空转——它绿，但绿的原因跟守卫无关。
QA 提醒过这个坑：他早先那条 34 字的 JUNK 就是被长度挡掉的，压根没打到守卫上。
--]]
ok(Util.utf8len(L4N) <= Suggest.MAX_LEN,
    "素材自检：残句样本没被长度门槛挡住（丢它的确实是截断逻辑，不是长度）",
    string.format("len=%d max=%d", Util.utf8len(L4N), Suggest.MAX_LEN))
ok(Util.utf8len(L4Q) <= Suggest.MAX_LEN,
    "素材自检：单行完整问句样本也没被长度门槛挡住")

local SELECTED = "袭人笑道：“你仔细那块玉，别又失了。”宝玉只低着头，半晌不言语。"
local PROGRESS = {
    ok = true, enabled = true, chapter = "第二章 故人",
    chapter_index = 2, chapter_total = 12, page = 25, total = 200, percent = 12.5,
}

--[[--
跑一次真实的 askSync → parseList 链。
@param lines    table  模型的"逐行输出"
@param finish   string "stop" | "length"
@param book_fp  string 每次换一个，避免撞上一轮的缓存
@return content, truncated, list, from_cache
--]]
local function run(lines, finish, book_fp)
    NEXT_CONTENT = table.concat(lines, "\n")
    NEXT_FINISH = finish
    local content, _err, from_cache, _hit, truncated = Asker:askSync({
        kind = "ideas",
        selected = SELECTED,
        page_text = SELECTED,
        book_fp = book_fp,
        progress = PROGRESS,
    })
    local list = type(content) == "string"
        and Suggest.parseList(content, 4, truncated) or {}
    return content, truncated, list, from_cache
end

-- 末字符是不是问号（多字节安全：按字节取后缀比）
local function endsWithQuestion(s)
    if type(s) ~= "string" or s == "" then return false end
    return (s:sub(-3) == "？") or (s:sub(-1) == "?")
end

print("=== a. 截断 + 末行残句：残句丢掉，前 3 条保住 ===")
Cache:clear()
local _c, trunc_a, list_a = run({ L1, L2, L3, L4N }, "length", "trunc_a")
ok(trunc_a == true, "a1 askSync 第五个返回值 truncated == true", tostring(trunc_a))
eq(#list_a, 3, "a2 只收 3 条（残句被丢）")
eq(list_a[1], L1, "a3 第 1 条原样")
eq(list_a[2], L2, "a4 第 2 条原样")
eq(list_a[3], L3, "a5 第 3 条原样")
ok(list_a[4] == nil, "a6 第 4 条（残句）不在结果里", tostring(list_a[4]))
local joined = table.concat(list_a, "|")
ok(joined:find(L4N, 1, true) == nil, "a7 残句的任何一部分都没混进按钮文案")

print("=== b. 截断 + 末行是完整问句：末行照收 ===")
Cache:clear()
local _c2, trunc_b, list_b = run({ L1, L2, L3, L4Q }, "length", "trunc_b")
ok(trunc_b == true, "b1 truncated == true", tostring(trunc_b))
eq(#list_b, 4, "b2 4 条全收（有问号就不是残句）")
eq(list_b[4], L4Q, "b3 末行原样保留")

print("=== c. 没截断 + 末行漏写问号：不误杀，补问号且不削字 ===")
Cache:clear()
local _c3, trunc_c, list_c = run({ L1, L2, L3, L4N }, "stop", "trunc_c")
ok(trunc_c == false, "c1 truncated == false（stop 不是截断）", tostring(trunc_c))
eq(#list_c, 4, "c2 4 条全收（stop 时不许按截断处理）")
eq(list_c[4], L4N .. "？", "c3 漏写的问号补上，且一个字都没削")
ok(Util.utf8len(list_c[4]) == Util.utf8len(L4N) + 1, "c4 长度 = 原长度 + 1（问号不计入 20 字上限）",
    string.format("got=%d want=%d", Util.utf8len(list_c[4]), Util.utf8len(L4N) + 1))

print("=== d. 截断的那次不进缓存 ===")
Cache:clear()
http_calls = 0
local _c4, _t4, _l4, fc_d1 = run({ L1, L2, L3, L4N }, "length", "trunc_d")
eq(http_calls, 1, "d1 第一次真发了请求")
eq(fc_d1, false, "d2 第一次不是缓存命中")
local _c5, _t5, _l5, fc_d2 = run({ L1, L2, L3, L4N }, "length", "trunc_d")
eq(http_calls, 2, "d3 第二次又真发了请求（截断结果没进缓存）")
eq(fc_d2, false, "d4 第二次仍然不是缓存命中")
-- 对照组：没截断的必须照常进缓存，否则说明我把缓存整个关掉了
Cache:clear()
http_calls = 0
local _c6, _t6, _l6, fc_e1 = run({ L1, L2, L3, L4Q }, "stop", "trunc_e")
eq(http_calls, 1, "d5 对照组第一次发请求")
eq(fc_e1, false, "d6 对照组第一次不是缓存命中")
local _c7, _t7, _l7, fc_e2 = run({ L1, L2, L3, L4Q }, "stop", "trunc_e")
eq(http_calls, 1, "d7 对照组第二次没再发请求（正常结果照常进缓存）")
eq(fc_e2, true, "d8 对照组第二次命中缓存")

print("=== e. 回归：不传第三参数时行为与此前完全一致 ===")
-- 不传 truncated，即使是"截断形状"的文本，也必须照旧收满 4 条
local old = Suggest.parseList(table.concat({ L1, L2, L3, L4N }, "\n"), 4)
eq(#old, 4, "e1 旧调用方式仍然收 4 条（末行补问号）")
eq(old[4], L4N .. "？", "e2 旧的补问号行为没变")
local old2 = Suggest.parseList(table.concat({ L1, L2, L3, L4N }, "\n"), 4, false)
eq(#old2, 4, "e3 显式传 false 等价于此前的默认行为")

print("=== f. 只有一行、且是残句：整批不收（上层退回本地建议页） ===")
Cache:clear()
local _c8, trunc_f, list_f = run({ L4N }, "length", "trunc_f")
ok(trunc_f == true, "f1 truncated == true")
eq(#list_f, 0, "f2 一条都不收（那唯一一行就是残句）")
ok(type(list_f) == "table", "f3 返回的是空表不是 nil（上层 #list 不会炸）")
-- 反过来：只有一行但它是完整问句，不能因为"截断"就把它也扔了
Cache:clear()
local _c9, trunc_g, list_g = run({ L4Q }, "length", "trunc_g")
ok(trunc_g == true, "f4 truncated == true")
eq(#list_g, 1, "f5 单行完整问句照收（别为了防残句把好问题也丢了）")
eq(list_g[1], L4Q, "f6 单行完整问句原样")

print("=== g. 每条结果都以问号结尾（补问号不许削字这条没人破坏） ===")
local all = {}
for _i, v in ipairs(list_a) do all[#all + 1] = v end
for _i, v in ipairs(list_b) do all[#all + 1] = v end
for _i, v in ipairs(list_c) do all[#all + 1] = v end
for _i, v in ipairs(list_g) do all[#all + 1] = v end
local bad = 0
for _i, v in ipairs(all) do
    if not endsWithQuestion(v) then bad = bad + 1 end
end
eq(bad, 0, "g1 所有收下的问题都以问号结尾", "bad=" .. tostring(bad))
ok(#all > 0, "g2 这条断言不是空断言（确实有样本）", "#all=" .. tostring(#all))

print(string.format("=== 合计 %d 通过 / %d 失败 ===", passed, failed))
if failed > 0 then os.exit(1) end
os.exit(0)
