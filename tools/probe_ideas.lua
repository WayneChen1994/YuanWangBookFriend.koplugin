--[[--
探针：在 KPW4 上用真 luajit 验证「AI 引导式提问」（kind = ideas）这条路。

单元测试是 QA 的活，这个探针要证明的是**整条链路在真机上真的成立**，
而且重点是两条底线有没有守住：

  ① 防剧透：ideas 的请求体里必须有防剧透声明（system 侧 + user 侧双保险），
     且未读章节的原文必须被物理剪掉（不是靠"嘱咐模型别说"）；
  ② 省钱：max_tokens = 300、命中缓存时零请求、ideas 不写进历史（Store）。

外加一条健壮性：Suggest.parseList 对任何脏输入都不崩、不返回 nil。

做法：把 ywbf/httpclient 换成"假的网络层"，真实跑 Asker:askSync →
DeepSeek:chat 全链路（防剧透管道是真跑的），只是不出网。
这样抓到的是**真正会被发出去的那个 request body**，不是我们自己拼的字符串。

用法（先 ./tools/deploy_kpw4.sh 部署模块本体）：
  scp -i ~/.ssh/id_ywbf_kpw4 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -P 2222 tools/probe_ideas.lua root@192.168.3.89:/mnt/us/ywbf_dev/
  ssh -i ~/.ssh/id_ywbf_kpw4 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -p 2222 root@192.168.3.89 "cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
      YWBF_PLUGIN_DIR=/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin \
      ./luajit /mnt/us/ywbf_dev/probe_ideas.lua"
--]]

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR")
    or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"

-- 行缓冲：Windows 侧 ssh 回传常常丢最后一段输出，行缓冲能显著降低概率
io.stdout:setvbuf("line")

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

--[[--
真机付费调用开关（**默认关闭**）。

YWBF_REAL_CALL=1 时才真的往 api.deepseek.com 发一次请求，用来拿到
"模型真实长什么样"的四条问题（替身网络层编不出来这个）。
一次会话最多跑一次——它是真花钱的，而且拿到的东西只用于人工过目。
开这个开关时：不装网络替身、不写假 Key、不清缓存（那是用户的真实缓存）。
--]]
local REAL = (os.getenv("YWBF_REAL_CALL") == "1")

