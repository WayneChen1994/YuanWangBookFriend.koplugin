--[[--
风格改动的下游端到端验证：看**真正发出去的 HTTP 请求体**。

为什么还要这一层：check_style.lua 只证明 Prompts.build 会按 key 拼出不同 system，
但风格要走到线上还得过两道：
  1. Asker 有没有真把 Config 里的 reply_style 传给 Prompts.build（漏传就永远是默认风格，
     而 Prompts.build 对 nil 是静默回落的，不报任何错）；
  2. 缓存是不是按风格分桶 —— 否则换成毒舌后问同一段话，会命中之前专业风格的旧回答，
     用户看到的现象就是"改了设置没生效"。

做法：stub 掉 HttpClient.post 截获请求体（不发网络、不烧 token），其余全用真源码。

用法：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     ./luajit /mnt/us/ywbf_dev/smoke_style_e2e.lua
--]]

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR")
    or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"
local TMP_DIR = os.getenv("YWBF_E2E_DIR") or "/mnt/us/ywbf_dev/e2e_data"

io.stdout:setvbuf("line")

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

-- ---- 桩：UI 层不需要真的画出来 ----
local function fake_widget(self, t) -- luacheck: ignore
    t.show = function() end
    t.close = function() end
    return t
end
package.loaded["ui/uimanager"] = {
    show = function(self, w) end,
    close = function(self, w) end,
    scheduleIn = function(self, sec, fn) end,
}
package.loaded["ui/widget/infomessage"] = { new = fake_widget }
package.loaded["ui/widget/textviewer"] = { new = fake_widget }
package.loaded["ui/widget/inputdialog"] = { new = fake_widget }
package.loaded["ui/widget/notification"] = {
    SOURCE_ALWAYS_SHOW = 1,
    notify = function(text, source, always) end,
}
package.loaded["ui/trapper"] = {
    wrap = function(self, fn) return fn() end,
    info = function(self, txt) end,
    isWrapped = function(self) return false end,
    clear = function(self) end,
}

local Config = require("ywbf/config")
local Crypto = require("ywbf/crypto")
local Prompts = require("ywbf/prompts")
local Cache = require("ywbf/cache")
local HttpClient = require("ywbf/httpclient")
local json = require("json")

Config:init(TMP_DIR)
Cache:init()
Cache:clear()
-- Trapper 被桩成了同步执行，askSync 里 Crypto 取 Key 仍然要真的有 Key
Config:set("api_key_enc", Crypto:encrypt("sk-style-e2e-not-real"))

