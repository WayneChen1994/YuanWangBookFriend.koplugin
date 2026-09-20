--[==[
QA 独立验证：**收藏与回顾（阶段二）** —— 备注/标签、Markdown 导出、按时间与风格筛选。

范围（团队 2026-09-20 派发，只验这些）：
  1. Store:setNote / Store:setTags 的落盘、清空、老数据兼容；标签串解析（中英文逗号、
     去空白、去重、丢空），以及**中文的字节安全**；
  2. Export:render(rows, opts) -> string：八要素（书名/章节/时间/提问/回答/备注/标签/风格）
     齐全、UTF-8 不被截断、称呼不许写死「AI」；
  3. Export:write(rows, opts) -> path：文件真的落盘、路径受 Config.paths.data 管辖、
     **内容就是 render 的产物**（防"render 写对了但 write 没调它"）；
  4. Store:search(query, book_fp, opts) 的 since / until（**两端都含**）/ style / tag；
  5. 老调用方回归：两参数 search 行为不变；
  6. UI 层真的接了导出入口（防"函数写好了但没接进调用链"）；
  7. 四个冻结文件的 md5 没被动过。

三条硬规矩（沿用阶段一）：
  · **必须走"真的落盘再读回"**：以**直接 json.decode 磁盘文件**为证据，并且清掉
    package.loaded 重新 require（模拟关书/重启），内存里的变化不算数。
  · **每条"某物必须存在"都配前置与反向对照**：例如"下界含"要配"下界外一秒必须不含"，
    "导出里有备注"要配"没有备注的那条导出里不许出现备注那一节"。
  · **红色不许撒谎**：接口还没落地 = 红（那是本次的交付物），只有"打桩驱动不到"才 SKIP，
    且 SKIP 单独计数、绝不当通过。

跑法（KPW4）：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     YWBF_PLUGIN_DIR=/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin \
     YWBF_P2_DIR=/mnt/us/ywbf_dev/p2_data \
     ./luajit /mnt/us/ywbf_dev/tools/qa_verify_phase2.lua
--]==]

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR") or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"
-- 测试目录独立：绝不碰用户真机上的 data/（临时文件只允许落在 /mnt/us/ywbf_dev 内）
local TEST_DIR = os.getenv("YWBF_P2_DIR") or "/mnt/us/ywbf_dev/p2_data"

io.stdout:setvbuf("line")

-- 每轮从空目录开始：books.json（书名索引）不会被 Store:clear 清掉，
-- 留着上一轮的数据会让"跨书/书名"那几条变成拿旧数据冒充新写入的假绿。
-- 兜一道保险再删：路径里没有 ywbf_dev 就不动手。
if type(TEST_DIR) == "string" and TEST_DIR:find("ywbf_dev", 1, true) and #TEST_DIR > 12 then
    os.execute("rm -rf " .. TEST_DIR)
end

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
package.loaded["ui/widget/buttondialog"] = { new = function(_s, t) return t or {} end }
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
                            b.label = b.text
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
    levels = { dbg = 1, info = 2, warn = 3, err = 4 },
}
package.loaded["dispatcher"] = { registerAction = function() end }
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(_s, t) return t or {} end,
    new = function(_s, t) return t or {} end,
}

local Config = require("ywbf/config")
-- 配置基线：Config:set 是**同步落盘**的，某一节中途抛异常会把下一个进程毒死。
-- 所以先记下原始 settings.json 正文，全部跑完（含异常路径）再整体还原。
local SETTINGS_RAW = nil
do
    local f = io.open(TEST_DIR .. "/data/settings.json", "rb")
    if f then SETTINGS_RAW = f:read("*all"); f:close() end
end
local function restoreSettings()
    if not SETTINGS_RAW then return end
    local f = io.open(TEST_DIR .. "/data/settings.json", "wb")
    if f then f:write(SETTINGS_RAW); f:close() end
end

Config:init(TEST_DIR)
Config:set("cache_enabled", true)
Config:set("spoiler_guard", true)
Config:set("spoiler_granularity", "chapter")
Config:set("reply_style", "professional")

local json = require("json")
local Util = require("ywbf/util")
local Prompts = require("ywbf/prompts")
local Store = require("ywbf/store")

-- 网络与 Key 打桩：本脚本不发起任何真实请求，更不会花钱。
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
if Crypto:init() then DeepSeek:setApiKey("qa-p2-key") end
if not DeepSeek:hasApiKey() then DeepSeek.getApiKey = function() return "qa-p2-key" end end

local PERSONA = Prompts.PERSONA_NAME
-- 风格的显示名从 Prompts.STYLES 里**动态取**，不写死：导出里写「专业严谨」还是
-- "professional" 是实现自由，但必须是 STYLES 里那个名字，不能是随手编的。
local STYLE_LABEL = {}
do
    for _i, s in ipairs(type(Prompts.STYLES) == "table" and Prompts.STYLES or {}) do
        if type(s) == "table" and type(s.key) == "string" then
            STYLE_LABEL[s.key] = type(s.text) == "string" and s.text or s.key
        end
    end
end
local LABEL_PRO = STYLE_LABEL["professional"] or "professional"
local UNKNOWN_STYLE = Store.UNKNOWN_STYLE or "unknown"

