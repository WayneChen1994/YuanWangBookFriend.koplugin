--[==[
QA 独立验证：**收藏与回顾（阶段一）**。

范围（团队 2026-09-20 划定，只验这些）：
  1. Store 条目扩展 + **向后兼容**（老数据缺字段也要能读、能列、能搜，不许抛异常）；
  2. setFavorite / listFavorites（fp 为 nil 时跨书）/ search 同时命中 selection 与 question / 书名索引 books.json；
  3. kind == "ideas" 不参与收藏；
  4. showLastReply() 内存为空时回退读 Store 当前书最后一条 assistant。
阶段二（备注/标签、导出、时间与风格筛选）**不写断言**——没实现就写断言等于空转。

三条硬规矩：
  · **必须走"真的落盘再读回"**：判断"收藏仍在"要以**直接 json.decode 磁盘文件**为证据，
    并且把模块 `package.loaded` 清掉重新 require（模拟关书/重启），不能只看内存。
  · **每条"某物必须存在"的断言都配前置/对照组**（本项目通用判据）：
    例如"搜引用段落能命中"要配"这个 token 确实不在 content 里"，
    "列表项提问不为空"要配一条**没有配对 user 条目**的样本 → 它的提问**必须为空**。
  · **红色也不许撒谎**：驱动不到、接口还没有的地方一律 `SKIP`（单独计数，不算通过），
    绝不用实现细节的变化假装成绿。

跑法（KPW4）：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     YWBF_PLUGIN_DIR=/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin \
     YWBF_FAV_DIR=/mnt/us/ywbf_dev/fav_data \
     ./luajit /mnt/us/ywbf_dev/tools/qa_verify_favorites.lua
--]==]

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR") or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"
-- 测试目录独立：绝不碰用户真机上的 data/（临时文件只允许落在 /mnt/us/ywbf_dev 内）
local TEST_DIR = os.getenv("YWBF_FAV_DIR") or "/mnt/us/ywbf_dev/fav_data"

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

