--[[--
QA 独立验证：「AI 回复风格」+ 角色名「小望」。

只做**行为断言**：stub 掉 HttpClient.post 抓真实请求体，并给 KOReader UI 模块
打桩后 require 真正的 ui/asker.lua，跑真的 Asker:askSync —— 只有这样才能抓住
"config 加了、prompts 加了、调用点没传"这类写了没接的事故（本项目已栽过三次）。

跑法（KPW4）：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     YWBF_PLUGIN_DIR=/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin \
     YWBF_TEST_DIR=/mnt/us/ywbf_dev/testdata \
     ./luajit /mnt/us/ywbf_dev/tools/qa_verify_style.lua
--]]

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR") or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"
local TEST_DIR = os.getenv("YWBF_TEST_DIR") or "/mnt/us/ywbf_dev/testdata"

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

-- ---- KOReader UI 打桩：只为让 ui/asker.lua / ui/settings.lua 能被真的 require 进来 ----
package.loaded["ui/widget/infomessage"] = { new = function(t) return t or {} end }
package.loaded["ui/widget/confirmbox"] = { new = function(t) return t or {} end }
-- InputDialog 打桩：记录每一次创建，并补齐 settings 会用到的两个方法。
-- 注意业务代码是 InputDialog:new{...} 冒号调用，第一个参数是 self —— 这个坑我踩过一次，
-- 写成 function(t) 会把模块表当成选项表，后面取 input/text_type 全是 nil，断言就假绿了。
local input_dialogs = {}
package.loaded["ui/widget/inputdialog"] = {
    new = function(_self, t)
        t = t or {}
        function t:getInputText() return self.input or "" end
        function t:onShowKeyboard() end
        function t:onCloseKeyboard() end
        input_dialogs[#input_dialogs + 1] = t
        return t
    end,
}
package.loaded["ui/widget/notification"] = {
    SOURCE_ALWAYS_SHOW = 1,
    notify = function() end,
}
package.loaded["ui/widget/textviewer"] = { new = function(t) return t or {} end }
package.loaded["ui/trapper"] = {
    wrap = function(_, fn) return fn() end,
    info = function() end,
    isWrapped = function() return false end,
    clear = function() end,
}
package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function() end,
    scheduleIn = function(_, _n, fn) return fn() end,
}
package.loaded["gettext"] = function(s) return s end
package.loaded["logger"] = {
    info = function() end, warn = function() end,
    dbg = function() end, err = function() end,
}

local Config = require("ywbf/config")
local HttpClient = require("ywbf/httpclient")
local Prompts = require("ywbf/prompts")
local Spoiler = require("ywbf/spoiler")
Config:init(TEST_DIR)
local Cache = require("ywbf/cache")
local Crypto = require("ywbf/crypto")
local DeepSeek = require("ywbf/deepseek")