-- ================= 断言骨架 =================
local TOTAL, PASSED, FAILED, SKIPPED, EXEMPT = 0, 0, 0, 0, 0
local FAILED_NAMES = {}
local function ok(cond, name, extra)
    TOTAL = TOTAL + 1
    if cond then PASSED = PASSED + 1; print("  PASS  " .. name)
    else
        FAILED = FAILED + 1
        FAILED_NAMES[#FAILED_NAMES + 1] = name
        print("  FAIL  " .. name .. (extra and (" -> " .. tostring(extra)) or ""))
    end
end
local function skip(name, why)
    SKIPPED = SKIPPED + 1
    print("  SKIP  " .. name .. " -> " .. tostring(why))
end
local function exempt(name, why)
    EXEMPT = EXEMPT + 1
    print("  EXEMPT  " .. name .. " -> " .. tostring(why))
end
-- NOTE：既不算通过也不算失败，只是把"我看到的、但要团队裁定"的事实打出来
local function note(name, why)
    print("  NOTE  " .. name .. " -> " .. tostring(why))
end
local function callp(fn, name, ...)
    local oks, r1, r2, r3 = pcall(fn, ...)
    ok(oks, name, oks and nil or r1)
    return oks, r1, r2, r3
end
-- 接口没落地：这是本次的交付物，缺了就是红，但只红一条（后面细项走 SKIP，
-- 免得一次缺失刷出二十条红，把真正的问题淹掉）。
local function missing(name, why)
    ok(false, name .. "（接口缺失）", why)
end
local function section(t) print(""); print("=== " .. t .. " ===") end
local function has(s, sub)
    return type(s) == "string" and type(sub) == "string" and sub ~= "" and s:find(sub, 1, true) ~= nil
end
local function hasNot(s, sub) return not has(s, sub) end

-- 按行扫源码找字面量，正确区分"--"行注释与 Lua 长注释（方括号那一种）。
--
-- **为什么要自己维护长注释状态**：只认"行首是 --"会把长注释**内部的行**当成代码，
-- 于是"注释里提了一句"被误判成"代码里抄了一份"。这个错误我自己犯过一次——
-- export.lua 第 137 行是一整段长注释里的设计说明，被我误报成抄了映射表。
-- 误报比漏报更伤信任，所以长注释的开合状态必须在这里显式推进。
--
-- （这段说明故意写成"--"行注释而不是长注释：长注释的正文里一旦出现闭合方括号，
--   注释会在那儿提前结束，剩下的正文就变成代码了——我自己就是这么写出这个语法错的。）
local function scanLiterals(src, literals)
    local hits, exempts = {}, {}
    local n, in_block = 0, false
    for line in (tostring(src) .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1
        local trimmed = line:gsub("^%s+", "")
        local is_comment = in_block or (trimmed:sub(1, 2) == "--")
        for _i, lit in ipairs(literals) do
            if has(line, lit) then
                if is_comment then exempts[#exempts + 1] = n .. ":" .. trimmed
                else hits[#hits + 1] = n .. ":" .. trimmed end
                break
            end
        end
        -- 块注释状态推进（长注释：--[[ / --[=[ / --[==[ … ]] / ]=] / ]==]）
        if in_block then
            if line:find("%]%=?%=?%]") then in_block = false end
        else
            local _op, ope = line:find("%-%-%[%=?%=?%[")
            if ope and not line:sub(ope + 1):find("%]%=?%=?%]") then in_block = true end
        end
    end
    return hits, exempts
end
local function readFile(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local s = f:read("*all"); f:close(); return s
end
local function writeFile(p, s)
    local f = io.open(p, "wb"); if not f then return false end
    f:write(s); f:close(); return true
end
local function freshStore()
    package.loaded["ywbf/store"] = nil
    return require("ywbf/store")
end
local function rawEntries(fp)
    local raw = readFile(Config.paths.history .. "/" .. fp .. ".json")
    if not raw or #raw == 0 then return nil end
    local okd, dec = pcall(json.decode, raw)
    if not (okd and type(dec) == "table") then return nil end
    return dec.entries or {}
end
local function md5_of(path)
    local f = io.popen("md5sum '" .. tostring(path) .. "' 2>/dev/null")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return type(s) == "string" and s:match("^(%x+)") or nil
end
local LFS_OK, LFS = pcall(require, "libs/libkoreader-lfs")
-- 列文件（含一层子目录）：导出可能落在 data/export/ 之类的子目录里，
-- 只看根目录会把"文件其实写了"误判成"没写"。
local function listAllFiles(dir)
    local out = {}
    if not LFS_OK then return out end
    local function walk(d, prefix)
        for f in LFS.dir(d) do
            if f ~= "." and f ~= ".." then
                local full = d .. "/" .. f
                local attr = LFS.attributes(full)
                if attr and attr.mode == "directory" then
                    walk(full, prefix .. f .. "/")
                elseif attr and attr.mode == "file" then
                    out[#out + 1] = prefix .. f
                end
            end
        end
    end
    walk(dir, "")
    table.sort(out)
    return out
end

-- ================= 夹具 =================
local FP_N = "qa_p2_note"     -- 备注 / 标签
local FP_T = "qa_p2_filter"   -- 时间与风格筛选
local FP_X = "qa_p2_export"   -- 导出

local SEL_N = "雪停了，铁马不再作响的那一夜，他却偏偏提起了灯。"
local BOOK_X, CHAP_X = "《靛蓝纪事》", "第七章 橙黄灯"
local SEL_X  = "瓦上的雪被风扫开，露出一线黑。"
local Q_X    = "凤凰为何偏偏落在这一片瓦上？"
local A_X    = "因为瓦是暖的，而风不是。"
local NOTE_X = "我的批注：这里要回头再读一遍"
local TAG_X, TAG_X2 = "乌鸦", "瓦脊"

-- 时间戳固定：**不依赖"今天"**，否则今年跑和明年跑结论不同
local TS_EARLY = 1700000000   -- 下界外
local TS_SINCE = 1700000100   -- 正好在下界
local TS_MID   = 1700000200   -- 区间内
local TS_UNTIL = 1700000300   -- 正好在上界
local TS_LATE  = 1700000400   -- 上界外
local TS_XA    = 1700000500   -- 导出样本 A
local TS_XB    = 1500000000   -- 导出样本 B（与 A 不同年，用来证明时间是**从条目取的**）
local YEAR_XA  = os.date("!%Y", TS_XA)
local YEAR_XB  = os.date("!%Y", TS_XB)

-- 超长中文正文：专门用来抓"按字节截断"（裸 string.sub 会切在汉字中间）
local LONG_TEXT = (function()
    local parts = {}
    for _i = 1, 120 do parts[#parts + 1] = "雪夜里他把灯举过头顶，影子落在瓦上像一只乌鸦。" end
    return table.concat(parts)
end)()

local function buildFixtures()
    local noteBook = {
        entries = {
            -- 老数据形状：只有 role/content/kind/selection/ts
            { role = "user", content = "老数据里的提问。", kind = "chat", selection = SEL_N, ts = 7000 },
            { role = "assistant", content = "老数据里的回答。", kind = "chat", selection = SEL_N,
              ts = 7001, favorite = true },
            -- 新数据：字段齐全，用来验"改备注/标签不许把别的字段冲掉"
            { role = "assistant", content = "带完整字段的那条回答。", kind = "chat", selection = SEL_N,
              ts = 7002, turn_id = "n1", question = "这是它自己的提问？", book_fp = FP_N,
              book_title = "《备注书》", chapter_title = "第二章 灯芯", chapter_index = 2, page = 21,
              style = "professional", favorite = true, note = NOTE_X, tags = { TAG_X, TAG_X2 } },
        },
    }
    local filterBook = {
        entries = {
            { role = "assistant", content = "筛选正文甲", kind = "chat", selection = "筛选引用",
              ts = TS_EARLY, book_fp = FP_T, book_title = "《筛选书》", style = "professional",
              tags = { TAG_X }, question = "早于下界的提问" },
            { role = "assistant", content = "筛选正文乙", kind = "chat", selection = "筛选引用",
              ts = TS_SINCE, book_fp = FP_T, book_title = "《筛选书》", style = "gentle",
              tags = { TAG_X }, question = "正好在下界的提问" },
            -- 这一条**没有 style 也没有 tags**：老数据就这个形状
            { role = "assistant", content = "筛选正文丙", kind = "chat", selection = "筛选引用",
              ts = TS_MID, book_fp = FP_T, book_title = "《筛选书》", question = "区间内的提问" },
            { role = "assistant", content = "筛选正文丁", kind = "chat", selection = "筛选引用",
              ts = TS_UNTIL, book_fp = FP_T, book_title = "《筛选书》", style = "professional",
              tags = { TAG_X2 }, question = "正好在上界的提问" },
            { role = "assistant", content = "筛选正文戊", kind = "chat", selection = "筛选引用",
              ts = TS_LATE, book_fp = FP_T, book_title = "《筛选书》", style = "gentle",
              tags = { TAG_X2 }, question = "晚于上界的提问" },
        },
    }
    local exportBook = {
        entries = {
            { role = "assistant", content = A_X, kind = "chat", selection = SEL_X, ts = TS_XA,
              turn_id = "x1", question = Q_X, book_fp = FP_X, book_title = BOOK_X,
              chapter_title = CHAP_X, chapter_index = 7, page = 88, style = "professional",
              favorite = true, note = NOTE_X, tags = { TAG_X, TAG_X2 } },
            { role = "assistant", content = A_X .. LONG_TEXT, kind = "chat", selection = SEL_X,
              ts = TS_XB, turn_id = "x2", question = Q_X, book_fp = FP_X, book_title = BOOK_X,
              chapter_title = CHAP_X, chapter_index = 8, page = 99, style = "gentle",
              favorite = true },
        },
    }
    return {
        { fp = FP_N, data = noteBook, title = "《备注书》" },
        { fp = FP_T, data = filterBook, title = "《筛选书》" },
        { fp = FP_X, data = exportBook, title = BOOK_X },
    }
end

-- ================= 0 前置 =================
section("0. 前置：夹具落盘、样本本身站得住")
-- 先把我**审的是哪个版本**钉在输出里：md5 直接打出来，报告里不靠嘴说
do
    local AUDITED = {
        "main.lua", "ywbf/store.lua", "ywbf/export.lua",
        "ui/favorites.lua", "ui/settings.lua",
    }
    for _i, rel in ipairs(AUDITED) do
        print("  AUDIT  " .. rel .. " md5=" .. tostring(md5_of(PLUGIN_DIR .. "/" .. rel)))
    end
end
-- （前置）显示名必须**真的**从 Prompts.STYLES 取到，且不等于内部 key。
-- 少了这条，上面那句 `or "professional"` 兜底会在 STYLES 里 text 缺失时悄悄生效，
-- 3⑨ 就退化成"输出 key 也算过"——正是团队驳回掉的那个版本。这条必须单独站出来。
ok(LABEL_PRO ~= nil and LABEL_PRO ~= "" and LABEL_PRO ~= "professional",
    "0：（前置）从 Prompts.STYLES 取到的风格显示名存在、且不等于内部 key"
    .. "（这条不成立，3⑨/4⑥ 就会悄悄退化成放行的口径）", tostring(LABEL_PRO))
local fixtures = buildFixtures()
for _i, fx in ipairs(fixtures) do
    local okw = writeFile(Config.paths.history .. "/" .. fx.fp .. ".json", json.encode(fx.data))
    ok(okw, "0：夹具 " .. fx.fp .. " 写进测试目录了（写不进去下面全是假绿）")
    -- 书名索引也记一笔：导出里取书名可能走 row.book_title，也可能走 Store:bookTitle(fp)。
    -- 两条路都给成同一个值，免得"实现走了另一条路"被我误判成缺要素。
    pcall(function() Store:noteBook(fx.fp, fx.title) end)
end
do
    local es = rawEntries(FP_N)
    ok(type(es) == "table" and #es == 3, "0：（前置）备注书的 3 条夹具都读得回来", es and #es)
    if type(es) == "table" and es[1] then
        ok(es[1].note == nil and es[1].tags == nil and es[1].turn_id == nil,
            "0：（夹具自检）老数据那条确实**没有** note/tags/turn_id（否则兼容断言是空转）")
    end
    if type(es) == "table" and es[3] then
        ok(es[3].note == NOTE_X and type(es[3].tags) == "table" and es[3].tags[1] == TAG_X,
            "0：（夹具自检）新数据那条**已经带着** note 与 tags（否则「改完要保留」那条是空转）")
    end
    local et = rawEntries(FP_T)
    ok(type(et) == "table" and #et == 5, "0：（前置）筛选书的 5 条夹具都读得回来", et and #et)
    if type(et) == "table" then
        local no_style, no_tags = 0, 0
        for _i, e in ipairs(et) do
            if e.style == nil then no_style = no_style + 1 end
            if e.tags == nil then no_tags = no_tags + 1 end
        end
        ok(no_style == 1 and no_tags == 1,
            "0：（夹具自检）筛选书里正好有一条**既没 style 也没 tags**的老数据（缺字段的对照组）",
            string.format("no_style=%d no_tags=%d", no_style, no_tags))
    end
    -- 字节陷阱自检：「开」「式」含字节 0xBC，「二」含 0x8C —— `[^,，]` 这种**字节类**
    -- 切分会把它们一起切碎。先把字节打出来，证明这个夹具真的踩在那个坑上。
    local b_kai, b_er = {}, {}
    for _i = 1, #"开始" do b_kai[#b_kai + 1] = string.byte("开始", _i) end
    for _i = 1, #"二" do b_er[#b_er + 1] = string.byte("二", _i) end
    local kai_has_bc, er_has_8c = false, false
    for _i, b in ipairs(b_kai) do if b == 0xBC then kai_has_bc = true end end
    for _i, b in ipairs(b_er) do if b == 0x8C then er_has_8c = true end end
    ok(kai_has_bc and er_has_8c,
        "0：（夹具自检）「开始」含字节 0xBC、「二」含 0x8C（中文逗号 U+FF0C = EF BC 8C，"
        .. "字节类切分必然踩雷——这条不成立的话第 2⑥/2⑦ 条就是空转）",
        string.format("开始=%s 二=%s", table.concat(b_kai, ","), table.concat(b_er, ",")))
    ok(Store:bookTitle(FP_X) == BOOK_X,
        "0：（前置）书名索引里也记着《靛蓝纪事》（导出取书名的两条路都通）",
        tostring(Store:bookTitle(FP_X)))
end

-- ================= 1 备注：setNote =================
section("1. 备注：写进去要落盘、要能被重新读回，且只动这一个键")
if type(Store.setNote) ~= "function" then
    missing("1：Store:setNote 已落地", "store.lua 里没有 setNote")
    skip("1①-1⑥ 备注的落盘与清空", "setNote 缺失")
else
    local IDX_LEGACY, IDX_NEW = 2, 3
    local NOTE_TEXT = "这是 QA 写进去的备注。"
    -- ① 老数据条目（没有 note 字段）也要能写，不许因为缺字段炸
    local ok1, r1 = pcall(function() return Store:setNote(FP_N, IDX_LEGACY, NOTE_TEXT) end)
    ok(ok1, "1①：setNote 打在**老数据**条目上不抛异常（缺字段不许炸）", r1)
    ok(ok1 and r1 == true, "1①：setNote 成功时返回 true", tostring(r1))
    -- ② 磁盘证据
    local disk = rawEntries(FP_N)
    ok(type(disk) == "table" and disk[IDX_LEGACY] and disk[IDX_LEGACY].note == NOTE_TEXT,
        "1②：磁盘文件里 note 写进去了（内存里的变化不算）",
        disk and disk[IDX_LEGACY] and tostring(disk[IDX_LEGACY].note))
    -- ③ 重新 require（模拟关书/重启）后仍然在
    local S = freshStore()
    local back = (type(S.noteOf) == "function") and S:noteOf(FP_N, IDX_LEGACY)
        or (S:list(FP_N)[IDX_LEGACY] or {}).note
    ok(back == NOTE_TEXT, "1③：清掉模块状态重新 require 后备注还在（关书不丢）", tostring(back))
    -- ④ **只动这一个键**：这条样本事先带着 question/style/tags/favorite，
    --    改完备注它们必须原样在——"改备注把别的字段冲掉"是标准的数据损坏
    local d4 = rawEntries(FP_N)[IDX_NEW]
    local ok4 = pcall(function() return Store:setNote(FP_N, IDX_NEW, "改一下备注") end)
    ok(ok4, "1④：（准备）给带完整字段的那条写备注不抛异常")
    local d4b = rawEntries(FP_N)[IDX_NEW]
    ok(type(d4) == "table" and type(d4b) == "table" and d4b.question == d4.question
        and d4b.style == d4.style and d4b.favorite == d4.favorite
        and type(d4b.tags) == "table" and d4b.tags[1] == TAG_X
        and d4b.note == "改一下备注",
        "1④：写备注**只改 note**，其余字段（question/style/favorite/tags）原样保留",
        d4b and string.format("q=%s style=%s fav=%s tags=%s",
            tostring(d4b.question), tostring(d4b.style), tostring(d4b.favorite),
            type(d4b.tags) == "table" and tostring(d4b.tags[1]) or tostring(d4b.tags)))
    -- ⑤ 清空：空串表示清空，不许留下空字符串占位
    local ok5 = pcall(function() return Store:setNote(FP_N, IDX_NEW, "") end)
    ok(ok5, "1⑤：用空串清空备注不抛异常")
    local d5 = rawEntries(FP_N)[IDX_NEW]
    ok(type(d5) == "table" and (d5.note == nil or d5.note == ""),
        "1⑤：清空之后磁盘上不再有备注内容（不许留一个空串占位）", d5 and tostring(d5.note))
    -- ⑥ 反向对照：条目不存在时必须返回 false，不许抛异常、也不许凭空新建一条
    local n_before = #(rawEntries(FP_N) or {})
    local ok6, r6 = pcall(function() return Store:setNote(FP_N, 9999, "越界") end)
    ok(ok6 and r6 == false, "1⑥：（对照）下标越界时返回 false，不抛异常", tostring(r6))
    ok(#(rawEntries(FP_N) or {}) == n_before,
        "1⑥：（对照）越界写入没有凭空多出条目",
        string.format("before=%d after=%d", n_before, #(rawEntries(FP_N) or {})))
    local ok6b, r6b = pcall(function() return Store:setNote("qa_p2_不存在的书", 1, "x") end)
    ok(ok6b and r6b == false, "1⑥：（对照）书不存在时也返回 false", tostring(r6b))
    -- 还原夹具，免得污染后面的导出
    pcall(function() return Store:setNote(FP_N, IDX_NEW, NOTE_X) end)
end

-- ================= 2 标签：setTags + 解析 =================
section("2. 标签：中英文逗号都要认、要落盘、中文不许被切碎")
if type(Store.setTags) ~= "function" then
    missing("2：Store:setTags 已落地", "store.lua 里没有 setTags")
    skip("2①-2⑧ 标签的解析与落盘", "setTags 缺失")
else
    local IDX_NEW = 3
    local RAW = "甲，乙 , 甲,,"
    ok(has(RAW, "，") and has(RAW, ","),
        "2①：（前置）输入串里**同时**有中文逗号和英文逗号（否则这条就是空转）")
    if type(Store.parseTags) == "function" then
        local okp, r = pcall(function() return Store.parseTags(RAW) end)
        ok(okp, "2①：parseTags 不抛异常", r)
        local parsed = okp and r or nil
        ok(type(parsed) == "table" and #parsed == 2 and parsed[1] == "甲" and parsed[2] == "乙",
            "2①：parseTags 把「甲，乙 , 甲,,」切成 {甲, 乙}（中英文逗号都认、去重、丢空项）",
            type(parsed) == "table" and ("{" .. table.concat(parsed, ",") .. "}") or tostring(parsed))
    else
        skip("2①：parseTags 解析标签串", "Store.parseTags 没单独暴露，改由 2② 在磁盘上验")
    end
    -- ② 落盘证据（parseTags 存不存在都要验这一条）
    local ok2 = pcall(function() return Store:setTags(FP_N, IDX_NEW, RAW) end)
    ok(ok2, "2②：setTags 接受逗号串不抛异常")
    local d2 = rawEntries(FP_N)[IDX_NEW]
    ok(type(d2) == "table" and type(d2.tags) == "table" and #d2.tags == 2
        and d2.tags[1] == "甲" and d2.tags[2] == "乙",
        "2②：磁盘上的 tags 是 {甲, 乙}（不是原样存一个长串）",
        d2 and type(d2.tags) == "table" and ("{" .. table.concat(d2.tags, ",") .. "}") or tostring(d2 and d2.tags))
    -- ③ 重新 require 后还在
    local S3 = freshStore()
    local t3 = (type(S3.tagsOf) == "function") and S3:tagsOf(FP_N, IDX_NEW)
        or (S3:list(FP_N)[IDX_NEW] or {}).tags
    ok(type(t3) == "table" and #t3 == 2 and t3[1] == "甲",
        "2③：重新 require 后标签还在（关书不丢）",
        type(t3) == "table" and ("{" .. table.concat(t3, ",") .. "}") or tostring(t3))
    -- ④ 数组形式也要收（UI 很可能直接传数组）
    local ok4 = pcall(function() return Store:setTags(FP_N, IDX_NEW, { "丙", " 丁 " }) end)
    ok(ok4, "2④：setTags 接受字符串数组不抛异常")
    local d4 = rawEntries(FP_N)[IDX_NEW]
    ok(type(d4) == "table" and type(d4.tags) == "table" and d4.tags[1] == "丙" and d4.tags[2] == "丁",
        "2④：数组进去也是去空白后原样落盘",
        d4 and type(d4.tags) == "table" and ("{" .. table.concat(d4.tags, ",") .. "}") or tostring(d4 and d4.tags))
    -- ⑤ 清空
    local ok5 = pcall(function() return Store:setTags(FP_N, IDX_NEW, "") end)
    ok(ok5, "2⑤：清空标签不抛异常")
    local d5 = rawEntries(FP_N)[IDX_NEW]
    -- 收紧成"必须是 nil"：原来写的是 `== nil or # == 0`，那等于**放行空数组**，
    -- 而 store.lua 自己的契约写着"空结果一律返回 nil（空数组对"有没有标签"这个问题的
    -- 答案是含糊的）"。工程师在他自测里被同一类漏洞咬过一轮（A5 变异第一轮全绿），
    -- 是他把那条线索给我的，我回过头把自己的同一处放水堵上。
    ok(type(d5) == "table" and d5.tags == nil,
        "2⑤：清空之后磁盘上 tags 必须是 **nil**（不许留空数组：空数组对"
        .. "「有没有标签」这个问题的答案是含糊的）",
        d5 and type(d5.tags) == "table" and ("留了个空数组 #" .. #d5.tags) or tostring(d5 and d5.tags))
    -- 2⑤b：只含空白与逗号的输入，走的是 parseTags 之后 `#out == 0` 那条**更深**的分支。
    -- 光用 "" 验不到它——"" 在更靠前的分支就返回了，正是"入口被前分支挡住"那类变异幸存。
    pcall(function() return Store:setTags(FP_N, IDX_NEW, { "占位标签" }) end)
    local pre5b = rawEntries(FP_N)[IDX_NEW]
    ok(type(pre5b) == "table" and type(pre5b.tags) == "table" and #pre5b.tags == 1,
        "2⑤b：（前置）先真的写上标签（不先写，「清到 nil」就是拿一个本来就是 nil 的字段冒充）",
        pre5b and type(pre5b.tags) == "table" and ("#" .. #pre5b.tags) or tostring(pre5b and pre5b.tags))
    local ok5b = pcall(function() return Store:setTags(FP_N, IDX_NEW, "  \239\188\140 \239\188\140 ") end)
    ok(ok5b, "2⑤b：喂一串只有空白和逗号的东西不抛异常")
    local d5b = rawEntries(FP_N)[IDX_NEW]
    ok(type(d5b) == "table" and d5b.tags == nil,
        "2⑤b：只含空白/逗号时同样清到 nil（不是空数组，也不是留一堆空串）",
        d5b and type(d5b.tags) == "table" and ("{" .. table.concat(d5b.tags, ",") .. "}")
            or tostring(d5b and d5b.tags))
    -- ⑥ **中文的字节安全**（解析器层）：[^,，] 是**字节类**，
    --    含 0xBC / 0x8C 的汉字会被当成分隔符一起切碎
    if type(Store.parseTags) == "function" then
        local okb, rb = pcall(function() return Store.parseTags("开始，方式") end)
        ok(okb, "2⑥：parseTags 处理含 0xBC 字节的中文不抛异常", rb)
        ok(okb and type(rb) == "table" and #rb == 2 and rb[1] == "开始" and rb[2] == "方式",
            "2⑥：【字节安全】parseTags 把「开始，方式」切成 {开始, 方式}"
            .. "（[^,，] 这种字节类会把「开」「式」里的 0xBC 当分隔符，切出一地碎片）",
            okb and type(rb) == "table" and ("{" .. table.concat(rb, ",") .. "} #" .. #rb) or tostring(rb))
        local okc, rc = pcall(function() return Store.parseTags("二，三") end)
        ok(okc and type(rc) == "table" and #rc == 2 and rc[1] == "二" and rc[2] == "三",
            "2⑥：【字节安全】parseTags 把「二，三」切成 {二, 三}（「二」含 0x8C）",
            okc and type(rc) == "table" and ("{" .. table.concat(rc, ",") .. "} #" .. #rc) or tostring(rc))
    else
        skip("2⑥：解析器层的中文字节安全", "Store.parseTags 没暴露；改由 2⑦ 在磁盘上验")
    end
    -- ⑦ **字节安全**（磁盘层，不依赖 parseTags 是否暴露）
    local ok7 = pcall(function() return Store:setTags(FP_N, IDX_NEW, "开始，方式") end)
    ok(ok7, "2⑦：把含 0xBC 的中文标签写进去不抛异常")
    local d7 = rawEntries(FP_N)[IDX_NEW]
    ok(type(d7) == "table" and type(d7.tags) == "table" and #d7.tags == 2
        and d7.tags[1] == "开始" and d7.tags[2] == "方式",
        "2⑦：【字节安全】磁盘上的标签是 {开始, 方式}（切碎了就说明切分用的是字节类）",
        d7 and type(d7.tags) == "table" and ("{" .. table.concat(d7.tags, ",") .. "} #" .. #d7.tags)
            or tostring(d7 and d7.tags))
    -- ⑧ 老数据条目也要能写标签
    local ok8, r8 = pcall(function() return Store:setTags(FP_N, 2, { "老标签" }) end)
    ok(ok8, "2⑧：给**老数据**条目写标签不抛异常", r8)
    local d8 = rawEntries(FP_N)[2]
    ok(type(d8) == "table" and type(d8.tags) == "table" and d8.tags[1] == "老标签"
        and d8.content == "老数据里的回答。",
        "2⑧：老条目写标签后，原有字段（content）仍在、标签也在", d8 and tostring(d8.content))
    -- 还原
    pcall(function() return Store:setTags(FP_N, IDX_NEW, { TAG_X, TAG_X2 }) end)
    pcall(function() return Store:setTags(FP_N, 2, nil) end)
end

-- ================= 3 导出：Export:render 的八要素 =================
section("3. 导出：render 出来的 Markdown 要八要素齐全、不许截断、不许写死「AI」")
local ok_exp, Export = pcall(require, "ywbf/export")
if not (ok_exp and type(Export) == "table") then
    missing("3：ywbf/export 模块存在且能 require", tostring(Export))
    skip("3①-3⑭ render 的八要素", "ywbf/export 缺失")
    skip("4①-4⑦ write 的落盘", "ywbf/export 缺失")
elseif type(Export.render) ~= "function" then
    missing("3：Export:render 已落地", "export.lua 里没有 render")
    skip("3①-3⑭ render 的八要素", "render 缺失")
else
    local S = freshStore()
    local rows_all = S:listFavorites(FP_X)
    ok(type(rows_all) == "table" and #rows_all == 2,
        "3：（前置）导出样本的两条收藏都取到了（取不到下面全是空转）",
        type(rows_all) == "table" and #rows_all or tostring(rows_all))
    local rowA = type(rows_all) == "table" and rows_all[1] or nil
    local rowB = type(rows_all) == "table" and rows_all[2] or nil
    -- 行必须带得回 note / tags：八要素里有两项就靠它，阶段二的筛选也要用它
    if type(rowA) == "table" then
        ok(type(rowA.tags) == "table" and #rowA.tags >= 1,
            "3：（前置/接线）列表行带得回 tags（导出的标签要素、按标签筛选都靠它）",
            type(rowA.tags) == "table" and ("{" .. table.concat(rowA.tags, ",") .. "}") or tostring(rowA.tags))
        ok(type(rowA.note) == "string" and rowA.note ~= "",
            "3：（前置/接线）列表行带得回 note（导出的备注要素就靠它）", tostring(rowA.note))
    end
    local okr, out = pcall(function() return Export:render({ rowA }) end)
    ok(okr, "3①：Export:render 不抛异常", out)
    ok(okr and type(out) == "string" and out ~= "",
        "3①：render 返回非空字符串", okr and type(out) == "string" and ("#" .. #out) or tostring(out))

    if not (okr and type(out) == "string" and out ~= "") then
        skip("3②-3⑭ render 的要素", "render 没返回非空字符串")
    else
        -- 八要素里的**自由文本**六项（书名/章节/提问/回答/备注/标签）必须原样出现
        ok(has(out, BOOK_X), "3②：导出里有**书名**", BOOK_X)
        ok(has(out, CHAP_X), "3③：导出里有**章节**", CHAP_X)
        ok(has(out, Q_X),    "3④：导出里有**提问**", Q_X)
        ok(has(out, A_X),    "3⑤：导出里有**回答**", A_X)
        ok(has(out, NOTE_X), "3⑥：导出里有**备注**", NOTE_X)
        ok(has(out, TAG_X),  "3⑦：导出里有**标签**", TAG_X)
        ok(has(out, SEL_X),  "3⑦b：导出里有**引用的段落**（回想时靠它认出是哪一段）", SEL_X)
        -- 时间：用年份钉，并让两个不同年份的样本互为对照。
        -- 若实现写死"导出时的当前时间"，A 的输出里就不会有它的年份；
        -- 若压根不导时间，两条都会红。
        ok(has(out, YEAR_XA), "3⑧：导出里有**时间**（样本 A 的年份 " .. YEAR_XA .. "）", YEAR_XA)
        ok(hasNot(out, YEAR_XB),
            "3⑧：（对照）样本 A 的导出里**没有**样本 B 的年份"
            .. "（证明时间是从条目取的，不是写死的当前时间）", YEAR_XB)
        -- 风格必须是**给用户看的显示名**，不是内部 key：设置菜单里写「专业严谨」，
        -- 导出的 Markdown 里写 professional 用户看不懂——导出是给用户看的文档，
        -- 两处不一致就是用户可见的缺陷，不算"实现自由"。（团队 2026-09-20 裁定）
        -- 显示名从 Prompts.STYLES 现取、不写死：风格名改了这条跟着走，不会假红。
        ok(type(rowA) == "table" and rowA.style == "professional" and has(out, LABEL_PRO),
            "3⑨：导出里有**风格**，且是显示名「" .. LABEL_PRO .. "」"
            .. "（只输出内部 key professional 算红）", LABEL_PRO)

        -- 反向对照：没有备注 / 没有标签的那条，导出里不许留下空的那一节
        local function renderCopy(mut)
            local r = {}
            for k, v in pairs(rowA) do r[k] = v end
            mut(r)
            local okk, oo = pcall(function() return Export:render({ r }) end)
            return okk and oo or nil
        end
        local out_no_note = renderCopy(function(r) r.note = nil end)
        ok(type(out_no_note) == "string" and hasNot(out_no_note, NOTE_X),
            "3⑩：（对照）没有备注的那条，导出里**不出现**备注（不许留一个空标题）")
        local out_no_tag = renderCopy(function(r) r.tags = nil end)
        ok(type(out_no_tag) == "string" and hasNot(out_no_tag, TAG_X),
            "3⑩：（对照）没有标签的那条，导出里**不出现**标签")

        -- UTF-8 安全：超长中文正文必须**完整**出现（按字节截断就拼不回去）
        if type(rowB) == "table" then
            local okb, outB = pcall(function() return Export:render({ rowB }) end)
            ok(okb and type(outB) == "string" and has(outB, LONG_TEXT),
                "3⑪：【UTF-8】超长中文正文（" .. tostring(#LONG_TEXT) .. " 字节）"
                .. "**完整**出现在导出里（裸 string.sub 截断或按字节切都会拼不完整）",
                okb and type(outB) == "string"
                    and ("out=" .. #outB .. " 含全文=" .. tostring(has(outB, LONG_TEXT))) or tostring(outB))
            ok(okb and type(outB) == "string" and has(outB, YEAR_XB) and hasNot(outB, YEAR_XA),
                "3⑫：（对照）样本 B 的导出里是它自己的年份 " .. YEAR_XB .. "，不是 A 的 " .. YEAR_XA)
        else
            skip("3⑪/3⑫：超长正文与第二个年份", "第二条样本没取到")
        end

        -- 称呼不许写死「AI」
        local src = readFile(PLUGIN_DIR .. "/ywbf/export.lua") or ""
        ok(PERSONA ~= nil and PERSONA ~= "" and PERSONA ~= "AI",
            "3⑬：（前置）PERSONA_NAME 是「" .. tostring(PERSONA) .. "」，确实不等于 AI"
            .. "（这条不成立的话，下面的反向约束就没有参照物）")
        -- 反向约束：整个文件里不许出现 "AI" 字样。按行扫，注释里的命中单独计豁免
        -- （团队裁定：反向约束覆盖注释，但要带理由地豁免；豁免清单**不预建**——
        --  预建等于把这条变成永远走不到的死分支）。
        local ai_lines, exempt_lines = scanLiterals(src, { "AI" })
        ok(#ai_lines == 0,
            "3⑬：【反向】export.lua 的非注释行里没有写死的「AI」"
            .. "（称呼一律走 Prompts.PERSONA_NAME）",
            #ai_lines > 0 and table.concat(ai_lines, " | ") or nil)
        if #exempt_lines > 0 then
            exempt("3⑬ 注释里的 AI 字样", table.concat(exempt_lines, " | "))
        end
        ok(hasNot(out, "AI"),
            "3⑭：导出文本里也没有「AI」字样（用户看到的是" .. tostring(PERSONA) .. "）")
        if has(src, "PERSONA_NAME") then
            ok(has(out, PERSONA),
                "3⑮：export.lua 引用了 PERSONA_NAME，导出里就真的用上了（引用了不用 = 空转）",
                PERSONA)
        end

        --【反向约束】导出不许另抄一份中文风格映射表：显示名必须走 Prompts.STYLES。
        -- 真正走定义处的实现**根本不需要**出现这些字面量；出现就说明抄了一份，
        -- 以后改风格名要改两处、迟早不同步。
        -- 显示名**全部现取**（本文件里不写任何风格名字面量），所以风格名改了这条自动跟随，
        -- 零维护成本——硬编码进断言才会有"改风格名我要跟着改"那个代价。
        local labels = {}
        for _i, s in ipairs(type(Prompts.STYLES) == "table" and Prompts.STYLES or {}) do
            if type(s) == "table" and type(s.text) == "string" and s.text ~= ""
                and s.text ~= s.key then
                labels[#labels + 1] = s.text
            end
        end
        table.sort(labels)

        ok(#labels > 0,
            "3⑯：（前置）从 Prompts.STYLES 现取到了风格显示名（取不到就是空扫描，"
            .. "下面的「没抄写」会恒绿）", #labels)
        -- 反向对照：证明这个"逐行搜"的机制真能命中，否则"零命中"可能只是扫描压根没干活
        if #labels > 0 then
            -- 对照里的注释特意用**块注释**写：只认 `--` 行注释的实现会把它误判成代码命中，
            -- 这正是我上一轮误报 export.lua 137 行的原因。这条对照专治那个复发。
            local probe = "--[[--\n注释里提一句 " .. labels[1] .. "\n--]]\n"
                .. "local x = \"" .. labels[1] .. "\"\n"
            local ph, pe = scanLiterals(probe, labels)
            ok(#ph == 1 and #pe == 1,
                "3⑯：（对照）扫描机制自己验过了——造一段含显示名的假源码（块注释 1 处 + 代码 1 处），"
                .. "能报出 1 处代码命中 + 1 处注释豁免"
                .. "（块注释那一处若被算成命中，就会重演我误报 137 行那次）",
                string.format("hits=%d exempt=%d", #ph, #pe))
        end
        local style_hits, style_exempt = scanLiterals(src, labels)
        ok(#style_hits == 0,
            "3⑯：【反向】export.lua 的非注释行里**没有抄写任何风格显示名**"
            .. "（" .. #labels .. " 个显示名全部从 Prompts.STYLES 现取；"
            .. "抄一份就等于把显示名硬编码进导出，改风格名要改两处）",
            #style_hits > 0 and table.concat(style_hits, " | ") or nil)
        if #style_exempt > 0 then
            exempt("3⑯ 注释里的风格显示名", table.concat(style_exempt, " | "))
        end
    end
end

-- ================= 4 导出：Export:write =================
section("4. 导出：write 要真的落盘，且写进去的**就是 render 的产物**")
if not (ok_exp and type(Export) == "table") then
    skip("4①-4⑦ write 的落盘", "ywbf/export 缺失")
elseif type(Export.write) ~= "function" then
    missing("4：Export:write 已落地", "export.lua 里没有 write")
    skip("4①-4⑦ write 的落盘", "write 缺失")
else
    local S = freshStore()
    local rows = S:listFavorites(FP_X)
    local rowA = type(rows) == "table" and rows[1] or nil
    local rowB = type(rows) == "table" and rows[2] or nil
    ok(type(rowA) == "table", "4：（前置）拿得到导出样本", tostring(rowA))
    -- 交付版定死 `write(rows, opts) -> path, err`：路径在第一位，成功时 err 为 nil。
    -- 早前规格没 settling，我在这里做过"三个槽位里扫第一个非空字符串"的宽容写法；
    -- 那种写法有洞：签名退回 `(true, path)` 时它照样绿（只打一行 NOTE），
    -- 而 `if p then` 在那种形状下也通过 —— 于是"拿到路径"这件事其实没被钉住。
    -- 签名既已交付，宽容度取消：第一位必须是路径字符串。
    local w1, w2, w3 = nil, nil, nil
    local okw = pcall(function() w1, w2, w3 = Export:write({ rowA }) end)
    ok(okw, "4①：Export:write 不抛异常", w2)
    ok(type(w1) == "string" and w1 ~= "",
        "4①：write 的第一个返回值**就是**落盘路径"
        .. "（不许在别的槽位里找路径：`local ok, p = ...` 那种形状下 `if p then`"
        .. " 也会通过、然后把 true 当路径用，是静默出错）",
        string.format("r1=%s r2=%s r3=%s", tostring(w1), tostring(w2), tostring(w3)))
    ok(type(w1) == "string" and w2 == nil,
        "4①：（对照）成功时第二个返回值（错误原因）必须是 nil"
        .. "（成功还带个原因 = 错误通道是摆设，调用方没法据它判断成败）",
        string.format("err=%s", tostring(w2)))
    local path = w1
    if not (okw and type(path) == "string" and path ~= "") then
        skip("4②-4⑦ write 的落盘内容", "write 没返回路径")
    else
        -- 路径必须受 Config 管辖（跟着数据目录走），不许写死 /tmp 或插件目录之外
        ok(path:sub(1, #Config.paths.data) == Config.paths.data,
            "4②：导出文件落在 Config.paths.data 里（" .. Config.paths.data .. "）"
            .. "——写死 /tmp 或写到插件目录之外都违反「只落在插件内」的铁律", tostring(path))
        ok(hasNot(path, "/tmp"),
            "4②：（对照）导出路径不在 /tmp（临时目录会被清，用户以为导出了其实没了）",
            tostring(path))
        ok(has(path, ".md"),
            "4③：导出文件是 .md（Markdown）", tostring(path))
        local body = readFile(path)
        ok(type(body) == "string" and body ~= "", "4④：路径指向的文件真的存在、读得回来", tostring(path))
        if type(Export.render) == "function" then
            local okr, rendered = pcall(function() return Export:render({ rowA }) end)
            -- 【接线】write 的内容必须是 render 的产物：render 写对了但 write 自己拼个空壳，
            -- 静态扫描抓不到，只有比内容才抓得到。
            ok(okr and type(rendered) == "string" and type(body) == "string" and has(body, rendered),
                "4⑤：【接线】文件内容**包含 render 的完整产物**"
                .. "（write 真的调了 render，不是自己拼了个标题了事）",
                okr and type(rendered) == "string" and ("render#" .. #rendered) or tostring(rendered))
            if okr and type(rendered) == "string" and type(body) == "string" then
                ok(has(body, BOOK_X) and has(body, Q_X) and has(body, A_X) and has(body, NOTE_X)
                    and has(body, TAG_X) and has(body, YEAR_XA) and has(body, LABEL_PRO),
                    "4⑥：落盘的文件里八要素齐全（书名/提问/回答/备注/标签/时间/风格）",
                    type(body) == "string" and ("#" .. #body) or tostring(body))
            end
            if type(rowB) == "table" then
                local x1, x2, x3 = nil, nil, nil
                local okw2 = pcall(function() x1, x2, x3 = Export:write({ rowB }) end)
                local p2 = nil
                for _i, v in ipairs({ x1, x2, x3 }) do
                    if (not p2) and type(v) == "string" and v ~= "" then p2 = v end
                end
                if okw2 and type(p2) == "string" then
                    local b2 = readFile(p2)
                    ok(type(b2) == "string" and has(b2, LONG_TEXT),
                        "4⑦：【UTF-8】超长中文正文完整落盘（没被按字节截断）",
                        type(b2) == "string" and ("file#" .. #b2) or tostring(b2))
                else
                    skip("4⑦：超长正文落盘", "第二条导出失败 -> " .. tostring(p2))
                end
            else
                skip("4⑦：超长正文落盘", "第二条样本没取到")
            end
        else
            skip("4⑤-4⑦ write 与 render 的一致性", "render 缺失")
        end
        -- 反向对照：空行数组不许崩（一条都没有就是没有，给空数组是正常场景）
        local oke, pe = pcall(function() return Export:write({}) end)
        ok(oke, "4⑧：（对照）rows 为空表时 write 不抛异常", pe)
    end
end

-- ================= 5 导出入口的接线（UI 层） =================
section("5. 导出入口接进了 UI（函数写好了但没接进调用链，静态扫描抓不到）")
do
    local fav_src = readFile(PLUGIN_DIR .. "/ui/favorites.lua") or ""
    local set_src = readFile(PLUGIN_DIR .. "/ui/settings.lua") or ""
    local main_src = readFile(PLUGIN_DIR .. "/main.lua") or ""
    local all_src = fav_src .. "\n" .. set_src .. "\n" .. main_src

    -- ① 有人 require 了导出模块（不是嘴上说说）
    ok(has(all_src, "ywbf/export"),
        "5①：UI 层（favorites/settings/main）里有 require(\"ywbf/export\")")
    -- ② 光 require 不算接线：必须**真的调用** write/render
    local called = has(all_src, "Export:write") or has(all_src, "Export:render")
        or has(all_src, "export:write") or has(all_src, "export:render")
        or has(all_src, "Export.write") or has(all_src, "Export.render")
    ok(called, "5②：【接线】UI 层有对 Export 的**调用**（不只是 require 进来放着）")

    -- ③ 行为级：真的把入口点一下，看 data/ 下是不是多出一个文件
    local okf, Fav = pcall(require, "ui/favorites")
    if not (okf and type(Fav) == "table") then
        skip("5③-5⑥ UI 导出入口的行为级验证", "ui/favorites 起不来 -> " .. tostring(Fav))
    else
        local S = freshStore()
        local rows = S:listFavorites(FP_X)
        ok(type(rows) == "table" and #rows >= 1,
            "5：（前置）拿得到收藏行（拿不到，下面的点击全是空转）",
            type(rows) == "table" and #rows or tostring(rows))

        local before = listAllFiles(Config.paths.data)
        local produced, how, newfile = false, nil, nil
        local function checkNew(tag)
            local after = listAllFiles(Config.paths.data)
            if #after > #before then
                local seen = {}
                for _i, f in ipairs(before) do seen[f] = true end
                for _i, f in ipairs(after) do if not seen[f] then newfile = f end end
                produced, how = true, tag
            end
        end

        -- 路线一：**用户真正的路径** —— 设置里的「我的收藏」子菜单。
        -- 工程师把导出入口放在这里（"想起要导出的时候，一定是在看收藏的时候"），
        -- 所以钉这一条比钉收藏列表页更有意义。
        local oks, SettingsUI = pcall(require, "ui/settings")
        if not (oks and type(SettingsUI) == "table"
                and type(SettingsUI.buildFavoritesMenu) == "function") then
            skip("5③：设置菜单里的导出入口", "ui/settings 起不来或没有 buildFavoritesMenu -> "
                .. tostring(SettingsUI))
        else
            local probe = {
                bookFingerprint = function() return FP_X end,
                bookTitle = function() return BOOK_X end,
            }
            local okb, items = pcall(function() return SettingsUI:buildFavoritesMenu(probe) end)
            local export_item, seen_texts = nil, {}
            if okb and type(items) == "table" then
                for _i, it in ipairs(items) do
                    if type(it) == "table" then seen_texts[#seen_texts + 1] = tostring(it.text) end
                    if type(it) == "table" and type(it.text) == "string" and has(it.text, "导出") then
                        export_item = export_item or it
                    end
                end
            end
            ok(okb and type(items) == "table" and #items > 0,
                "5③：（前置）设置里的「我的收藏」子菜单画得出来（画不出来下面全是空转）",
                okb and (table.concat(seen_texts, " | ")) or tostring(items))
            ok(type(export_item) == "table",
                "5③：设置菜单里有**「导出 Markdown」**这一项（用户找得到它）",
                export_item and tostring(export_item.text)
                    or ("菜单项里没有含「导出」的：" .. table.concat(seen_texts, " | ")))
            if type(export_item) == "table" and type(export_item.callback) == "function" then
                local okc, errc = pcall(export_item.callback)
                ok(okc, "5③：点「" .. tostring(export_item.text) .. "」不抛异常", errc)
                checkNew("设置菜单「" .. tostring(export_item.text) .. "」")
            end
        end

        -- 路线二：模块上名字里带 export 的函数（不依赖具体命名）
        if not produced then
            local hooks = {}
            for k, v in pairs(Fav) do
                if type(v) == "function" and type(k) == "string" and has(k:lower(), "export") then
                    hooks[#hooks + 1] = { name = k, fn = v }
                end
            end
            table.sort(hooks, function(a, b) return a.name < b.name end)
            local names = {}
            for _i, h in ipairs(hooks) do names[#names + 1] = h.name end
            ok(#hooks > 0,
                "5④：ui/favorites 上有名字带 export 的函数（UI 层导出入口的兜底查法）",
                #hooks > 0 and table.concat(names, ",") or "一个都没有")
            local argsets = {
                function(fn) return fn(Fav, rows) end,
                function(fn) return fn(Fav, rows, {}) end,
                function(fn) return fn(rows) end,
                function(fn) return fn(Fav) end,
                function(fn) return fn(Fav, rows, { book_title = BOOK_X }) end,
            }
            for _i, h in ipairs(hooks) do
                for _j, mk in ipairs(argsets) do
                    if not produced then
                        local okc = pcall(mk, h.fn)
                        if okc then checkNew(h.name) end
                    end
                end
            end
        end

        ok(produced,
            "5⑤：【接线】真的点一下 UI 上的导出入口，data/ 下就多出一个文件"
            .. "（函数写好了但没接进调用链，静态扫描全绿也只有这条抓得到）",
            produced and ("via " .. tostring(how) .. " -> " .. tostring(newfile))
                or ("点了但没有新文件；before=" .. #before
                    .. " after=" .. #listAllFiles(Config.paths.data)))
        if produced and type(newfile) == "string" then
            local content = readFile(Config.paths.data .. "/" .. newfile)
            ok(type(content) == "string" and has(content, BOOK_X) and has(content, A_X),
                "5⑥：从 UI 导出的文件里至少书名与回答在（不是写了个空壳）",
                type(content) == "string" and ("#" .. #content) or tostring(content))
        else
            skip("5⑥：UI 导出文件的内容", "没能从 UI 驱动出导出文件")
        end
    end
end

-- ================= 6 时间筛选：两端都含 =================
section("6. 时间筛选：since / until 两端都含")
do
    local function hitsWith(opts)
        local oks, r = pcall(function() return Store:search("筛选", FP_T, opts) end)
        return (oks and type(r) == "table") and r or {}, oks
    end
    local function has_ts(list, ts)
        for _i, r in ipairs(list) do if r.ts == ts then return true end end
        return false
    end
    local all, oks_all = hitsWith(nil)
    ok(oks_all, "6：（前置）search 带第三个参数不抛异常")
    ok(#all == 5, "6：（前置）不筛选时 5 条全中（夹具站得住，下面每条才有意义）", #all)
    -- 下界：含
    local h_since = hitsWith({ since = TS_SINCE })
    ok(has_ts(h_since, TS_SINCE),
        "6①：since 边界那一秒**要**命中（左端含）", "#hits=" .. #h_since)
    ok(not has_ts(h_since, TS_EARLY),
        "6②：（对照）下界外那一秒**不**命中（这条不成立，6① 就是恒真的空转）",
        "#hits=" .. #h_since)
    -- 上界：含
    local h_until = hitsWith({ ["until"] = TS_UNTIL })
    ok(has_ts(h_until, TS_UNTIL),
        "6③：until 边界那一秒**要**命中（右端含）", "#hits=" .. #h_until)
    ok(not has_ts(h_until, TS_LATE),
        "6④：（对照）上界外那一秒**不**命中（这条不成立，6③ 就是恒真的空转）",
        "#hits=" .. #h_until)
    -- 区间
    local h_both = hitsWith({ since = TS_SINCE, ["until"] = TS_UNTIL })
    ok(#h_both == 3 and has_ts(h_both, TS_SINCE) and has_ts(h_both, TS_UNTIL)
        and has_ts(h_both, TS_MID),
        "6⑤：区间 [since, until] 正好命中 3 条，两端都在里面", "#hits=" .. #h_both)
    -- 反向对照
    ok(#hitsWith({}) == 5,
        "6⑥：（对照）opts 传空表时等价于不筛选（5 条全中）", #hitsWith({}))
    ok(#hitsWith({ since = TS_LATE + 1 }) == 0,
        "6⑦：（对照）时间窗落在所有样本之后时 0 条（筛选项不是摆设）",
        #hitsWith({ since = TS_LATE + 1 }))
    if type(Store.filterRows) == "function" then
        local fr = Store:filterRows(all, { since = TS_SINCE, ["until"] = TS_UNTIL })
        ok(#fr == 3, "6⑧：Store:filterRows 用的也是「两端都含」（列表页与检索同一口径）", #fr)
        ok(#all == 5, "6⑧：（对照）filterRows 不改动传入的数组", #all)
    else
        skip("6⑧：filterRows 的两端含", "Store.filterRows 没暴露（不是本次强制接口）")
    end
end

-- ================= 7 风格筛选 =================
section("7. 风格筛选：老数据（没有 style 字段）要能被单独筛出来")
do
    local function hitsWith(opts)
        local oks, r = pcall(function() return Store:search("筛选", FP_T, opts) end)
        return (oks and type(r) == "table") and r or {}
    end
    local function has_ts(list, ts)
        for _i, r in ipairs(list) do if r.ts == ts then return true end end
        return false
    end
    ok(UNKNOWN_STYLE ~= nil and UNKNOWN_STYLE ~= "",
        "7：（前置）Store.UNKNOWN_STYLE 有值（" .. tostring(UNKNOWN_STYLE) .. "）")
    local h_pro = hitsWith({ style = "professional" })
    ok(#h_pro == 2 and has_ts(h_pro, TS_EARLY) and has_ts(h_pro, TS_UNTIL),
        "7①：style=professional 只命中那两条 professional 的", "#hits=" .. #h_pro)
    local h_gen = hitsWith({ style = "gentle" })
    ok(#h_gen == 2 and has_ts(h_gen, TS_SINCE) and has_ts(h_gen, TS_LATE),
        "7②：style=gentle 只命中那两条 gentle 的", "#hits=" .. #h_gen)
    ok(not has_ts(h_pro, TS_MID),
        "7③：（对照）**没有 style 字段**的老数据不会被算成某个具体风格", "#hits=" .. #h_pro)
    local h_unk = hitsWith({ style = UNKNOWN_STYLE })
    ok(#h_unk == 1 and has_ts(h_unk, TS_MID),
        "7④：style=" .. tostring(UNKNOWN_STYLE) .. " 能把**没有 style 的老数据**单独筛出来"
        .. "（缺字段不等于不该被筛到）", "#hits=" .. #h_unk)
    ok(#hitsWith(nil) == 5,
        "7⑤：（对照）不按风格筛选时 5 条全中（加筛选没把老行为改坏）", #hitsWith(nil))
end

-- ================= 8 标签筛选 =================
section("8. 标签筛选：打了标签的才命中")
do
    local function hitsWith(opts)
        local oks, r = pcall(function() return Store:search("筛选", FP_T, opts) end)
        return (oks and type(r) == "table") and r or {}
    end
    local function has_ts(list, ts)
        for _i, r in ipairs(list) do if r.ts == ts then return true end end
        return false
    end
    local h_tag = hitsWith({ tag = TAG_X })
    ok(#h_tag == 2 and has_ts(h_tag, TS_EARLY) and has_ts(h_tag, TS_SINCE),
        "8①：tag=" .. TAG_X .. " 只命中打了这个标签的两条", "#hits=" .. #h_tag)
    ok(not has_ts(h_tag, TS_MID),
        "8②：（对照）**没有标签**的老数据不会被命中", "#hits=" .. #h_tag)
    ok(#hitsWith({ tag = "_没有这个标签_" }) == 0,
        "8③：（对照）筛一个不存在的标签时 0 条（tag 不是恒真的摆设）",
        #hitsWith({ tag = "_没有这个标签_" }))
end

-- ================= 9 老调用方回归 =================
section("9. 回归：两参数 search 的行为不许变（加了第三个参数反而把老的弄坏最常见）")
do
    local oks2, r2 = pcall(function() return Store:search("筛选", FP_T) end)
    ok(oks2 and type(r2) == "table" and #r2 == 5,
        "9①：search(query, book_fp) 两参数调用照旧工作", oks2 and type(r2) == "table" and #r2 or tostring(r2))
    local oks3, r3 = pcall(function() return Store:search("筛选", nil) end)
    ok(oks3 and type(r3) == "table" and #r3 >= 5,
        "9②：search(query, nil) 跨书照旧工作", oks3 and type(r3) == "table" and #r3 or tostring(r3))
    local oks4, r4 = pcall(function() return Store:search("", FP_T) end)
    ok(oks4 and type(r4) == "table" and #r4 == 0,
        "9③：空关键词返回空表", oks4 and type(r4) == "table" and #r4 or tostring(r4))
    local oks5, r5 = pcall(function() return Store:search("_不存在的关键词_", FP_T) end)
    ok(oks5 and type(r5) == "table" and #r5 == 0,
        "9④：（对照）搜不到就返回空表，不瞎命中", oks5 and type(r5) == "table" and #r5 or tostring(r5))
    local oks6, r6 = pcall(function() return Store:search("铁马", nil) end)
    ok(oks6, "9⑤：跨书检索不抛异常", r6)
end

-- ================= 10 冻结文件不许被动过 =================
section("10. 四个冻结文件的 md5 不许变（阶段二只许动授权文件）")
do
    local FROZEN = {
        { rel = "ui/suggestpicker.lua", md5 = "f83eae6d3b3c241dd75d60ac566c56a9" },
        { rel = "ui/asker.lua",         md5 = "e579bf5ef08660d828c5426127130be2" },
        { rel = "ui/chatdialog.lua",    md5 = "00203f5ce1df29ef3777629956aace73" },
        { rel = "ui/toastcard.lua",     md5 = "228cdbf7b80a3df5cb472503c37bd847" },
    }
    for _i, f in ipairs(FROZEN) do
        local got = md5_of(PLUGIN_DIR .. "/" .. f.rel)
        ok(got == f.md5, "10：" .. f.rel .. " 的 md5 仍是 " .. f.md5:sub(1, 8) .. "…",
            "got=" .. tostring(got))
    end
end

-- ================= 11 筛选菜单不能是死胡同 =================
--[[--
工程师在他自测里自己踩到并修掉的一个真 bug：风格筛选菜单里缺了「不设限」这一项，
用户一旦选中某种风格就再也回不到"全部"。根因是 `local style_keys = { nil }` ——
Lua 里 `{ nil }` 是**空表**，ipairs 一步都不走，那一栏被静默吞掉。

为什么单独钉这一条：单项"存在与否"的断言查不到它，**没有任何一项凭空消失，只是少了一项**。
只有"从已选中的状态出发，必须有一条路回到不设限"这种**可达性**断言才抓得住。
他让我在他那套里复现一次；我选择在自己这套里独立钉一条行为级断言——
他的断言验的是菜单项数，我这条验的是"点得到回得来"，两条互为补充。
--]]
section("11. 筛选菜单不能是死胡同：选中之后必须有回到「不设限」的路")
do
    local okf, Fav = pcall(require, "ui/favorites")
    if not (okf and type(Fav) == "table") then
        missing("11：ui/favorites 起得来", tostring(Fav))
        skip("11①-11⑤ 筛选菜单的可达性", "ui/favorites 缺失")
    elseif type(Fav.showFilterMenu) ~= "function" then
        missing("11：Favorites:showFilterMenu 已落地", "favorites.lua 里没有 showFilterMenu")
        skip("11①-11⑤ 筛选菜单的可达性", "showFilterMenu 缺失")
    else
        local saved_filter = Fav.filter
            and { time = Fav.filter.time, style = Fav.filter.style, tag = Fav.filter.tag } or nil
        local okm, menu = pcall(function() return Fav:showFilterMenu(function() end) end)
        ok(okm, "11①：（前置）筛选菜单画得出来", menu)
        if not (okm and type(menu) == "table" and type(menu.item_table) == "table") then
            skip("11②-11⑤ 筛选菜单的可达性", "菜单没画出来 -> " .. tostring(menu))
        else
            local items = menu.item_table
            local style_keys = {}
            for _i, s in ipairs(type(Prompts.STYLES) == "table" and Prompts.STYLES or {}) do
                if type(s) == "table" and type(s.key) == "string" then
                    style_keys[#style_keys + 1] = s.key
                end
            end
            local presets = type(Fav.TIME_PRESETS) == "table" and Fav.TIME_PRESETS or {}
            local days_key = nil
            for _i, p in ipairs(presets) do
                if type(p) == "table" and type(p.days) == "number" and (not days_key) then
                    days_key = p.key
                end
            end
            ok(#items > 0, "11①：（前置）菜单里确有条目（空菜单的话下面全是空转）", #items)
            ok(#style_keys > 0 and days_key ~= nil,
                "11①：（前置）拿得到具体风格 key 与带天数的预设（拿不到就驱动不到死胡同状态）",
                string.format("styles=%d days_key=%s", #style_keys, tostring(days_key)))

            -- 逐项点一遍，每次都**从"已经选中"的状态出发**——死胡同只有在这个状态下才暴露
            local back_style, to_concrete, back_time = nil, nil, nil
            for _i, it in ipairs(items) do
                if type(it) == "table" and type(it.callback) == "function" then
                    if #style_keys > 0 then
                        Fav.filter.style = style_keys[1]
                        if pcall(it.callback) and Fav.filter.style == nil then
                            back_style = it.text
                        end
                        Fav.filter.style = nil
                        if pcall(it.callback) and Fav.filter.style ~= nil then
                            to_concrete = it.text
                        end
                    end
                    if days_key then
                        Fav.filter.time = days_key
                        if pcall(it.callback) and Fav:filterOpts().since == nil then
                            back_time = it.text
                        end
                    end
                end
            end

            ok(type(back_style) == "string",
                "11②：【死胡同】已经选中某种风格时，菜单里**必须有一项**能把风格设回不设限"
                .. "（没有就是用户再也回不到「全部」——`{ nil }` 是空表那个坑）",
                back_style and ("via " .. tostring(back_style))
                    or "逐项点完没有一项能把 filter.style 设回 nil")
            ok(type(to_concrete) == "string",
                "11③：（对照）菜单里也有能把风格设成具体值的项"
                .. "（这条不成立，11② 可能只是因为压根没有风格可选）",
                to_concrete and ("via " .. tostring(to_concrete)) or nil)
            ok(type(back_time) == "string",
                "11④：【死胡同】已经选中「最近 N 天」时，菜单里**必须有一项**能回到不限时间",
                back_time and ("via " .. tostring(back_time)) or nil)
            -- 精确计数：2 个分组标题 + 时间预设 + 「不设限」1 项 + 每种风格 1 项 + 未知风格 1 项。
            -- 少一项就是少一项，单项存在性断言抓不到这个（没有任何一项凭空消失）。
            local expect = 2 + #presets + 1 + #style_keys + 1
            ok(#items == expect,
                "11⑤：菜单项数正好是 " .. expect .. "（2 标题 + " .. #presets .. " 时间预设 + 1 不设限 + "
                .. #style_keys .. " 风格 + 1 未知风格）——少一项就是被静默吞了一项",
                "got=" .. #items)

            if saved_filter and Fav.filter then
                Fav.filter.time, Fav.filter.style, Fav.filter.tag =
                    saved_filter.time, saved_filter.style, saved_filter.tag
            end
        end
    end
end

-- ================= 收尾 =================
restoreSettings()

print("")
print(string.format("TOTAL: %d  PASSED: %d  FAILED: %d  SKIPPED: %d  EXEMPT: %d",
    TOTAL, PASSED, FAILED, SKIPPED, EXEMPT))
if FAILED > 0 then
    print("失败清单：")
    for _i, n in ipairs(FAILED_NAMES) do print("  - " .. n) end
end
print("（测试目录 " .. TEST_DIR .. "；夹具写在临时目录，不碰用户真机 data）")