-- ================= KOReader UI 打桩（记录型） =================
local viewers, notifies, dialogs = {}, {}, {}
package.loaded["ui/widget/infomessage"] = { new = function(_s, t) return t or {} end }
package.loaded["ui/widget/confirmbox"] = { new = function(_s, t) return t or {} end }
local input_dialogs = {}
package.loaded["ui/widget/inputdialog"] = {
    new = function(_s, t)
        t = t or {}
        function t:getInputText() return self.input or "" end
        function t:onShowKeyboard() end
        function t:onClose() end
        input_dialogs[#input_dialogs + 1] = t
        return t
    end,
}
-- suggestpicker 会 require 它，缺了整条链起不来（打桩不全 = SKIP，不算通过）
package.loaded["ui/widget/buttondialog"] = {
    new = function(_s, t) return { buttons = type(t) == "table" and t.buttons or {} } end,
}
-- TextViewer 桩不只是"记下来"：结果卡片上的收藏按钮要靠 button_table:getButtonById 取回、
-- 改文字。桩提供同名的取回口子，并把按钮摊平成 _buttons，测试才能**真的点一下**——
-- 只看"卡片建出来了"等于没验（团队口径：按钮上写着什么，点下去就得发生什么）。
package.loaded["ui/widget/textviewer"] = {
    new = function(_s, t)
        t = t or {}
        local by_id, flat = {}, {}
        local rows = t.buttons_table
        if type(rows) == "table" then
            for _r, row in ipairs(rows) do
                if type(row) == "table" then
                    for _c, b in ipairs(row) do
                        if type(b) == "table" then
                            b.label = b.text          -- 记住初始文字，setText 之后还能比对
                            function b:setText(s) b.text = s end
                            function b:getText() return b.text end
                            flat[#flat + 1] = b
                            if b.id then by_id[b.id] = b end
                        end
                    end
                end
            end
        end
        t._buttons = flat
        t.button_table = { getButtonById = function(_self, id) return by_id[id] end }
        viewers[#viewers + 1] = t
        return t
    end,
}
package.loaded["ui/widget/buttondialog"] = { new = function(_s, t) return t or {} end }
-- Menu 也要打桩：真 Menu 会把 frontend/dbg 那条链一起拉起来（dbg.lua:67 会去索引
-- logger.levels）。收藏列表就是拿 Menu 拼的，桩只要能把 item_table 交出来就够断言了。
package.loaded["ui/widget/menu"] = { new = function(_s, t) return t or {} end }
package.loaded["ui/widget/notification"] = {
    SOURCE_ALWAYS_SHOW = 1,
    notify = function(_s, text) notifies[#notifies + 1] = tostring(text) end,
}
package.loaded["ui/uimanager"] = {
    show = function(_s, w) if type(w) == "table" then dialogs[#dialogs + 1] = w end end,
    close = function() end,
    scheduleIn = function(_s, _n, fn) return fn() end,
}
package.loaded["ui/trapper"] = {
    wrap = function(_s, fn) return fn() end, info = function() end,
    isWrapped = function() return false end, clear = function() end,
}
package.loaded["device"] = { screen = nil }
package.loaded["ui/font"] = { getFace = function() return {} end }
package.loaded["ui/size"] = { padding = { large = 1 }, margin = { small = 1 } }
package.loaded["ui/rendertext"] = { sizeUtf8Text = function() return { x = 0 } end }
package.loaded["gettext"] = setmetatable({}, { __call = function(_s, s) return s end })
package.loaded["logger"] = {
    info = function() end, warn = function() end,
    dbg = function() end, err = function() end,
    -- 真模块（frontend/dbg.lua 之类）会来索引 logger.levels，缺了它 require 就断在半路
    levels = { dbg = 1, info = 2, warn = 3, err = 4 },
}
package.loaded["dispatcher"] = { registerAction = function() end }
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(_s, t) return t or {} end,
    new = function(_s, t) return t or {} end,
}

local Config = require("ywbf/config")
Config:init(TEST_DIR)
Config:set("cache_enabled", true)
Config:set("spoiler_guard", true)
Config:set("spoiler_granularity", "chapter")
Config:set("reply_style", "professional")
local json = require("json")
local Util = require("ywbf/util")
-- 网络与 Key 打桩：本脚本只验持久化，**不发起任何真实请求、更不会花钱**。
-- 缓存命中那一段要靠它：先塞缓存、再让它"命中"，全程不碰网络。
local HttpClient = require("ywbf/httpclient")
HttpClient.post = function(_url, _headers, _body)
    local j = require("json")
    return j.encode({
        choices = { { message = { content = "（QA 桩回复）" }, finish_reason = "stop" } },
        usage = { prompt_tokens = 1, completion_tokens = 1, total_tokens = 2 },
    }), 200, "OK", nil
end
local Crypto = require("ywbf/crypto")
local DeepSeek = require("ywbf/deepseek")
if Crypto:init() then DeepSeek:setApiKey("qa-fav-key") end
if not DeepSeek:hasApiKey() then DeepSeek.getApiKey = function() return "qa-fav-key" end end
local Store = require("ywbf/store")

-- ================= 断言骨架 =================
local TOTAL, PASSED, FAILED, SKIPPED = 0, 0, 0, 0
local function ok(cond, name, extra)
    TOTAL = TOTAL + 1
    if cond then PASSED = PASSED + 1; print("  PASS  " .. name)
    else
        FAILED = FAILED + 1
        print("  FAIL  " .. name .. (extra and (" -> " .. tostring(extra)) or ""))
    end
end
-- SKIP：接口还没有 / 驱动不到。**不计入通过**，避免用"跑不到"冒充绿。
local function skip(name, why)
    SKIPPED = SKIPPED + 1
    print("  SKIP  " .. name .. " -> " .. tostring(why))
end
local function callp(fn, name, ...)
    local oks, r1, r2, r3 = pcall(fn, ...)
    ok(oks, name, oks and nil or r1)
    return oks, r1, r2, r3
end
local function section(t) print(""); print("=== " .. t .. " ===") end
local function has(s, sub)
    return type(s) == "string" and type(sub) == "string" and sub ~= "" and s:find(sub, 1, true) ~= nil
end
local function hasNot(s, sub) return not has(s, sub) end
local function readFile(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local s = f:read("*all"); f:close(); return s
end
local function writeFile(p, s)
    local f = io.open(p, "wb"); if not f then return false end
    f:write(s); f:close(); return true
end
-- 重新 require：模拟"关书/重启"后内存状态全丢，只有磁盘上的东西是真的
local function freshStore()
    package.loaded["ywbf/store"] = nil
    local S = require("ywbf/store")
    return S
end
local function rawEntries(fp)
    local raw = readFile(Config.paths.history .. "/" .. fp .. ".json")
    if not raw or #raw == 0 then return nil end
    local okd, dec = pcall(json.decode, raw)
    if not (okd and type(dec) == "table") then return nil end
    return dec.entries or {}
end

-- ================= 夹具 =================
-- 三本书：A = 纯老格式（真机用户攒下的历史就是这个形状）、B = 新格式、C = 用来验跨书
local FP_A, FP_B, FP_C = "qa_fav_old", "qa_fav_new", "qa_fav_other"
local SEL_A = "雪停了，铁马不再作响的那一夜，他却偏偏提起了灯。"   -- token「铁马」只在 selection 里
local SEL_B = "橙黄的灯芯爆了一下，屋里的人都屏住了呼吸。"        -- token「橙黄」只在 selection 里
local Q_B   = "他为什么偏偏此时提灯？"                             -- 这一条是**真实形状**：user 条目的 content 就是提问
-- 下面这个是**只存在于 question 字段**的提问：对应的 user 条目已经被删掉了
-- （Store:delete 支持删单条，用户清理历史后就是这个形状）。
-- 为什么非要造这么一条：如果提问同时也出现在某个条目的 content 里，
-- 那么"只搜 content"的实现也能命中它，那条断言就成了空转 —— 分不出真假。
local Q_SOLO = "哑巴仆人为何偏偏选中这一夜？"
local A_B   = "因为灯是他唯一答得出口的话。"

local function buildFixtures()
    local oldA = {
        entries = {
            { role = "user",      content = "他为什么偏偏此时提灯？", kind = "chat", selection = SEL_A, ts = 1000 },
            { role = "assistant", content = A_B,                      kind = "chat", selection = SEL_A, ts = 1001 },
        },
    }
    local newB = {
        entries = {
            { role = "user", content = Q_B, kind = "chat", selection = SEL_B, ts = 2000,
              turn_id = "t1", question = Q_B, book_fp = FP_B, book_title = "《灯下漫笔》",
              chapter_title = "第三章 孤灯", chapter_index = 3, page = 42, style = "professional", favorite = false },
            { role = "assistant", content = "《灯下漫笔》第三章的这段点亮了整篇的线索。", kind = "chat",
              selection = SEL_B, ts = 2001, turn_id = "t1", book_fp = FP_B,
              book_title = "《灯下漫笔》", chapter_title = "第三章 孤灯", chapter_index = 3, page = 42,
              style = "professional", favorite = false },
            -- 对照组：这条 assistant **没有配对的 user 条目**，它的提问必须是空的
            { role = "assistant", content = "这条回答没有配对的提问。", kind = "chat",
              selection = SEL_B, ts = 2002, turn_id = "t_orphan", book_fp = FP_B,
              book_title = "《灯下漫笔》", chapter_title = "第三章 孤灯", favorite = false },
            -- ideas 条目：即使被人手工标了 favorite，也不许出现在收藏列表里
            { role = "assistant", content = "他为何偏偏此时提灯？", kind = "ideas",
              selection = SEL_B, ts = 2003, book_fp = FP_B, book_title = "《灯下漫笔》", favorite = true },
            -- 提问只存在于 question 字段的那一条（对应 user 条目已被删掉）
            { role = "assistant", content = "这条回答的提问只留在 question 字段里。", kind = "chat",
              selection = SEL_B, ts = 2004, turn_id = "t_solo", question = Q_SOLO, book_fp = FP_B,
              book_title = "《灯下漫笔》", chapter_title = "第三章 孤灯", favorite = false },
        },
    }
    local otherC = {
        entries = {
            { role = "user",      content = "另一本书的提问",   kind = "chat", selection = SEL_B, ts = 3000,
              turn_id = "c1", question = "另一本书的提问", book_fp = FP_C, book_title = "《寒砧集》", favorite = false },
            { role = "assistant", content = "另一本书的回答。", kind = "chat", selection = SEL_B, ts = 3001,
              turn_id = "c1", book_fp = FP_C, book_title = "《寒砧集》", favorite = false },
        },
    }
    return {
        { fp = FP_A, data = oldA,   legacy = true  },
        { fp = FP_B, data = newB,   legacy = false },
        { fp = FP_C, data = otherC, legacy = false },
    }
end

section("0. 前置：夹具落盘、样本本身站得住")
local fixtures = buildFixtures()
for _i, fx in ipairs(fixtures) do
    local okw = writeFile(Config.paths.history .. "/" .. fx.fp .. ".json", json.encode(fx.data))
    ok(okw, "0：夹具 " .. fx.fp .. " 写进测试目录了（写不进去下面全是假绿）")
end
-- 老格式样本的**自检**：它必须真的没有那些新字段，否则"兼容"那几条就是空转
do
    local es = rawEntries(FP_A)
    ok(type(es) == "table" and #es >= 2, "0：（前置）老格式样本读得回来、至少 2 条", es and #es)
    if type(es) == "table" and es[1] then
        ok(es[1].turn_id == nil and es[1].favorite == nil and es[1].book_title == nil
            and es[1].chapter_title == nil and es[1].question == nil,
            "0：（夹具自检）老格式样本确实**没有** turn_id/favorite/book_title/chapter_title/question（这条不成立的话，兼容断言全是空转）")
    end
    -- 检索用的三个 token 必须各在其位。**按字段扫全表**，不靠肉眼看字符串：
    -- 只要 token 出现在任何条目的 content 里，"只搜 content"的实现就能蒙混过关，
    -- 那几条断言就全成空转了。
    local function fieldHas(entries, field, token)
        for _i, e in ipairs(type(entries) == "table" and entries or {}) do
            if type(e) == "table" and has(e[field], token) then return true end
        end
        return false
    end
    local all_entries = {}
    for _i, fx in ipairs(fixtures) do
        local es = rawEntries(fx.fp)
        for _j, e in ipairs(type(es) == "table" and es or {}) do all_entries[#all_entries + 1] = e end
    end
    ok(#all_entries >= 8, "0：（前置）三本书的夹具条目都读得回来（读不回来下面全是假绿）", #all_entries)
    ok(has(SEL_A, "铁马") and not fieldHas(all_entries, "content", "铁马"),
        "0：（夹具自检）「铁马」只出现在引用段落里，没有任何条目的 content 含它")
    ok(has(SEL_B, "橙黄") and not fieldHas(all_entries, "content", "橙黄"),
        "0：（夹具自检）「橙黄」只出现在引用段落里，没有任何条目的 content 含它")
    ok(has(Q_SOLO, "哑巴仆人")
        and not fieldHas(all_entries, "content", "哑巴仆人")
        and not fieldHas(all_entries, "selection", "哑巴仆人"),
        "0：（夹具自检）「哑巴仆人」只出现在 question 字段里，没有任何条目的 content/selection 含它")
    ok(fieldHas(all_entries, "question", "哑巴仆人"),
        "0：（夹具自检）「哑巴仆人」确实在某个条目的 question 字段里（否则上面那条就是空转）")
end

-- ================= 1 老数据兼容 =================
section("1. 老数据兼容：只有 {role,content,kind,selection,ts} 的历史不许崩")
do
    local oks, list = pcall(function() return Store:list(FP_A) end)
    ok(oks and type(list) == "table", "1：list(老数据) 不抛异常", list)
    if oks and type(list) == "table" then
        ok(#list >= 2, "1：老数据的条目数没变（读回来了）", #list)
    end
    callp(function() return Store:search("偏偏", FP_A) end, "1：search(老数据) 不抛异常")
    if type(Store.setFavorite) == "function" then
        -- 给一条**老数据**条目打收藏：不能因为缺字段就炸，也不能丢东西
        local okf, res = pcall(function() return Store:setFavorite(FP_A, 2, true) end)
        ok(okf, "1：setFavorite(老数据条目) 不抛异常（缺字段不许炸）", res)
        -- **顺序不能反**：必须先给老数据打上收藏，再列收藏列表。
        -- 一条都没收藏时 listFavorites 根本不会走到 toRow，那条断言是空转——
        -- 我第一版就是这么写的，M4（toRow 里直接拼缺少的字段）竟然没把它打红。
        if type(Store.listFavorites) == "function" then
            callp(function() return Store:listFavorites(FP_A) end,
                "1：listFavorites(老数据) 不抛异常（**已收藏**之后列，否则 toRow 压根走不到）")
            local rowsA = nil
            pcall(function() rowsA = Store:listFavorites(FP_A) end)
            ok(type(rowsA) == "table" and #rowsA >= 1,
                "1：（前置）老数据那条确实被列出来了（列不出来，上面那条又是空转）",
                type(rowsA) == "table" and #rowsA or tostring(rowsA))
        else
            skip("1：listFavorites(老数据) 不抛异常", "Store.listFavorites 接口还没落地")
        end
        local before = rawEntries(FP_A)
        ok(type(before) == "table" and #before >= 2,
            "1：setFavorite 之后老数据的条目没被删掉（也不能被改写成只剩新字段）", before and #before)
        if type(before) == "table" and before[2] then
            ok(before[2].role == "assistant" and before[2].content == A_B,
                "1：老条目的既有字段（role/content）原样保留，没有被覆盖成默认值",
                before[2].content)
        end
    else
        skip("1：setFavorite(老数据条目)", "Store.setFavorite 接口还没落地")
    end
end

-- ================= 2 收藏必须真的落盘 =================
section("2. 收藏落盘：磁盘文件才有资格说话（内存不算）")
do
    if type(Store.setFavorite) ~= "function" or type(Store.listFavorites) ~= "function" then
        skip("2：收藏落盘与重新加载", "setFavorite / listFavorites 还没落地")
    else
        -- 取消上一节在 A 上打的那条，从干净状态开始
        local idxA = 2
        local idxB = 2   -- 书 B 第 2 条 = 有配对提问的 assistant
        callp(function() return Store:setFavorite(FP_A, idxA, false) end, "2：（准备）先把 A 上的收藏清掉")
        callp(function() return Store:setFavorite(FP_B, idxB, false) end, "2：（准备）先把 B 上的收藏清掉")

        callp(function() return Store:setFavorite(FP_B, idxB, true) end, "2：setFavorite 不抛异常")
        -- ① 直接读磁盘： favorite 必须是 true（这是"真的落盘了"的唯一硬证据）
        local disk = rawEntries(FP_B)
        ok(type(disk) == "table" and disk[idxB] and disk[idxB].favorite == true,
            "2①：磁盘文件里 favorite == true（不是只改了内存）",
            disk and disk[idxB] and tostring(disk[idxB].favorite))
        -- ② 重新 require（模拟关书/重启）后仍然收藏
        local S2 = freshStore()
        local fav2 = S2:listFavorites(FP_B)
        local hit2 = 0
        for _i, e in ipairs(type(fav2) == "table" and fav2 or {}) do
            if e and e.ts == 2001 then hit2 = hit2 + 1 end
        end
        ok(hit2 == 1, "2②：清掉模块状态重新 require 后，这条仍然在收藏里（关书/重启不丢）", hit2)

        -- ③ 取消收藏 → 磁盘与重载都消失
        callp(function() return Store:setFavorite(FP_B, idxB, false) end, "2：取消收藏不抛异常")
        local disk3 = rawEntries(FP_B)
        local still = disk3 and disk3[idxB] and disk3[idxB].favorite == true
        ok(still == false, "2③：磁盘文件里 favorite 不再是 true（取消也真的落盘了）",
            disk3 and disk3[idxB] and tostring(disk3[idxB].favorite))
        local S3 = freshStore()
        local fav3 = S3:listFavorites(FP_B)
        local hit3 = 0
        for _i, e in ipairs(type(fav3) == "table" and fav3 or {}) do
            if e and e.ts == 2001 then hit3 = hit3 + 1 end
        end
        ok(hit3 == 0, "2③：重新 require 后不再出现在收藏里", hit3)
    end
end

-- ================= 3 跨书 listFavorites =================
section("3. 跨书收藏：fp 为 nil 时必须把各书的收藏都带出来")
do
    if type(Store.listFavorites) ~= "function" or type(Store.setFavorite) ~= "function" then
        skip("3：跨书收藏列表", "接口还没落地")
    else
        callp(function() return Store:setFavorite(FP_B, 2, true) end, "3：（准备）收藏书 B 一条")
        callp(function() return Store:setFavorite(FP_C, 2, true) end, "3：（准备）收藏书 C 一条")
        local S = freshStore()
        local all = S:listFavorites(nil)
        ok(type(all) == "table", "3：listFavorites(nil) 返回表", all)
        local fps, b_ok, c_ok = {}, false, false
        for _i, e in ipairs(type(all) == "table" and all or {}) do
            if e and e.book_fp == FP_B then b_ok = true end
            if e and e.book_fp == FP_C then c_ok = true end
            if e and e.book_fp then fps[e.book_fp] = true end
        end
        ok(b_ok and c_ok, "3：跨书列表里同时有书 B 和书 C 的收藏（fp=nil 真的跨书）")
        -- 每条都要能拿回书名（老数据没有就给回退值，但不许是 nil/空串）
        local bad_title = nil
        for _i, e in ipairs(type(all) == "table" and all or {}) do
            if not (type(e.book_title) == "string" and e.book_title ~= "") then bad_title = tostring(e.book_title) end
        end
        ok(bad_title == nil, "3：每条收藏都带得回书名（老数据也要有回退值，不许 nil/空串）", bad_title)
        -- 清场
        callp(function() Store:setFavorite(FP_B, 2, false) end, "3：（清场）")
        callp(function() Store:setFavorite(FP_C, 2, false) end, "3：（清场）")
    end
end

-- ================= 4 ideas 不参与收藏 =================
-- 需求原文（docs/FEATURE_NOTES.md:42）：「AI 出题（kind = ideas）不进历史（已有约定），
-- **因此**也不参与收藏。」——不参与收藏是"不进历史"的**推论**，不是另一条独立要求。
-- 所以要钉两层：
--   4①/4② **可达的那层**：真的走一次 ideas，历史里不许新增任何条目（推论的前提）；
--   4③      **纵深防御那层**：万一历史里真躺着一条 favorite 的 ideas，列表也不该列它。
-- 4③ 目前红。我把证据一起打出来（真机 history 里 ideas 条目数 = 0、唯一 append 入口
-- 已被 `kind ~= "ideas"` 挡住），裁定权交团队——但**不删这条断言**。
section("4. kind == ideas 不参与收藏（先钉可达的「不进历史」，再钉纵深防御）")
do
    local FP_F = "qa_fav_ideas"
    local oka, Asker4 = pcall(require, "ui/asker")
    if not (oka and type(Asker4) == "table" and type(Asker4.askSync) == "function") then
        skip("4①：ideas 不进历史", "ui/asker 起不来 -> " .. tostring(Asker4))
    else
        local C4 = require("ywbf/cache")
        pcall(function() return C4:init() end)
        pcall(function() return C4:clear() end)          -- 别让上一节的缓存把这一轮变成命中
        callp(function() return Store:clear(FP_F) end, "4：（准备）清掉 F 书")
        local ok_i, res_i, err_i = pcall(function()
            return Asker4:askSync({
                kind = "ideas", selected = "他要问的那一段。", page_text = "他要问的那一段。",
                book_fp = FP_F, progress = { chapter = 1, total = 10 },
            })
        end)
        ok(ok_i, "4①：ideas 这一轮不抛异常", err_i)
        ok(ok_i and type(res_i) == "string" and res_i ~= "",
            "4①：（前置）ideas 这一轮真的拿到了内容（拿不到的话「没写历史」就是假绿）",
            ok_i and tostring(res_i))
        local after_i = rawEntries(FP_F) or {}
        ok(#after_i == 0,
            "4①：ideas 那一轮**没有往历史里写任何条目**（FEATURE_NOTES:42 的约定）",
            "#entries=" .. tostring(#after_i))
        -- 反向对照：同样的调用换成 explain 就必须写进去。
        -- 没有这条，"0 条"可能只是 append 坏了 / 这一轮根本没走到写入分支。
        local ok_x = pcall(function()
            return Asker4:askSync({
                kind = "explain", selected = "他要问的那一段。", page_text = "他要问的那一段。",
                book_fp = FP_F, progress = { chapter = 1, total = 10 },
            })
        end)
        ok(ok_x, "4②：（对照）explain 那一轮不抛异常", nil)
        local after_x = rawEntries(FP_F) or {}
        ok(#after_x >= 1,
            "4②：（对照）同样的调用换成 explain 就**写进历史**了——证明 4① 的 0 条是约定生效，不是写入坏了",
            "#entries=" .. tostring(#after_x))
        pcall(function() return C4:clear() end)
        callp(function() return Store:clear(FP_F) end, "4：（清场）")
    end

    if type(Store.listFavorites) ~= "function" then
        skip("4③：脏数据里的 ideas 不进收藏列表", "listFavorites 还没落地")
    else
        local raw = rawEntries(FP_B)
        local ideas_idx = nil
        for i, e in ipairs(type(raw) == "table" and raw or {}) do
            if e and e.kind == "ideas" then ideas_idx = i end
        end
        ok(ideas_idx ~= nil and raw[ideas_idx].favorite == true,
            "4③：（前置）夹具里那条 ideas **已经被标了 favorite**（这条不成立，下面那条就是空转）",
            ideas_idx)
        local S = freshStore()
        local favs = S:listFavorites(nil)
        local leaked = false
        for _i, e in ipairs(type(favs) == "table" and favs or {}) do
            if e and e.kind == "ideas" then leaked = true end
        end
        ok(leaked == false,
            "4③：【纵深防御】收藏列表里没有任何 kind == ideas 的条目"
            .. "（store.lua:327 的守卫；它防的是阶段二 append 入口变多之后的脏数据，不是今天的真实数据）")
    end
end

-- ================= 5 问答成对 =================
section("5. 问答成对：列表项里的提问不许为空（并配一条必须为空的对照）")
do
    if type(Store.setFavorite) ~= "function" or type(Store.listFavorites) ~= "function" then
        skip("5：问答成对", "接口还没落地")
    else
        callp(function() return Store:setFavorite(FP_B, 2, true) end, "5：（准备）收藏有配对的那条 assistant")
        callp(function() return Store:setFavorite(FP_B, 3, true) end, "5：（准备）收藏那条没有配对的 assistant")
        local S = freshStore()
        local favs = S:listFavorites(FP_B)
        local paired, orphan = nil, nil
        for _i, e in ipairs(type(favs) == "table" and favs or {}) do
            if e and e.ts == 2001 then paired = e end
            if e and e.ts == 2002 then orphan = e end
        end
        ok(type(paired) == "table" and type(orphan) == "table",
            "5：（前置）有配对的、没配对的两条都取到了（取不到下面就是空转）")
        -- 列表行必须带上 book_fp 与 index：提问是**展示时**靠 questionFor 回查的，
        -- 行里没这两个字段，UI 就查不回去（团队定的口径：listFavorites 必须带 question，
        -- 实现上是"带原始字段 + 展示层回查"，两处都要钉）。
        if type(paired) == "table" then
            ok(type(paired.book_fp) == "string" and type(paired.index) == "number",
                "5①：（前置）列表行带得回 book_fp 与 index（回查提问靠它俩）",
                string.format("fp=%s index=%s", tostring(paired.book_fp), tostring(paired.index)))
        end
        if type(Store.questionFor) == "function" and type(paired) == "table" then
            local q = Store:questionFor(paired.book_fp, paired.index)
            ok(type(q) == "string" and q ~= "",
                "5①：有配对的那条，questionFor 回查到的提问**不为空**", tostring(q))
            ok(q == Q_B, "5①：回查到的是同一轮的提问（不是随便挑一条）", q)
        elseif type(Store.questionFor) ~= "function" then
            skip("5①：questionFor 回查提问", "Store.questionFor 还没落地")
        end
        if type(Store.questionFor) == "function" and type(orphan) == "table" then
            -- 反向对照：没有配对提问时必须是空的 —— 有这条在，上面那条才不是"刚好都有值"。
            local qo = Store:questionFor(orphan.book_fp, orphan.index)
            ok(not (type(qo) == "string" and qo ~= ""),
                "5②：没有配对提问的那条，回查结果**为空**（对照：回查不是一直有值）", tostring(qo))
        end
        -- UI 层：列表摘要与详情页都必须把提问显示出来（这才是用户真正看到的东西）
        local okf, Fav = pcall(require, "ui/favorites")
        if not (okf and type(Fav) == "table" and type(Fav.entryText) == "function") then
            skip("5③：UI 层展示提问", "ui/favorites 起不来 -> " .. tostring(Fav))
        else
            if type(paired) == "table" then
                local text = Fav:entryText(paired)
                ok(has(text, "【你的提问】") and has(text, Q_B),
                    "5③：详情页里确实把那一轮的提问显示出来了", text)
                ok(has(Fav:rowText(paired, true), Q_B:sub(1, 6)),
                    "5③：列表摘要里也带着提问（回想时靠它认人）", Fav:rowText(paired, true))
            end
            if type(orphan) == "table" then
                -- 对照：没有提问就不该出现「【你的提问】」那一节（而不是显示一个空标题）
                ok(hasNot(Fav:entryText(orphan), "【你的提问】"),
                    "5④：没有提问的那条，详情页不显示空的「【你的提问】」", Fav:entryText(orphan))
            end
        end
        callp(function() Store:setFavorite(FP_B, 2, false) end, "5：（清场）")
        callp(function() Store:setFavorite(FP_B, 3, false) end, "5：（清场）")
    end
end

-- ================= 6 search 同时命中 selection 与 question =================
section("6. 检索：引用段落、提问、回复都要能搜到")
do
    callp(function() return Store:search("偏偏", nil) end, "6：search 不抛异常")
    local _, r_sel = pcall(function() return Store:search("橙黄", nil) end)
    ok(type(r_sel) == "table" and #r_sel >= 1,
        "6①：搜「橙黄」（只存在于引用段落里）能命中——selection 必须进检索",
        type(r_sel) == "table" and #r_sel or tostring(r_sel))
    local _, r_q = pcall(function() return Store:search("哑巴仆人", nil) end)
    ok(type(r_q) == "table" and #r_q >= 1,
        "6②：搜「哑巴仆人」（只存在于提问里）能命中——question 必须进检索",
        type(r_q) == "table" and #r_q or tostring(r_q))
    local _, r_c = pcall(function() return Store:search("唯一答得出口", nil) end)
    ok(type(r_c) == "table" and #r_c >= 1,
        "6③：搜回复正文仍然命中（对照组：加了新字段没把原来的 content 搜索弄坏）",
        type(r_c) == "table" and #r_c or tostring(r_c))
    local _, r_none = pcall(function() return Store:search("_不该存在的字符串_", nil) end)
    ok(type(r_none) == "table" and #r_none == 0,
        "6④：搜不到的词返回空表，不瞎命中", type(r_none) == "table" and #r_none or tostring(r_none))
end

-- ================= 7 showLastReply 的 Store 回退 =================
section("7. 关书后还能看到最近一条回复（showLastReply 回退读 Store）")
do
    -- 这一步要真的 require main.lua 并调用 showLastReply：
    -- 只看 store 层等于没验（团队踩的正是"管道对、接线漏"）。
    local okm, Plugin = pcall(require, "main")
    if not (okm and type(Plugin) == "table" and type(Plugin.showLastReply) == "function") then
        skip("7：showLastReply 的 Store 回退", "main.lua 在打桩环境里没起来 -> " .. tostring(Plugin))
    else
        -- 关键 1：**内存字段是空的**（模拟关书后 Reader 实例已被销毁）
        -- 关键 2：probe 要能调到 Plugin 的方法 —— 上一版我直接传裸表，
        --         showLastReply 里的 self:bookFingerprint() 就炸了（是我桩没搭全，不是他的 bug）。
        local probe = setmetatable({ last_reply = nil, ui = { document = nil } }, { __index = Plugin })
        -- ui.document 为 nil 时 bookFingerprint() 回退成 "unknown"，
        -- 这正是"关书之后"的取值，所以历史要落在 unknown.json 里。
        local FP_U = "unknown"
        local CONTENT_U = "（QA）这是历史里躺着的那条回复。"
        writeFile(Config.paths.history .. "/" .. FP_U .. ".json", json.encode({
            entries = {
                { role = "user", content = "（QA）当时问的是什么？", kind = "light",
                  selection = "（QA）选中句。", ts = 6001, book_fp = FP_U,
                  book_title = "《未知书》", turn_id = "u1" },
                { role = "assistant", content = CONTENT_U, kind = "light",
                  selection = "（QA）选中句。", ts = 6002, book_fp = FP_U,
                  book_title = "《未知书》", turn_id = "u1" },
            },
        }))
        local fresh = freshStore()                       -- 清掉内存缓存，逼它真的去读盘
        ok(type(fresh.lastAssistant) == "function", "7：（前置）Store:lastAssistant 已落地")
        local n_before = #viewers
        local okc, errc = pcall(function() Plugin.showLastReply(probe) end)
        if not okc then
            skip("7：showLastReply 的 Store 回退",
                "驱动 showLastReply 时抛异常 -> " .. tostring(errc))
        else
            local last = viewers[#viewers]
            ok(#viewers > n_before and type(last) == "table"
                and type(last.text) == "string" and last.text ~= "",
                "7：last_reply 为空时，showLastReply 从 Store 读到内容并展示了（关书后不再是空的）",
                last and tostring(last.text))
            if #viewers > n_before then
                ok(has(last.text, CONTENT_U),
                    "7①：展示的正是历史里那一条（不是随便抓的）", tostring(last.text))
                -- 回退路径也要挂收藏按钮：用户是**事后**才想收藏的，
                -- 这时候没有 ref 就永远收藏不了（团队口径：ref 要一路带上）。
                local btn = nil
                for _i, b in ipairs(last._buttons or {}) do
                    if b.id == "ywbf_favorite" then btn = b end
                end
                ok(type(btn) == "table",
                    "7②：从历史回退读出来的回复也挂了收藏按钮（关书后才想起要收藏的场景）",
                    btn and tostring(btn.label))
            end
        end
        -- 反向对照：历史里也确实没有时，给的是空提示，而不是崩、也不是弹个空卡片
        callp(function() return Store:clear(FP_U) end, "7：（准备）清掉 unknown 的历史")
        local n_before2 = #viewers
        local okc2, errc2 = pcall(function() Plugin.showLastReply(probe) end)
        ok(okc2, "7③：（对照）历史也没有时不抛异常", errc2)
        if okc2 then
            ok(#viewers == n_before2,
                "7③：（对照）历史里也没有时，不再弹结果卡片（给空提示就够，不许弹空白页）",
                string.format("新增 %d 个卡片", #viewers - n_before2))
            local d = dialogs[#dialogs]
            ok(type(d) == "table" and has(d.text, "还没有异步回复"),
                "7③：（对照）走的是原来的空提示", d and tostring(d.text))
        end
    end
end

-- ================= 8 append 透传新字段 + 书名索引 books.json =================
-- 这里盯的是"写入侧"：老 append 是手写 rec（store.lua:44-50），除 ts/role/kind/content/selection
-- 之外**全丢**。新字段过不去，后面收藏/检索/展示就全是空的——所以必须单独钉一条。
section("8. 写入侧：append 要透传新字段，并把书名记进索引")
do
    local FP_D = "qa_fav_append"
    callp(function() return Store:clear(FP_D) end, "8：（准备）清掉 D 书")
    local entry = {
        role = "assistant", kind = "chat",
        content = "这是 append 写进去的一条回复。",
        selection = SEL_B, question = "append 带过来的提问是什么？",
        book_fp = FP_D, book_title = "《附录集》", chapter_title = "第一章 引子",
        chapter_index = 1, page = 7, style = "professional", turn_id = "d1",
    }
    callp(function() return Store:append(FP_D, entry) end, "8：append 不抛异常")
    local disk = rawEntries(FP_D)
    if type(disk) ~= "table" or #disk < 1 then
        skip("8：append 透传新字段", "append 没写出任何条目")
    else
        local e = disk[#disk]
        ok(e.question == entry.question, "8①：question 落盘了（append 透传）", tostring(e.question))
        ok(e.book_title == entry.book_title, "8②：book_title 落盘了", tostring(e.book_title))
        ok(e.chapter_title == entry.chapter_title, "8③：chapter_title 落盘了", tostring(e.chapter_title))
        ok(e.style == entry.style, "8④：style 落盘了（阶段二要按风格筛选，现在就得记）", tostring(e.style))
        ok(e.turn_id == entry.turn_id, "8⑤：turn_id 落盘了（问答成对靠它）", tostring(e.turn_id))
        ok(e.chapter_index == entry.chapter_index and e.page == entry.page,
            "8⑥：chapter_index / page 落盘了",
            string.format("idx=%s page=%s", tostring(e.chapter_index), tostring(e.page)))
    end
    -- 书名索引：append 收到 book_title 就顺手记进 books.json（团队口径：不依赖单一写入时机）
    if type(Store.bookTitle) == "function" then
        local title_back = Store:bookTitle(FP_D)
        ok(title_back == entry.book_title,
            "8⑦：Store:bookTitle(fp) 能从索引里拿回书名（append 顺手记的）", tostring(title_back))
    else
        skip("8⑦：Store:bookTitle 回读书名", "Store.bookTitle 还没落地")
    end
    -- 对照：从没写过索引的书，也要给得回一个非空书名（老数据就是这个形状）
    if type(Store.bookTitle) == "function" then
        local t_unknown = Store:bookTitle("qa_fav_never_seen_book")
        ok(type(t_unknown) == "string" and t_unknown ~= "",
            "8⑧：没写过索引的书，书名给回退值、不许是 nil/空串（老数据就这个形状）",
            tostring(t_unknown))
    else
        skip("8⑧：没索引时的书名回退", "Store.bookTitle 还没落地")
    end
end

-- ================= 9 缓存命中时的收藏 =================
-- 团队口径（2026-09-20）：缓存命中照样弹出了真实的结果卡片，那收藏按钮就必须真能收藏；
-- 唯一不能要的是"显示但点了没变化"。所以：历史里有那条 → 拿得到 ref 且能收藏；
-- 历史里没有（被删过）→ ref 为 nil，卡片上不该挂按钮。
section("9. 缓存命中：拿得到 ref 就能收藏，拿不到就不挂按钮")
do
    local Cache = package.loaded["ywbf/cache"]
    local okc0, CacheMod = pcall(require, "ywbf/cache")
    if not (okc0 and type(CacheMod) == "table") then
        skip("9：缓存命中时的收藏", "ywbf/cache 起不来 -> " .. tostring(CacheMod))
    else
        Cache = CacheMod
        local okinit = Cache:init()
        ok(okinit, "9：（前置）Cache 初始化成功（起不来下面全是假绿）")
        local FP_E = "qa_fav_cache"
        local SEL_E = "这段是用来验缓存命中的选中文本。"
        local CONTENT_E = "缓存里存着的这条回复原文。"
        -- 夹具：E 书里有两条 content 相同的 assistant（后一条是"最近一次"），
        -- 再塞一条**同 content 的 ideas**在最后，用来验证回查不会挑中它。
        local fx = {
            entries = {
                { role = "assistant", content = CONTENT_E, kind = "chat", selection = SEL_E, ts = 5001,
                  book_fp = FP_E, book_title = "《缓存书》", turn_id = "e1", favorite = false },
                { role = "assistant", content = CONTENT_E, kind = "chat", selection = SEL_E, ts = 5002,
                  book_fp = FP_E, book_title = "《缓存书》", turn_id = "e2", favorite = false },
                { role = "assistant", content = CONTENT_E, kind = "ideas", selection = SEL_E, ts = 5003,
                  book_fp = FP_E, book_title = "《缓存书》", favorite = false },
                -- 再放一条 ts 5004 的 chat 在 ideas **之后**：这样"取最后一条"和"不许挑中 ideas"
                -- 是两件独立的事——否则两条断言会互相顶，红了也不知道红在哪一条。
                { role = "assistant", content = CONTENT_E, kind = "chat", selection = SEL_E, ts = 5004,
                  book_fp = FP_E, book_title = "《缓存书》", turn_id = "e4", favorite = false },
            },
        }
        writeFile(Config.paths.history .. "/" .. FP_E .. ".json", json.encode(fx))
        -- 把这条内容塞进缓存，让下一次 askSync 直接命中。
        -- key 必须**照 asker 的算法**算（asker:139-143）：
        --   seed = selected .. "|" .. (question or "")（非默认风格才加 style 后缀）
        --   key  = keyFor(book_fp, seed, kind, model)
        -- 算错了就变成"缓存未命中"，下面那几条会红得莫名其妙（我第一版就踩了）。
        local okk, key = pcall(function()
            return Cache:keyFor(FP_E, SEL_E .. "|", "explain", Config:get("model"))
        end)
        ok(okk and type(key) == "string", "9：（前置）算得出缓存键（算不出下面全是假绿）", key)
        if okk and type(key) == "string" then
            callp(function() return Cache:set(key, CONTENT_E) end, "9：（准备）把回复塞进缓存")
        end

        local Asker = nil
        local oka, AMod = pcall(require, "ui/asker")
        if oka then Asker = AMod end
        if type(Asker) ~= "table" or type(Asker.askSync) ~= "function" then
            skip("9：缓存命中时的 ref 回查", "ui/asker 起不来 -> " .. tostring(AMod))
        else
            -- ① 先确认这一轮真的命中缓存，且**没有**再往历史里堆一条
            -- （口径：命中不写历史，否则同一问题反复问会不断堆叠）。
            local n_before = #(rawEntries(FP_E) or {})
            local ok1, c1, e1, fc1, _sp1, _tr1, stored1 = pcall(function()
                return Asker:askSync({
                    kind = "explain", selected = SEL_E, page_text = SEL_E,
                    book_fp = FP_E, progress = { chapter = 1, total = 10 },
                })
            end)
            ok(ok1, "9①：缓存命中的 askSync 不抛异常", e1)
            if ok1 then
                ok(fc1 == true, "9①：（前置）这一轮确实是缓存命中（不是真发请求）", tostring(fc1))
                ok(c1 == CONTENT_E, "9①：（前置）拿到的内容就是缓存里那条", tostring(c1))
                local n_after = #(rawEntries(FP_E) or {})
                ok(n_after == n_before,
                    "9①：命中缓存这一轮**没有**再往历史里堆一条（否则同一问题反复问会堆叠）",
                    string.format("before=%d after=%d", n_before, n_after))
                -- 缓存命中的 early return 只带 4 个值，stored 当然是 nil——**这是对的**：
                -- 没写新记录就没有新的 ref。卡片上的 ref 由 locateStoredTurn 用**回答原文**
                -- 把之前那条找回来（asker:398）。所以我第一版死盯第 6 个返回值是我断言写错了，
                -- 不是他的 bug；这里改钉真正的出口。
                ok(stored1 == nil,
                    "9②：缓存命中时不返回新的 ref（没写记录就不该有）—— 真正的 ref 走 locateStoredTurn",
                    tostring(stored1))
                ok(type(Asker.locateStoredTurn) == "function",
                    "9②：（前置）locateStoredTurn 这个出口存在（卡片就是靠它拿 ref 的）")
                if type(Asker.locateStoredTurn) == "function" then
                    local ref = Asker:locateStoredTurn(FP_E, c1, stored1)
                    ok(type(ref) == "table" and type(ref.index) == "number" and ref.book_fp == FP_E,
                        "9③：缓存命中也能拿回 ref（`{book_fp, index}`）—— 否则卡片上的收藏按钮就是死的",
                        type(ref) == "table" and string.format("fp=%s index=%s",
                            tostring(ref.book_fp), tostring(ref.index)) or tostring(ref))
                    if type(ref) == "table" and type(ref.index) == "number" then
                        local es = rawEntries(FP_E)
                        local e = es and es[ref.index]
                        ok(type(e) == "table" and e.content == CONTENT_E,
                            "9③：ref 指向的确实是那条回复（不是乱指的）", e and tostring(e.content))
                        ok(type(e) == "table" and e.kind ~= "ideas",
                            "9④：ref 回查不许挑中 ideas 条目（ideas 不进历史，回查也得守）",
                            e and tostring(e.kind))
                        ok(type(e) == "table" and e.ts == 5004,
                            "9⑤：同 content 有多条时取**最后**一条（口径确定，不依赖遍历顺序）",
                            e and tostring(e.ts))
                    end
                end

                -- ⑥ 行为层：真的把卡片弹出来，真的点一下收藏按钮，再去**磁盘**上看。
                -- 只看 ref 拿得到不算数——团队那条判据是"按钮上写着什么，点下去就得发生什么"。
                local n_v = #viewers
                local okshow = pcall(function()
                    Asker:askAndShow({
                        title = "远望书友", kind = "explain", selected = SEL_E,
                        page_text = SEL_E, book_fp = FP_E,
                        progress = { chapter = 1, total = 10 },
                    })
                end)
                ok(okshow, "9⑥：缓存命中时 askAndShow 不抛异常")
                if okshow and #viewers > n_v then
                    local card = viewers[#viewers]
                    local btn = nil
                    for _i, b in ipairs(card._buttons or {}) do
                        if b.id == "ywbf_favorite" then btn = b end
                    end
                    ok(type(btn) == "table",
                        "9⑥：缓存命中的结果卡片上**有**收藏按钮", btn and tostring(btn.label))
                    if type(btn) == "table" and type(btn.callback) == "function" then
                        ok(btn.label == "收藏",
                            "9⑥：（前置）按钮初始写着「收藏」（不是已经收藏过的状态）",
                            tostring(btn.label))
                        local okclick = pcall(btn.callback)
                        ok(okclick, "9⑥：点收藏按钮不抛异常")
                        local disk = rawEntries(FP_E) or {}
                        local hit = nil
                        for _i, e in ipairs(disk) do
                            if e.favorite == true then hit = e end
                        end
                        ok(type(hit) == "table",
                            "9⑦：点完之后**磁盘上**真的有了一条 favorite（内存里变化不算）",
                            hit and tostring(hit.ts))
                        ok(type(hit) == "table" and hit.ts == 5004,
                            "9⑦：收藏落在了 ref 指的那一条上（不是随便挑一条标上）",
                            hit and tostring(hit.ts))
                        ok(type(btn) == "table" and btn:getText() == "取消收藏",
                            "9⑦：按钮文字跟着变成了「取消收藏」（点了没反应是最难发现的假绿）",
                            btn and tostring(btn:getText()))
                        -- 再点一次能取消：只验"能收藏"不验"能取消"等于只验了一半
                        pcall(btn.callback)
                        local disk2 = rawEntries(FP_E) or {}
                        local still = false
                        for _i, e in ipairs(disk2) do
                            if e.favorite == true then still = true end
                        end
                        ok(still == false, "9⑧：再点一次取消收藏，磁盘上不再有 favorite")
                    end
                end
            end
            -- ⑦ 历史被清掉 → 拿不到 ref：这时卡片上不该挂收藏按钮（不许挂了没反应的死按钮）
            callp(function() return Store:clear(FP_E) end, "9：（准备）清掉 E 书历史")
            local ok2, c2, e2, fc2, _sp2, _tr2, stored2 = pcall(function()
                return Asker:askSync({
                    kind = "explain", selected = SEL_E, page_text = SEL_E,
                    book_fp = FP_E, progress = { chapter = 1, total = 10 },
                })
            end)
            ok(ok2, "9⑨：清掉历史后再问一次不抛异常", e2)
            if ok2 then
                ok(fc2 == true, "9⑨：（前置）这一轮仍然是缓存命中（历史没了，缓存还在）", tostring(fc2))
                ok(stored2 == nil,
                    "9⑨：没有新记录时，askSync 不返回 ref（本来就没写东西）",
                    tostring(stored2))
                if type(Asker.locateStoredTurn) == "function" then
                    local ref2 = Asker:locateStoredTurn(FP_E, c2, stored2)
                    ok(ref2 == nil,
                        "9⑩：历史里找不到那条时，ref 必须是 nil（没有可收藏的目标，就别挂按钮）",
                        tostring(ref2))
                end
                local n_v2 = #viewers
                pcall(function()
                    Asker:askAndShow({
                        title = "远望书友", kind = "explain", selected = SEL_E,
                        page_text = SEL_E, book_fp = FP_E,
                        progress = { chapter = 1, total = 10 },
                    })
                end)
                if #viewers > n_v2 then
                    local card2 = viewers[#viewers]
                    local btn2 = nil
                    for _i, b in ipairs(card2._buttons or {}) do
                        if b.id == "ywbf_favorite" then btn2 = b end
                    end
                    ok(btn2 == nil,
                        "9⑪：没有可收藏目标时，卡片上**不挂**收藏按钮（挂了就是点不动的死按钮）",
                        btn2 and tostring(btn2.label))
                end
            end
            callp(function() return Cache:clear() end, "9：（清场）")
        end
    end
end

-- ================= 10 接线静态兜底：书名要一路传到轻问 =================
-- 团队踩过"管道对、接线漏"（main.lua 忘了传 progress 那次），这类漏法行为断言跑不到：
-- gather() 需要真的 document 才能跑。所以这里用**静态兜底**把每一跳都钉住。
section("10. 静态兜底：书名的每一跳都写到了（漏一跳就是一批老数据缺字段）")
do
    local function srcOf(rel) return readFile(PLUGIN_DIR .. "/" .. rel) end
    local toast, mn = srcOf("ui/toastcard.lua"), srcOf("main.lua")
    ok(type(toast) == "string" and has(toast, "submitAsync"),
        "10：（前置）toastcard.lua 里确实有 submitAsync 的调用点（找不到的话下面那条就是空转）")
    if type(toast) == "string" then
        -- 不能只搜"文件里有 book_title"：写在别处（注释、另一个调用）也算命中，那是空转。
        -- 所以按**位置**钉：submitAsync 之后 400 字节内必须出现 book_title。
        local pos = toast:find("submitAsync", 1, true)
        local near = pos and toast:sub(pos, pos + 400) or ""
        ok(has(near, "book_title"),
            "10①：toastcard 调 submitAsync 时把 book_title 传过去了（轻问这条路径原本漏了它）",
            pos and ("submitAsync @ " .. pos) or "没找到 submitAsync")
    end
    ok(type(mn) == "string" and has(mn, "book_title"),
        "10②：main.lua 里有 book_title 的取值与传递（getProps().title → 文件名回退）")
    if type(mn) == "string" then
        ok(has(mn, "bookTitle"), "10③：main.lua 里新增了 bookTitle() 这个取书名的出口")
    end
end

-- ================= 11 轻问路径的书名透传（行为级） =================
-- 10① 只是静态兜底（"这一跳写到了"）；这一节是行为级（"真的传过去了"）。
-- 为什么还要多一层：轻问走的是 Queue + Trapper 的**异步通道**，跟 askSync 不是一条路，
-- 扫描到"写了 book_title"并不等于它在异步通道里也带着。
--
-- 另外一个坑必须先处理：**驱动前要清缓存**。命中缓存时 askSync 直接 early return、
-- 根本不写历史（那是团队定的正确行为），于是同一个目录跑第二遍就会假红。
-- 工程师自测脚本第 19 节正是被这个绊了一下（同一目录第二遍 4 条红，
-- 换干净目录第一遍 129/129 全绿），我把它写进注释免得再犯。
section("11. 轻问路径（toastcard → submitAsync）的书名真的传到了")
do
    -- FP_G **每轮换一个**：books.json（书名索引）不会被 Store:clear 清掉，
    -- 用固定指纹的话，上一轮写进索引的书名会留到这一轮，11③ 就变成"拿旧数据冒充新写入"的假绿。
    -- （同一类问题在工程师自测脚本第 19 节的 19e 上也出现过。）
    local FP_G = "qa_fav_toast_" .. tostring(os.time())
    local TITLE_G = "《轻问时的书名》"
    local okc11, CM = pcall(require, "ywbf/cache")
    if okc11 and type(CM) == "table" then
        pcall(function() CM:init() end)
    end
    local function purgeCache()
        if okc11 and type(CM) == "table" then pcall(function() CM:clear() end) end
    end
    callp(function() return Store:clear(FP_G) end, "11：（准备）清掉 G 书")
    local okT, TC = pcall(require, "ui/toastcard")
    if not (okT and type(TC) == "table" and type(TC.open) == "function") then
        skip("11：轻问路径的书名透传", "ui/toastcard 起不来 -> " .. tostring(TC))
    else
        -- 留空输入 → kind 走 explain、不带 question：这样不会碰到防剧透的"问后续剧情"分支，
        -- 红的就只会是"书名没传过去"，而不是"被防剧透拦了"。
        local function drive(book_title)
            purgeCache()
            input_dialogs = {}
            local okOpen, errOpen = pcall(function()
                TC:open({}, {
                    selected = "他要问的那一段。", page_text = "（已读）屋里只剩他两个。",
                    book_fp = FP_G, book_title = book_title,
                    progress = { chapter = 1, chapter_total = 10, page = 3, total = 100, percent = 3 },
                })
            end)
            ok(okOpen, "11：（前置）轻问输入框弹出来了", errOpen)
            if not okOpen then return false end
            local d = input_dialogs[#input_dialogs]
            if type(d) ~= "table" or type(d.buttons) ~= "table" then return false end
            d.input = ""
            local submit = nil
            for _r, row in ipairs(d.buttons) do
                for _c, b in ipairs(type(row) == "table" and row or {}) do
                    if type(b) == "table" and b.text == "提交" then submit = b end
                end
            end
            if type(submit) ~= "table" or type(submit.callback) ~= "function" then
                ok(false, "11：（前置）找得到「提交」按钮（找不到下面就是空转）", tostring(submit))
                return false
            end
            local okClick, errClick = pcall(submit.callback)
            ok(okClick, "11：（前置）点「提交」不抛异常", errClick)
            return okClick
        end
        if drive(TITLE_G) then
            local es = rawEntries(FP_G) or {}
            ok(#es >= 1, "11①：轻问这条异步路径真的写下了历史（不是只弹了个通知）",
                "#entries=" .. tostring(#es))
            local a = nil
            for _i, e in ipairs(es) do if e.role == "assistant" then a = e end end
            ok(type(a) == "table" and a.book_title == TITLE_G,
                "11②：轻问写下的条目带着当时那本书的书名（不是占位常量）",
                a and tostring(a.book_title))
            ok(Store:bookTitle(FP_G) == TITLE_G,
                "11③：书名索引也记下了同一个书名（跨书分组靠它）", tostring(Store:bookTitle(FP_G)))
        else
            skip("11①：轻问路径写历史", "没能驱动到提交（打桩不全，不算通过也不算失败）")
        end
        -- 反向对照：不给书名时确实没有书名 —— 没有这条，11② 的绿也可能只是别处写死了同一个值
        callp(function() return Store:clear(FP_G) end, "11：（准备）清掉 G 书（对照组）")
        if drive(nil) then
            local es2 = rawEntries(FP_G) or {}
            local a2 = nil
            for _i, e in ipairs(es2) do if e.role == "assistant" then a2 = e end end
            ok(type(a2) == "table" and (a2.book_title == nil or a2.book_title == ""),
                "11④：（对照）不给书名时条目就没有书名（11② 那个值不可能来自别处）",
                a2 and tostring(a2.book_title))
        else
            skip("11④：对照组的书名", "没能驱动到提交（打桩不全）")
        end
        callp(function() return Store:clear(FP_G) end, "11：（清场）")
        purgeCache()
    end
end

print("")
print(string.format("TOTAL: %d  PASSED: %d  FAILED: %d  SKIPPED: %d", TOTAL, PASSED, FAILED, SKIPPED))
print("（测试目录 " .. TEST_DIR .. "；夹具写在临时目录，不碰用户真机 data）")