local failures = {}
local function fail(m) failures[#failures + 1] = m; print("  FAIL: " .. m) end
local function pass(m) print("  ok: " .. m) end

-- 截获请求体
local captured = nil
HttpClient.post = function(url, headers, body, timeout)
    captured = body
    return '{"choices":[{"message":{"content":"这是回复"}}],"usage":{"total_tokens":7}}',
        200, "OK", nil
end

local Asker = require("ui/asker")

local PAGE = "宝玉听了这话，低头沉思良久，方才缓缓说道：你且回去，明日再说。"
local SELECTED = "你且回去，明日再说"
local QUESTION = "他为什么不当面说清楚？"

local function ask_once(style_key)
    Config:set("reply_style", style_key)
    captured = nil
    local content, err, from_cache = Asker:askSync({
        kind = "chat",
        book_fp = "e2e-book-fp",
        page_text = PAGE,
        selected = SELECTED,
        question = QUESTION,
        progress = { enabled = true, granularity = "chapter",
                     chapter_index = 3, chapter_total = 10 },
    })
    return content, err, from_cache, captured
end

print("========== 1. 风格是否真的传到了请求体 ==========")
local bodies = {}
local order = { "professional", "friendly", "blunt", "imaginative",
                "pragmatic", "snarky", "socratic" }
for i, key in ipairs(order) do
    local content, err, _, body = ask_once(key)
    if not content then fail(key .. "：askSync 失败 " .. tostring(err)) end
    if type(body) ~= "string" then
        fail(key .. "：没截获到请求体")
    else
        local ok_msg, messages = pcall(json.decode, body)
        local sys = (ok_msg and type(messages) == "table" and messages.messages
            and messages.messages[1] and messages.messages[1].content) or nil
        bodies[key] = sys
        local ins = Prompts.styleInstruction(key)
        if type(sys) == "string" and sys:find(ins, 1, true) then
            pass(key .. "：请求体里的 system 已带该风格指令")
        else
            fail(key .. "：请求体里没有该风格指令（Asker 没传 style？）")
        end
        if type(sys) == "string" and sys:find(Prompts.PERSONA_NAME, 1, true) then
            pass(key .. "：system 带角色名 " .. Prompts.PERSONA_NAME)
        else
            fail(key .. "：system 缺角色名")
        end
    end
end
print("")

print("========== 2. 7 份请求体两两不同（不是同一段） ==========")
local dup = 0
for i = 1, #order do
    for j = i + 1, #order do
        if bodies[order[i]] == bodies[order[j]] then
            dup = dup + 1
            fail(order[i] .. " 与 " .. order[j] .. " 的 system 完全相同")
        end
    end
end
if dup == 0 then pass("7 种风格两两不同，共 " .. tostring(#order * (#order - 1) / 2) .. " 组比对") end
print("")

print("========== 3. 缓存按风格分桶（换风格不会命中旧回答） ==========")
Cache:clear()
-- 同一句先用 professional 问一次，把结果写进缓存
local c1, _, c1_cache = ask_once("professional")
if c1_cache then fail("首次提问不该命中缓存") else pass("首次 professional 提问未命中缓存") end
local c2, _, c2_cache = ask_once("professional")
if c2_cache then pass("同样题同样风格：命中缓存（零 token，符合设计）")
else fail("同样题同样风格没命中缓存——缓存是不是坏了？") end
local c3, _, c3_cache = ask_once("snarky")
if c3_cache then
    fail("换成毒舌后仍然命中了专业风格的旧缓存（用户会以为设置没生效）")
else
    pass("换成毒舌后没有命中旧缓存，重新请求")
end
local c4, _, c4_cache = ask_once("snarky")
if c4_cache then pass("毒舌自己的结果也进了缓存")
else fail("毒舌二次提问没命中自己的缓存") end
print("")

print("========== 4. 非法风格值：链路不炸 ==========")
-- 必须换个没问过的问题：乱值会回落到 professional，与前面对 professional 用过的
-- 那句落在同一个缓存桶里；用同一个问题会直接命中缓存、不再发请求，
-- 于是根本截获不到请求体（这是探针自己的坑，不是产品行为）。
local c5, err5, _, body5
do
    Config:set("reply_style", "手改乱值")
    captured = nil
    c5, err5 = Asker:askSync({
        kind = "chat",
        book_fp = "e2e-book-fp",
        page_text = PAGE,
        selected = SELECTED,
        question = "换个没人问过的问题：这句话里的停顿说明了什么？",
        progress = { enabled = true, granularity = "chapter",
                     chapter_index = 3, chapter_total = 10 },
    })
    body5 = captured
end
if c5 then
    pass("乱值也能正常出结果（回落默认风格，不报错）")
    local ok_m, m = pcall(json.decode, body5)
    local sys = (ok_m and type(m) == "table" and m.messages and m.messages[1]
        and m.messages[1].content) or ""
    if sys:find(Prompts.styleInstruction(Prompts.STYLE_DEFAULT), 1, true) then
        pass("乱值时请求体回落到 " .. Prompts.STYLE_DEFAULT)
    else
        fail("乱值时请求体没回落")
    end
else
    fail("乱值导致 askSync 失败：" .. tostring(err5))
end
print("")

Config:set("reply_style", Prompts.STYLE_DEFAULT)
print("========== 结论 ==========")
if #failures == 0 then
    print("STYLE E2E OK")
    os.exit(0)
end
print(string.format("STYLE E2E FAILED：%d 项", #failures))
for i, m in ipairs(failures) do print("  - " .. m) end
os.exit(1)