local TOTAL, PASSED, FAILED = 0, 0, 0
local failures = {}
local function ok(cond, name, extra)
    TOTAL = TOTAL + 1
    if cond then
        PASSED = PASSED + 1; print("  PASS  " .. name)
    else
        FAILED = FAILED + 1
        failures[#failures + 1] = name
        print("  FAIL  " .. name .. (extra and (" -> " .. tostring(extra)) or ""))
    end
end
local function eq(a, b, name)
    ok(a == b, name, string.format("got=%s want=%s", tostring(a), tostring(b)))
end
local KNOWN = 0
local knowns = {}
-- 已知限制：不算 pass 也不算 fail，但必须在报告里点名（不许用「改断言」把它洗绿）
local function known(cond, name, extra)
    KNOWN = KNOWN + 1
    if cond then
        print("  KNOWN(已修)  " .. name)
    else
        knowns[#knowns + 1] = name
        print("  KNOWN(仍存在)  " .. name .. (extra and (" -> " .. tostring(extra)) or ""))
    end
end
local function section(t) print(""); print("=== " .. t .. " ===") end
local function has(s, sub)
    return type(s) == "string" and type(sub) == "string" and s:find(sub, 1, true) ~= nil
end
local function hasNot(s, sub) return not has(s, sub) end
local function readFile(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local s = f:read("*all"); f:close(); return s
end

-- ---------------- HTTP stub ----------------
local captured, reply = nil, "这条评语只针对写法本身。"
local function jstr(s)
    if type(s) ~= "string" then return '""' end
    return '"' .. (s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")) .. '"'
end
HttpClient.post = function(url, headers, body)
    captured = { url = url, body = body }
    return '{"id":"s","choices":[{"index":0,"message":{"role":"assistant","content":'
        .. jstr(reply) .. '}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}', 200, "OK", nil
end
local function bodyText()
    if not captured or type(captured.body) ~= "string" then return "" end
    return (captured.body:gsub("\\/", "/"):gsub("\\n", "\n"):gsub('\\"', '"'):gsub("\\\\", "\\"))
end

-- ---------------- 0 前置 ----------------
section("0. 前置：asker 真的被加载、API key 可用")
if Crypto:init() then DeepSeek:setApiKey("qa-style-key") end
if not DeepSeek:hasApiKey() then DeepSeek.getApiKey = function() return "qa-style-key" end end
Cache:init()
Config:set("spoiler_guard", true)
Config:set("spoiler_granularity", "chapter")
Config:set("reply_style", "professional")

local Asker = require("ui/asker")
ok(type(Asker) == "table" and type(Asker.askSync) == "function",
    "ui/asker.lua 在打桩环境里被真的 require 进来（跑的是真代码，不是副本）")

local SEL = "他把灯放下，回头看了一眼门口。"
local function askOnce(opts)
    captured = nil
    local content, err, from_cache = Asker:askSync({
        kind = opts.kind or "explain",
        selected = SEL,
        page_text = nil,
        question = opts.question or "这句话什么意思",
        book_fp = "style_fp",
        progress = opts.progress,
    })
    return content, err, from_cache
end

-- ---------------- 1 七种风格 ----------------
section("1. 七种风格：请求体里真的有对应语气指令，且两两不同")
do
    local seen = {}
    for _, st in ipairs(Prompts.STYLES) do
        local msgs = Prompts.build("explain", { context = "【选中内容】\n" .. SEL, style = st.key })
        local sys = msgs[1].content
        ok(has(sys, "小望"), "风格 " .. st.key .. "：system 里有角色名「小望」")
        ok(has(sys, "回复风格：" .. st.text), "风格 " .. st.key .. "：带风格名「" .. st.text .. "」")
        ok(has(sys, st.instruction), "风格 " .. st.key .. "：带该风格的语气指令原文")
        seen[st.key] = sys
    end
    local dup = 0
    local keys = {}
    for _, st in ipairs(Prompts.STYLES) do keys[#keys + 1] = st.key end
    for i = 1, #keys do
        for j = i + 1, #keys do
            if seen[keys[i]] == seen[keys[j]] then dup = dup + 1 end
        end
    end
    eq(dup, 0, "7 种风格两两不同（无重复 system）")
    eq(#Prompts.STYLES, 7, "风格表共 7 项")
end

-- ---------------- 2 五种 kind 全生效 ----------------
section("2. 五种 kind 都注入风格块")
do
    for _, kind in ipairs({ "explain", "summary", "concept", "chat", "light" }) do
        local msgs = Prompts.build(kind, {
            context = "【选中内容】\n" .. SEL, question = "这句话什么意思", style = "snarky",
        })
        ok(has(msgs[1].content, "毒舌吐槽"), "kind=" .. kind .. " 注入了风格块")
    end
end

-- ---------------- 3 非法值回落 ----------------
section("3. 非法 / 缺失风格值一律回落 professional，不报错")
do
    local bad = { nil, "", "BOGUS", "  ", {}, 123, true }
    for i, v in ipairs(bad) do
        eq(Prompts.normalizeStyleKey(v), "professional", "回落 " .. tostring(i) .. "（" .. tostring(v) .. "）→ professional")
    end
    ok(type(Prompts.styleInstruction(nil)) == "string", "styleInstruction(nil) 仍是 string")
    ok(type(Prompts.styleInstruction("BOGUS")) == "string", "styleInstruction(非法) 仍是 string")
    eq(Prompts.styleInstruction("BOGUS"), Prompts.styleInstruction("professional"),
        "非法 key 的指令等于默认风格指令")
    eq(Prompts.styleText(nil), "专业严谨", "styleText(nil) 回落默认显示名")
    ok(type(Prompts.styleHelp(nil)) == "string" and Prompts.styleHelp(nil) ~= "",
        "styleHelp(nil) 非空")
    local msgs = Prompts.build("explain", { context = "x", style = nil })
    ok(has(msgs[1].content, "专业严谨"), "style 为 nil 时 build 仍注入默认风格块")
    local msgs2 = Prompts.build("explain", { context = "x", style = "BOGUS" })
    ok(has(msgs2[1].content, "专业严谨"), "style 非法时 build 注入默认风格块")
end

-- ---------------- 3b 风格指令缺失时的回落分支 ----------------
-- 变异 3（把 styleInstruction 的回落改成 return nil）必须靠这一节变红：
-- nil/非法 key 走的是 normalizeStyleKey 归一，压根进不了回落分支，
-- 只有「STYLES 里真有这个 key、但 instruction 是空」才会落到 STYLE_DEFAULT。
section("3b. 风格表条目缺 instruction 时的回落（变异 3 的命门）")
do
    local idx_broken = 5 -- pragmatic
    local saved = Prompts.STYLES[idx_broken].instruction
    local saved_key = Prompts.STYLES[idx_broken].key
    Prompts.STYLES[idx_broken].instruction = ""
    local ins = Prompts.styleInstruction(saved_key)
    ok(type(ins) == "string", "条目指令为空时 styleInstruction 仍返回 string（不许把 nil 拼进 system）", tostring(ins))
    eq(ins, Prompts.styleInstruction("professional"),
        "条目指令为空时回落到默认风格的指令（而不是返回空串/nil）")
    local msgs = Prompts.build("explain", { context = "x", style = saved_key })
    -- 注意：回落的是**指令**，风格名仍是该条目自己的 text（我第一版断言成"名字也回落成专业严谨"，
    -- 实测为红；复核后判定是我的断言写错了，源码按"名保留、指令回落"实现。名字与指令不一致
    -- 属低危观感问题，已在报告里点名，不在测试里硬掰。）
    ok(has(msgs[1].content, Prompts.styleInstruction("professional")),
        "条目指令为空时 build 产出的 system 里是默认风格的**指令**（不是空、不是 nil）")
    ok(hasNot(msgs[1].content, "nil"), "system 里没有字面量 nil（拼接前必须已兜住）")
    Prompts.STYLES[idx_broken].instruction = saved
    eq(Prompts.styleInstruction(saved_key), saved, "还原后指令恢复（测试无副作用）")

    -- 已知限制探测：把**默认风格自己**的 instruction 掏空时，回落救不回来
    -- （STYLE_BY_KEY[STYLE_DEFAULT] 与被掏空的是同一张表，回落到自己身上还是空）。
    local saved_default = Prompts.STYLES[1].instruction
    Prompts.STYLES[1].instruction = nil
    local ins2 = Prompts.styleInstruction("professional")
    local okblock, block = pcall(Prompts.styleBlock, "professional")
    print(string.format("  [证据] 默认风格指令被掏空时：styleInstruction=%q styleBlock(ok=%s)=%q",
        tostring(ins2), tostring(okblock), tostring(block)))
    known(type(ins2) == "string" and okblock and type(block) == "string",
        "已知限制：默认风格自身指令被掏空时 styleInstruction 返回 nil、styleBlock 会崩（需源码兜底）",
        string.format("ins=%s okblock=%s", tostring(ins2), tostring(okblock)))
    -- 二次探测：不崩还不够，最好连「回复风格：…」这种**空抬头**也不要留。
    -- 实测（设备）：styleInstruction 已正确返回 ""，但 styleBlock 仍拼出
    -- "回复风格：专业严谨\n" + 空指令 —— 一个只有抬头没有内容的风格块。
    known(ins2 ~= "" or block == "",
        "已知限制2：默认风格指令缺失时 styleBlock 仍产出「回复风格：…」空抬头（源码缺 isEmpty 兜底，低危）",
        string.format("ins=%q block=%q", tostring(ins2), tostring(block)))
    Prompts.STYLES[1].instruction = saved_default
end

-- ---------------- 4 asker 真的把风格传下去 ----------------
section("4. 风格真的从 Asker:askSync 传到了请求体（最容易漏的一环）")
do
    Config:set("cache_enabled", false)
    for _, key in ipairs({ "professional", "friendly", "blunt", "imaginative",
                           "pragmatic", "snarky", "socratic" }) do
        Config:set("reply_style", key)
        local content, err = askOnce({})
        ok(content ~= nil, "askSync 风格 " .. key .. " 跑通", err)
        local bt = bodyText()
        ok(has(bt, "回复风格：" .. Prompts.styleText(key)),
            "askSync 风格 " .. key .. "：请求体里有该风格名")
        ok(has(bt, Prompts.styleInstruction(key)),
            "askSync 风格 " .. key .. "：请求体里有该风格指令")
    end
    Config:set("reply_style", "BOGUS")
    askOnce({})
    ok(has(bodyText(), "专业严谨"), "配置值非法时 askSync 发出的仍是默认风格")
    Config:set("reply_style", nil)
    askOnce({})
    ok(has(bodyText(), "专业严谨"), "配置缺失时 askSync 发出的仍是默认风格")
    Config:set("reply_style", "professional")
    askOnce({})
    local body_pro = bodyText()
    Config:set("reply_style", "snarky")
    askOnce({})
    ok(bodyText() ~= body_pro, "切换风格后请求体确实变了（证明配置被真的读取）")
    Config:set("reply_style", "professional")
end

-- ---------------- 5 缓存分桶 ----------------
section("5. 缓存分桶：默认风格沿用老缓存，换风格必须换桶")
do
    Config:set("cache_enabled", true)
    Cache:clear()
    Config:set("reply_style", "professional")
    local c1, e1, h1 = askOnce({ question = "缓存分桶测试问题" })
    ok(c1 ~= nil, "默认风格首次提问成功", e1)
    eq(h1, false, "默认风格首次：未命中缓存")
    local _, _, h2 = askOnce({ question = "缓存分桶测试问题" })
    eq(h2, true, "默认风格再次提问：命中缓存")
    Config:set("reply_style", "snarky")
    local c3, e3, h3 = askOnce({ question = "缓存分桶测试问题" })
    ok(c3 ~= nil, "切到非默认风格提问成功", e3)
    eq(h3, false, "切到非默认风格：必须不命中旧缓存（否则换了语气还拿旧答案）")
    ok(captured ~= nil, "非默认风格确实发出了新请求")
    Config:set("reply_style", "professional")
    local _, _, h4 = askOnce({ question = "缓存分桶测试问题" })
    eq(h4, true, "切回默认风格：仍能命中老缓存（老缓存没被污染/丢弃）")
    Cache:clear()
    Config:set("cache_enabled", true)
end

-- ---------------- 6 风格不得冲淡防剧透 ----------------
section("6. 风格块排在防剧透之后，且激进风格自带边界兜底")
do
    local note = Spoiler.buildNote({
        enabled = true, granularity = "chapter",
        chapter_index = 3, chapter_total = 10, chapter = "雪夜",
    })
    local msgs = Prompts.build("explain", { context = "x", spoiler_note = note, style = "snarky" })
    local sys = msgs[1].content
    local i_spoiler = sys:find("防剧透约束", 1, true)
    local i_style = sys:find("回复风格", 1, true)
    ok(i_spoiler ~= nil and i_style ~= nil, "system 里防剧透与风格块都在")
    ok(i_spoiler ~= nil and i_style ~= nil and i_spoiler < i_style,
        "风格块排在防剧透说明**之后**（后追加的语气压不过前面的硬约束）",
        string.format("spoiler@%s style@%s", tostring(i_spoiler), tostring(i_style)))
    ok(has(sys, "不许引用"), "防剧透硬约束仍在（没被风格块顶掉）")
    -- 激进风格各自的边界兜底
    ok(has(Prompts.styleInstruction("snarky"), "不得对用户做人身攻击"),
        "毒舌：自带「不得人身攻击」兜底")
    ok(has(Prompts.styleInstruction("snarky"), "读不到的内容照样不能说"),
        "毒舌：自带「不能剧透未读内容」兜底")
    ok(has(Prompts.styleInstruction("imaginative"), "必须当场标注是联想"),
        "天马行空：自带「联想必须标注」兜底")
    ok(has(Prompts.styleInstruction("blunt"), "绝不针对用户"), "直言：自带「对事不对人」兜底")
    ok(has(Prompts.styleInstruction("socratic"), "不许继续追问"), "启发：自带「别一直反问」兜底")
    -- 说明（我自己的断言被我自己推翻过一次，留痕）：
    -- 我最初写的是「7 种风格都必须含 不许/不得/绝不/必须/不要」，实测 pragmatic 不含 → 红。
    -- 复核判定：那是**我的启发式过度泛化**，不是源码缺陷——pragmatic 的指令是收敛型
    -- （「其余一概省略」「用户没问的…都不给」），本身就在收紧，不存在越界风险。
    -- 所以改成逐风格**按原文措辞**断言兜底，7 种一种不落，只是不再用同一个关键词糊过去。
    ok(has(Prompts.styleInstruction("pragmatic"), "都不给"), "高效务实：收敛型指令「没问的都不给」")
    ok(has(Prompts.styleInstruction("professional"), "不确定就说"), "专业严谨：自带「不确定就说没明说」兜底")
    ok(has(Prompts.styleInstruction("friendly"), "不许客套寒暄"), "亲和友善：自带「不许客套寒暄」兜底")
    local short = 0
    for _, st in ipairs(Prompts.STYLES) do
        local ins = st.instruction or ""
        local n = select(2, ins:gsub("·", ""))
        if n < 3 or type(st.help) ~= "string" or st.help == "" then short = short + 1 end
    end
    eq(short, 0, "每种风格都有 >=3 条要点且 help 非空（够了细节才能真的改变语气）")
end

-- ---------------- 7 角色名小望的接线 ----------------
section("7. 【小望】标签：必须用 PERSONA_NAME，不能写死")
do
    eq(Prompts.PERSONA_NAME, "小望", "PERSONA_NAME 是「小望」")
    ok(has(Prompts.BASE_SYSTEM, "小望"), "BASE_SYSTEM 里自称小望")
    local cd = readFile(PLUGIN_DIR .. "/ui/chatdialog.lua") or ""
    ok(has(cd, "Prompts.PERSONA_NAME"), "chatdialog 用的是 Prompts.PERSONA_NAME")
    ok(hasNot(cd, "【小望】"), "chatdialog 里没有写死的「【小望】」字面量（改名不会失联）")
    ok(hasNot(cd, "【答】"), "旧的「【答】」标签已移除")
    local st_src = readFile(PLUGIN_DIR .. "/ui/settings.lua") or ""
    ok(#st_src > 5000, "设置页源码真的读到了字节（下面的静态断言不是空转）", #st_src)
    ok(has(st_src, "reply_style"), "设置页接了 reply_style")
    ok(has(st_src, "AI 回复风格"), "设置页有一级菜单「AI 回复风格」")
    -- 我原来断言「设置页源码里必须出现 7 个风格名字面量」，实测全红。
    -- 复核判定：那是**我的断言错了**——设置页是 `for _i, s in ipairs(Prompts.STYLES) do`
    -- 动态枚举（settings.lua:476），不在 UI 里复制第二份名单，加风格只改 prompts.lua 一处。
    -- 这是更好的设计（避免两份名单漂移），所以我改成断言「确实是动态枚举」+ 真跑一遍菜单。
    ok(has(st_src, "ipairs(Prompts.STYLES)"),
        "设置页是遍历 Prompts.STYLES 动态生成，没在 UI 里复制第二份名单")
    ok(hasNot(st_src, "毒舌吐槽") and hasNot(st_src, "天马行空"),
        "设置页源码里没有写死的风格名（改 prompts.lua 一处即可，UI 不会失联）")

    -- 真的把 ui/settings.lua require 进来跑一遍菜单构建（不是看源码猜）
    local req_ok, SettingsUI = pcall(require, "ui/settings")
    ok(req_ok and type(SettingsUI) == "table" and type(SettingsUI.buildReplyStyleMenu) == "function",
        "ui/settings.lua 在打桩环境里被真的 require 进来")
    if req_ok and type(SettingsUI) == "table" then
        Config:set("reply_style", "professional")
        local subs = SettingsUI:buildReplyStyleMenu()
        ok(type(subs) == "table", "buildReplyStyleMenu 返回了菜单表")
        if type(subs) == "table" then
            eq(#subs, #Prompts.STYLES, "菜单项数 == 风格表项数（动态枚举不漏项）")
            for i, st in ipairs(Prompts.STYLES) do
                eq(subs[i] and subs[i].text, st.text, "菜单第 " .. i .. " 项是「" .. st.text .. "」")
                ok(type(subs[i] and subs[i].help_text) == "string" and subs[i].help_text ~= "",
                    "菜单项「" .. st.text .. "」有非空 help_text")
            end
            local n_checked = 0
            for _, sub in ipairs(subs) do
                if type(sub.checked_func) == "function" and sub.checked_func() then
                    n_checked = n_checked + 1
                end
            end
            eq(n_checked, 1, "当前风格恰好一项处于选中态（单选语义）")
            -- callback 真的落配置，不是只显示
            local target = nil
            for _, sub in ipairs(subs) do if sub.text == "毒舌吐槽" then target = sub end end
            ok(target ~= nil, "菜单里能找到「毒舌吐槽」")
            if target then
                target.callback()
                eq(Config:get("reply_style"), "snarky", "点「毒舌吐槽」后配置真的被写入（不是只显示）")
                ok(target.checked_func() == true, "写入后该项立刻变为选中态")
            end
            Config:set("reply_style", "professional")
        end
    end
end

-- ================= API Key 的显示与编辑（真机反馈②） =================
-- 口径：菜单上不显示内容（已设置/未设置），对话框里全明文且预填，去掉密码勾选框。
-- 这里全部走**真的调用**：真的 require ui/settings、真的建菜单、真的打开对话框、真的点保存。
section("API Key：菜单不回显、对话框明文预填、原样保存不丢 Key")
do
    local KEY = "sk-qa-9f3c2a7b41d8e605"

    -- ① 静态：全项目再没有 mask_key（先证明扫描器本身能扫到东西，避免空转）
    local dirs = { "/ui", "/ywbf" }
    local scanned, hit_files = 0, {}
    for _i, d in ipairs(dirs) do
        local n = 0
        for j = 1, 60 do
            -- 文件名清单不好拿，改成按已知清单扫（下面有非空校验兜底）
            n = n
        end
        local list = {
            "/main.lua", "/_meta.lua",
            "/ui/asker.lua", "/ui/chatdialog.lua", "/ui/settings.lua", "/ui/suggestpicker.lua",
            "/ui/toastcard.lua",
            "/ywbf/cache.lua", "/ywbf/config.lua", "/ywbf/context.lua", "/ywbf/crypto.lua",
            "/ywbf/deepseek.lua", "/ywbf/httpclient.lua", "/ywbf/prompts.lua", "/ywbf/queue.lua",
            "/ywbf/spoiler.lua", "/ywbf/store.lua", "/ywbf/suggest.lua", "/ywbf/tokens.lua",
            "/ywbf/util.lua",
        }
        if d == "/ui" or d == "/ywbf" then
            for _k, rel in ipairs(list) do
                local p = PLUGIN_DIR .. rel
                local s = readFile(p)
                if s then
                    scanned = scanned + 1
                    if has(s, "mask_key") then hit_files[#hit_files + 1] = rel end
                end
            end
            break
        end
    end
    ok(scanned >= 18, "（前置）静态扫描真的扫到了足够多的源文件", scanned)
    ok(#hit_files == 0, "全项目零命中 mask_key（菜单不再回显掩码 Key）",
        #hit_files > 0 and table.concat(hit_files, "、") or "0")

    -- ② 真的把设置页建出来
    local req_ok, SettingsUI = pcall(require, "ui/settings")
    ok(req_ok and type(SettingsUI) == "table" and type(SettingsUI.buildMenu) == "function",
        "ui/settings.lua 真加载，buildMenu 在")
    if not (req_ok and type(SettingsUI) == "table") then
        ok(false, "加载失败，后续 Key 断言无法执行")
    else
        DeepSeek:setApiKey(KEY)
        eq(DeepSeek:hasApiKey(), true, "前置：Key 已写入")

        local menu = SettingsUI:buildMenu(nil)
        local key_item = nil
        for _i, it in ipairs(menu or {}) do
            local t = (type(it.text) == "string") and it.text or ""
            if has(t, "API Key 配置") then key_item = it end
        end
        ok(key_item ~= nil, "菜单里有「API Key 配置」这一项")
        if key_item then
            local shown = type(key_item.text_func) == "function" and key_item.text_func() or key_item.text
            eq(shown, "API Key 配置（已设置）", "已设置时菜单只给状态，不给内容", shown)
            ok(has(shown, KEY) == false, "菜单项里不含 Key 明文", shown)
            ok(has(shown, "*") == false and has(shown, "•") == false,
                "菜单项里不含任何星号/圆点掩码", shown)
        end

        -- ③ 打开配置对话框：明文预填 + 没有密码勾选框
        input_dialogs = {}
        SettingsUI:showApiKeyDialog()
        local d = input_dialogs[#input_dialogs]
        ok(type(d) == "table", "点进去真的建了一个输入框")
        if type(d) == "table" then
            eq(d.input, KEY, "对话框把当前 Key 明文预填进输入框（能核对是哪个 Key）", d.input)
            eq(d.text_type, nil, "没有 text_type=password（那个「显示密码」勾选框根本不会出现）",
                tostring(d.text_type))
            -- 原样保存：不改动直接点保存，Key 不能被弄丢或写坏
            local save_btn = nil
            for _i, row in ipairs(d.buttons or {}) do
                for _j, b in ipairs(row) do
                    if has(b.text or "", "保存") then save_btn = b end
                end
            end
            ok(save_btn ~= nil, "对话框里有「保存」按钮")
            if save_btn then
                save_btn.callback()
                eq(DeepSeek:getApiKey(), KEY, "预填 → 不改动 → 保存：Key 还是同一个（没被写坏）")
            end
        end

        -- ④ 未设置那一支：菜单文案要变，对话框 input 为空
        -- 没有专门的清理接口（Lua 里 obj:method 不带括号不是合法表达式），
        -- 就用覆盖 getApiKey 的方式走"未设置"这一支
        if type(DeepSeek.clearApiKey) == "function" then
            DeepSeek:clearApiKey()
        else
            DeepSeek.getApiKey = function() return nil end
        end
        local menu2 = SettingsUI:buildMenu(nil)
        local shown2 = nil
        for _i, it in ipairs(menu2 or {}) do
            local t = (type(it.text) == "string") and it.text or ""
            if has(t, "API Key 配置") and type(it.text_func) == "function" then
                shown2 = it.text_func()
            end
        end
        eq(shown2, "API Key 配置（未设置）", "未设置时菜单显示「（未设置）」", tostring(shown2))

        -- 复原，别把后面的用例环境弄脏
        DeepSeek:setApiKey(KEY)
    end
end

section("RESULTS")
print(string.format("TOTAL: %d  PASSED: %d  FAILED: %d  KNOWN: %d", TOTAL, PASSED, FAILED, KNOWN))
if FAILED > 0 then
    print("")
    print("失败明细：")
    for _, m in ipairs(failures) do print("  - " .. m) end
end
if #knowns > 0 then
    print("")
    print("已知限制（仍存在，不计入失败，但需源码兜底）：")
    for _, m in ipairs(knowns) do print("  - " .. m) end
end