-- ---------- ① 先装替身，再 require（顺序不能反） ----------
-- ui/asker 会 require 一堆 KOReader UI 模块，无头 luajit 里加载不动，
-- 全部换成空壳。防剧透的关键路径（ywbf/*）仍然用真代码。
package.loaded["gettext"] = function(s) return s end
package.loaded["logger"] = {
    info = function() end, warn = function() end,
    dbg = function() end, err = function() end,
}
package.loaded["ui/widget/infomessage"] = {}
package.loaded["ui/widget/notification"] = {
    SOURCE_ALWAYS_SHOW = 1,
    notify = function() end,
}
package.loaded["ui/widget/textviewer"] = {}
package.loaded["ui/trapper"] = {}
package.loaded["ui/uimanager"] = {}

-- Store 换成记录仪：ideas 不该往历史里写一个字
local store_calls = {}
package.loaded["ywbf/store"] = {
    append = function(_self, fp, item)
        store_calls[#store_calls + 1] = { fp = fp, kind = item and item.kind }
    end,
}

-- ---------- ② 假网络层：只记账 + 回一段预制答案 ----------
-- 模型"应该"输出的样子；故意带上开场白和编号，顺手把 parser 一起测了
local CANNED = "好的，以下是针对这段文字的问题：\n"
    .. "1. 袭人为什么偏偏在这时提玉？\n"
    .. "2. 宝玉为何没有立刻接话？\n"
    .. "3. 「仔细」二字是在提醒谁？\n"
    .. "4. 这屋里的沉默说明了什么？\n"

local http_calls = 0
local bodies = {}

if not REAL then
    package.loaded["ywbf/httpclient"] = {
        post = function(_url, _headers, body, _timeout)
            http_calls = http_calls + 1
            bodies[#bodies + 1] = body
            local json = require("json")
            local reply = {
                choices = { { message = { content = CANNED } } },
                usage = { prompt_tokens = 120, completion_tokens = 60, total_tokens = 180 },
            }
            return json.encode(reply), 200, "OK", nil
        end,
        get = function()
            return nil, 0, "", "probe: no network"
        end,
    }
end

-- ---------- ③ 现在才 require 真模块 ----------
local json = require("json")
local Asker = require("ui/asker")
local Cache = require("ywbf/cache")
local Config = require("ywbf/config")
local Crypto = require("ywbf/crypto")
local DeepSeek = require("ywbf/deepseek")
local Prompts = require("ywbf/prompts")
local Spoiler = require("ywbf/spoiler")
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

-- ---------- ④ 环境 ----------
-- 替身模式一律写测试目录（绝不能碰插件自己的 data/：那里有真 Key、真缓存、真历史）；
-- 真机模式反过来必须读真插件目录，否则拿不到真 Key，用量也记不到真账上。
local TEST_DIR = os.getenv("YWBF_TEST_DIR") or "/mnt/us/ywbf_dev/ideas_data"
Config:init(REAL and PLUGIN_DIR or TEST_DIR)
Cache:init()
local cok, calgo = Crypto:init()
ok(cok, "crypto 可用（只有拿到 key 才能走完真实请求路径）", calgo)

if REAL then
    -- 真机付费调用：有且仅有一次，拿完就退出，不跑后面那些替身断言
    print("=== REAL CALL：真发一次 ideas 请求（一次会话只跑一次） ===")
    ok(DeepSeek:hasApiKey(), "插件目录里有真的 API Key")
    local real_selected = "袭人伸手从项上摘下那块玉来，用手帕包好，塞在褥子底下，"
        .. "说道：“仔细人偷了去。”宝玉只笑了笑，并不理会。"
    local real_page = "（前文）一时众人散了，屋里只剩他两个。\n" .. real_selected
        .. "\n（后文）窗外雪光映进窗纱，映得屋里半明半暗。"
    local content, err = Asker:askSync({
        kind = "ideas",
        selected = real_selected,
        page_text = real_page,
        book_fp = "realprobe0001",
        progress = {
            ok = true, enabled = true, granularity = Spoiler.GRANULARITY_CHAPTER,
            chapter = "第十九章 情切切良宵花解语", chapter_index = 19, chapter_total = 120,
            page = 300, total = 1800, percent = 17,
        },
    })
    if not content then
        print("REAL CALL FAILED: " .. tostring(err))
        os.exit(1)
    end
    print("---- 模型原始输出 ----")
    print(content)
    print("---- Suggest.parseList 之后 ----")
    local list = Suggest.parseList(content, 4)
    for _i, q in ipairs(list) do
        print(string.format("  %d) [%d字] %s", _i, Util.utf8len(q), q))
    end
    print(string.format("REAL CALL OK：解析出 %d 条", #list))

    -- 顺手把自己这条 synthetic 缓存清掉：探针用真插件目录跑，
    -- 用完不该在用户的缓存里留垃圾（合成 book_fp 永远不会再命中，纯占地方）
    local key = Cache:keyFor("realprobe0001", real_selected .. "|", "ideas", Config:get("model"))
    if type(Cache.index) == "table" and Cache.index[key] then
        Cache.index[key] = nil
        Cache:save()
        print("（已清掉探针自己留下的缓存条目）")
    end
    os.exit(0)
end

-- 上一轮跑完会留下缓存，必须清掉：否则第一次调用就命中缓存，
-- 一个请求都发不出去，"请求体里有没有防剧透"这条根本测不到（真踩过）。
Cache:clear()
print("  缓存已清空，当前条目数 = " .. tostring(Cache:count()))
DeepSeek:setApiKey("sk-probe-ideas-fake-key")
ok(DeepSeek:getApiKey() ~= nil, "假 API Key 装好了（不出网，只为走通 pipeline）")

-- ---------- ⑤ 素材：12 章的书，用户读到第 2 章 ----------
local TOC = {}
for i = 1, 12 do
    TOC[i] = { title = "第" .. tostring(i) .. "章 雪夜其" .. tostring(i), page = (i - 1) * 16 + 1 }
end
TOC[3].title = "第三章 密语"

local PROG = {
    ok = true,
    enabled = true,
    granularity = Spoiler.GRANULARITY_CHAPTER,
    chapter = "第二章 故人",
    chapter_index = 2,
    chapter_total = 12,
    page = 25,
    total = 200,
    percent = 12.5,
    toc = TOC,
}

local SELECTED = "袭人笑道：“你仔细那块玉，别又失了。”宝玉只低着头，半晌不言语。"
local PAGE_TEXT = "（已读部分）屋外雪下得紧，檐下铁马叮当作响。\n"
    .. SELECTED .. "\n"
    .. "第三章 密语\n雪停之后，老管家提着灯从廊下走过，谁也没有说话，"
    .. "那块玉其实早就被人换过了，真凶正是提灯的老管家。"

local BOOK_FP = "probeideas0001"

print("=== 0. 配置默认值 ===")
eq(Config:get("ai_suggestions"), true, "ai_suggestions 默认开启")
eq(Config:get("max_tokens_ideas"), 300, "max_tokens_ideas = 300")
eq(Prompts.LIMIT.ideas, 300, "Prompts.LIMIT.ideas = 300")
do
    local msgs = Prompts.build("ideas", { context = "（上下文）" .. SELECTED })
    local user = msgs[2] and msgs[2].content or ""
    ok(user:find("替读到这里的读者提出 4 个", 1, true) ~= nil,
        "TEMPLATES.ideas 真的被 build 用上了（不是掉进 else 分支）")
    ok(user:find("不得涉及尚未读到的内容", 1, true) ~= nil,
        "模板自带「不得涉及尚未读到的内容」")
    ok(user:find("（上下文）", 1, true) ~= nil, "ideas 会拼 context（走 explain/summary 那一组）")
end
print("")

-- ---------- ⑥ 检查 1：请求体里的防剧透 ----------
print("=== 1. ideas 请求体：防剧透声明 + 未读原文被剪掉 ===")
local content1, err1, from_cache1 = Asker:askSync({
    kind = "ideas",
    selected = SELECTED,
    page_text = PAGE_TEXT,
    book_fp = BOOK_FP,
    progress = PROG,
})
ok(content1 ~= nil, "ideas 调用成功", err1)
eq(from_cache1, false, "第一次不是缓存")
eq(http_calls, 1, "第一次调用发出 1 个请求")

do
    local ok_dec, payload = pcall(json.decode, bodies[1] or "")
    ok(ok_dec and type(payload) == "table", "request body 是合法 JSON")
    -- 解码失败也要能往下跑完（把失败原因打出来，而不是崩在一个 nil 上）
    payload = (ok_dec and type(payload) == "table") and payload or {}

    local system, user = "", ""
    if ok_dec and type(payload.messages) == "table" then
        for _i, m in ipairs(payload.messages) do
            if m.role == "system" then system = m.content or "" end
            if m.role == "user" then user = m.content or "" end
        end
    end

    eq(payload.max_tokens, 300, "request body 的 max_tokens = 300")
    eq(payload.model, "deepseek-chat", "model 正常")

    -- system 侧：防剧透说明
    ok(system:find("【防剧透约束（最高优先级）】", 1, true) ~= nil,
        "system 含防剧透抬头")
    ok(system:find("用户当前读到第 2 / 12 章", 1, true) ~= nil,
        "system 含「读到第 2 / 12 章」")

    -- user 侧：双保险那句
    local hint = Prompts.spoilerHint(PROG)
    ok(hint ~= "" and user:find(hint, 1, true) ~= nil,
        "user 含双保险进度提醒（" .. hint .. "）")
    ok(user:find("不得涉及尚未读到的内容", 1, true) ~= nil,
        "user 含「不得涉及尚未读到的内容」")

    -- 关键：未读章节的原文必须在物理上没进 payload
    local whole = system .. "\n" .. user
    ok(whole:find("第三章 密语", 1, true) == nil,
        "未读章节标题「第三章 密语」不在请求体里（被物理剪掉）")
    ok(whole:find("真凶正是提灯的老管家", 1, true) == nil,
        "未读正文「真凶正是提灯的老管家」不在请求体里")
    ok(whole:find("那块玉其实早就被人换过了", 1, true) == nil,
        "未读正文「那块玉其实早就被人换过了」不在请求体里")
    -- 已读部分必须在（否则等于什么都没发）
    ok(whole:find("袭人笑道", 1, true) ~= nil, "已读的选中原文在请求体里")

    print("  ---- system 摘录 ----")
    print("  " .. (Util.utf8sub(system, 120):gsub("\n", "\n  ")))
    print("  ---- user 摘录 ----")
    print("  " .. (Util.utf8sub(user, 200):gsub("\n", "\n  ")))
end
print("")

-- ---------- ⑦ 检查 2：parseList 鲁棒性 ----------
print("=== 2. Suggest.parseList 对任何输入都不崩、不返回 nil ===")
do
    local DIRTY = "袭人\128为什么\237\160\128这样？\n宝玉为何不语？"
    local cases = {
        { name = "nil",            text = nil,        max = 4 },
        { name = "空串",           text = "",         max = 4 },
        { name = "纯空白",         text = "  \n\n\t ", max = 4 },
        { name = "number",         text = 12345,      max = 4 },
        { name = "table",          text = {},         max = 4 },
        { name = "max=nil",        text = CANNED,     max = nil },
        { name = "标准四行(带编号+开场白)", text = CANNED, max = 4 },
        { name = "项目符号",       text = "- 袭人为何提玉？\n* 宝玉为何不语？\n1. 雪夜有何意味？\n4、老管家是谁？", max = 4 },
        { name = "全挤在一行",     text = "袭人为何提玉？宝玉为何不语？雪夜有何意味？老管家是谁？", max = 4 },
        { name = "没写问号",       text = "袭人为何提玉\n宝玉为何不语\n雪夜有何意味", max = 4 },
        { name = "脏字节",         text = DIRTY,      max = 4 },
        { name = "max=2",          text = CANNED,     max = 2 },
        { name = "max=999(压6)",   text = CANNED,     max = 999 },
        { name = "max=0(回落4)",   text = CANNED,     max = 0 },
        { name = "整段不按格式",   text = "好的：这段话里可以提出以下几个问题，袭人为什么偏偏在这个时点提起那块玉呢？", max = 4 },
    }

    for _i, c in ipairs(cases) do
        local want_max = (type(c.max) == "number" and c.max >= 1)
            and math.min(math.floor(c.max), Suggest.MAX_LIMIT) or Suggest.DEFAULT_MAX
        local ok_run, res = pcall(Suggest.parseList, c.text, c.max)
        if not ok_run then
            ok(false, c.name .. "：parseList 抛异常", tostring(res))
        elseif type(res) ~= "table" then
            ok(false, c.name .. "：返回类型不是 table", tostring(res))
        else
            local bad = nil
            for _j, q in ipairs(res) do
                if type(q) ~= "string" then bad = "元素不是字符串" end
                if Util.utf8len(q) > Suggest.MAX_LEN then bad = "超过 20 字：" .. tostring(q) end
                if Util.trim(q) == "" then bad = "空串" end
                if q:find("\n") or q:find("\t") then bad = "含换行/制表符" end
                if Util.sanitizeUtf8(q) ~= q then bad = "含非法 UTF-8：" .. tostring(q) end
                if not (q:sub(-3) == "？" or q:sub(-1) == "?") then bad = "不以问号结尾：" .. tostring(q) end
            end
            if #res > want_max then bad = "条数 " .. #res .. " 超过上限 " .. want_max end
            if bad then
                ok(false, c.name .. "：" .. bad)
            else
                local dump = {}
                for _j, q in ipairs(res) do dump[#dump + 1] = q end
                ok(true, string.format("%s：%d 条 %s", c.name, #res, table.concat(dump, " / ")))
            end
        end
    end

    -- 关键用例单独再钉一遍：标准输出必须真的是 4 条干净问题
    local parsed = Suggest.parseList(CANNED, 4)
    eq(#parsed, 4, "标准输出解析出 4 条")
    ok(parsed[1] == "袭人为什么偏偏在这时提玉？",
        "第 1 条剥掉了编号且完整", parsed[1])
    -- 中文引号只裹住中间那个词时不能剥开头那个「，否则留下孤儿 」
    ok(parsed[3] == "「仔细」二字是在提醒谁？", "第 3 条完整保留了「仔细」这对引号", parsed[3])
    -- 开场白（冒号结尾）不是问题；真正的问题要留下来
    local leadin = Suggest.parseList("好的，以下是我的建议：\n1. 袭人为何提玉？", 4)
    eq(#leadin, 1, "开场白被丢掉，只留下真问题")
    ok(leadin[1] == "袭人为何提玉？", "留下的是那条真问题", leadin[1])
    eq(#Suggest.parseList("当然！以下是我的建议：", 4), 0, "整段只有开场白时一条都不留")

    -- 脏字节用例：确认非法字节确实没进结果
    local dirty_res = Suggest.parseList(DIRTY, 4)
    local leaked = false
    for _i, q in ipairs(dirty_res) do
        if q:find("\237\160\128", 1, true) then leaked = true end
    end
    ok(not leaked, "脏字节没泄漏进解析结果")
end
print("")

-- ---------- ⑧ 检查 3：缓存 ----------
print("=== 3. 同一段文字第二次点击不再发请求（缓存） ===")
do
    local before = http_calls
    local content2, err2, from_cache2 = Asker:askSync({
        kind = "ideas",
        selected = SELECTED,
        page_text = PAGE_TEXT,
        book_fp = BOOK_FP,
        progress = PROG,
    })
    ok(content2 ~= nil, "第二次调用成功", err2)
    eq(from_cache2, true, "第二次命中缓存")
    eq(http_calls - before, 0, "第二次没有发出任何请求")
    ok(content2 == content1, "缓存返回的内容与首次一致")
end
print("")

-- ---------- ⑨ 检查 4：ideas 不写历史 ----------
print("=== 4. ideas 不进 Store（对照组 explain 会写） ===")
do
    local n0 = #store_calls
    local c3 = Asker:askSync({
        kind = "ideas",
        selected = SELECTED,
        page_text = PAGE_TEXT,
        book_fp = BOOK_FP,
        progress = PROG,
    })
    ok(c3 ~= nil, "ideas 再调一次成功（命中缓存）")
    eq(#store_calls - n0, 0, "ideas 没有往 Store 写一个字")

    local n1 = #store_calls
    local c4 = Asker:askSync({
        kind = "explain",
        selected = SELECTED,
        page_text = PAGE_TEXT,
        book_fp = BOOK_FP,
        progress = PROG,
    })
    ok(c4 ~= nil, "对照组 explain 调用成功")
    ok(#store_calls - n1 >= 1,
        "对照组 explain 确实写了 Store（证明跳过只针对 ideas）",
        #store_calls - n1)
end
print("")

print("=== 结论 ===")
print(string.format("http 请求次数 = %d（预期 2：ideas 首次 1 次 + explain 对照 1 次）", http_calls))
if failed == 0 then
    print("PROBE_IDEAS OK  (" .. tostring(passed) .. " 项通过)")
    os.exit(0)
end
print(string.format("PROBE_IDEAS FAILED：%d 项失败 / %d 项通过", failed, passed))
os.exit(1)
