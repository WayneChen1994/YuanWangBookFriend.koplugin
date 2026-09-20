--[[--
收藏与回顾（阶段一）的定向自测。

分两层测，因为"数据是对的"和"接线是对的"是两件事：
  · 数据层：直接用真 `ywbf/store`（只依赖 config/util/json，无头可跑）；
  · 接线层：把 KOReader 的 UI 模块换成记录仪，跑真 `ui/asker` 的
    recordTurn / askSync / showResult —— 只看 Store 接口的话，
    "收藏按钮根本没挂上"这种问题测不出来（它是接线问题，不是接口问题）。

不发网络、不烧 token：HttpClient.post 换成记数 + 回预制答案的替身。
在 KPW4 上跑：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     YWBF_PLUGIN_DIR=/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin \
     YWBF_TEST_DIR=/mnt/us/ywbf_dev/eng_fav_data \
     ./luajit /mnt/us/ywbf_dev/tools/eng_check_favorites.lua

测试目录刻意用**自己的** eng_fav_data，不共用别人的：跨书接口（listFavorites(nil) /
search(q, nil)）会遍历目录里**所有**书，别人留下的一条收藏就会让我的计数对不上，
而那种红是"环境脏"不是"代码错"，排查成本很高。

LuaJIT = Lua 5.1 语义：无位运算符；循环变量一律 _i。
--]]--

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR")
    or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"
local TEST_DIR = os.getenv("YWBF_TEST_DIR") or "/mnt/us/ywbf_dev/eng_fav_data"

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

-- ---------- ① 先装替身，再 require（顺序不能反） ----------
package.loaded["gettext"] = function(s) return s end
package.loaded["logger"] = {
    info = function() end, warn = function() end,
    dbg = function() end, err = function() end,
}
local infos = {}
package.loaded["ui/widget/infomessage"] = {
    new = function(_cls, o)
        local w = { info_text = (type(o) == "table" and o.text) or "" }
        infos[#infos + 1] = w
        return w
    end,
}

-- 通知记录仪：收藏成功/失败的提示必须真的发出去（真机上不传 SOURCE_ALWAYS_SHOW
-- 会被静默丢弃，这个坑踩过，所以这里连 source 一起断言）
local notified = {}
local notify_sources = {}
package.loaded["ui/widget/notification"] = {
    SOURCE_ALWAYS_SHOW = 1,
    -- 必须是 self 打头：真代码是冒号调用 Notification:notify(text, source, true)，
    -- 少了 self 这一位，text / source 会整体后移一位
    -- （第一次写的版本就是这样"绿"着通过了 #notified 断言才发现）
    notify = function(_self, text, source)
        notified[#notified + 1] = text
        notify_sources[#notify_sources + 1] = source
    end,
}

-- TextViewer 记录仪：拿到 buttons_table，就能断言"收藏按钮到底挂没挂上"
local last_viewer = nil
local last_buttons = {}
package.loaded["ui/widget/textviewer"] = {
    new = function(_cls, o)
        last_viewer = nil
        last_buttons = {}
        -- 返回的对象必须**就是**记录下来给 UIManager 的那个：
        -- "谁先关、谁后开"这种断言靠比较 widget 的身份，
        -- 记录选项表 o 、返回另一个表的话，身份永远对不上（我第一版就是这样写的）。
        local obj = {
            button_table = {
                getButtonById = function(_self, id) return last_buttons[id] end,
            },
            -- buttons_table 原样留一份：断言要枚举"都挂了哪些按钮"
            buttons_table = (type(o) == "table" and o.buttons_table) or nil,
        }
        local bt = type(o) == "table" and o.buttons_table or nil
        if type(bt) == "table" then
            for _r, row in ipairs(bt) do
                if type(row) == "table" then
                    for _c, spec in ipairs(row) do
                        if type(spec) == "table" and spec.id then
                            last_buttons[spec.id] = {
                                setText = function(_self, text) spec.text = text end,
                                getText = function(_self) return spec.text end,
                            }
                        end
                    end
                end
            end
        end
        last_viewer = obj
        return obj
    end,
}
-- Menu 记录仪：只看 item_table 就能断言"列表画了几行、分组标题在不在"
local last_menu = nil
package.loaded["ui/widget/menu"] = {
    new = function(_cls, o)
        local m = {
            title = type(o) == "table" and o.title or "",
            item_table = type(o) == "table" and o.item_table or {},
        }
        last_menu = m
        return m
    end,
}

-- InputDialog 记录仪：拿住 buttons 就能真的替用户点「搜索」
local last_input_dialog = nil
package.loaded["ui/widget/inputdialog"] = {
    new = function(_cls, o)
        local d = { buttons = type(o) == "table" and o.buttons or {}, _text = "" }
        function d:getInputText() return self._text end
        function d:onShowKeyboard() end
        function d:onClose() end
        last_input_dialog = d
        return d
    end,
}

-- ConfirmBox 记录仪：删除要二次确认，这里只确认"确实弹了框"
local last_confirm = nil
package.loaded["ui/widget/confirmbox"] = {
    new = function(_cls, o)
        last_confirm = o or {}
        return { info_text = type(o) == "table" and o.text or "" }
    end,
}

--[[--
UIManager 记录仪。

show / close 必须真的"被调用"，它们是接线的一部分：
接线漏了 UIManager:show 的话，页面在真机上根本不出现，
而"少一次 show"在纯数据层的断言里是全绿的。
scheduleIn 直接同步执行：自测不该引入异步，等事件循环会把"有没有跑到"
变成"什么时候跑到"。
--]]
-- ButtonDialog：本轮不测它，但 ui/suggestpicker 会 require 它，缺了会整个崩
package.loaded["ui/widget/buttondialog"] = {
    new = function(_cls, o) return { buttons = type(o) == "table" and o.buttons or {} } end,
}

package.loaded["ui/trapper"] = {
    -- 立刻同步执行：自测里没有事件循环，真排队就永远也跑不到
    wrap = function(_self, fn) return fn() end,
}
--[[--
UIManager 记录仪：连 show / close 的**先后**一起记。

为什么要记先后：团队真机踩过——在还开着的对话框之上再叠一层（尤其带虚拟键盘的
InputDialog），底下那层连同键盘会盖上来，新弹层点不动也关不掉。
所以"先关再开"是接线的一部分，只看"最后有没有弹出输入框"会把它漏掉。
--]]
local uievents = {}
package.loaded["ui/uimanager"] = {
    show = function(_self, widget)
        uievents[#uievents + 1] = { op = "show", widget = widget }
        return widget
    end,
    close = function(_self, widget)
        uievents[#uievents + 1] = { op = "close", widget = widget }
    end,
    scheduleIn = function(_self, _sec, fn)
        if type(fn) == "function" then fn() end
    end,
}
local function firstEvent(op, widget)
    for i, ev in ipairs(uievents) do
        if ev.op == op and ev.widget == widget then return i end
    end
    return nil
end
local function resetUiEvents()
    uievents = {}
end

local http_calls = 0
local NEXT_CONTENT = ""
local NEXT_FINISH = "stop"
package.loaded["ywbf/httpclient"] = {
    post = function(_url, _headers, _body, _timeout)
        http_calls = http_calls + 1
        local json = require("json")
        local reply = {
            choices = {
                { message = { content = NEXT_CONTENT }, finish_reason = NEXT_FINISH },
            },
            usage = { prompt_tokens = 10, completion_tokens = 10, total_tokens = 20 },
        }
        return json.encode(reply), 200, "OK", nil
    end,
    get = function() return nil, 0, "", "check_favorites: no network" end,
}

-- ---------- ② 现在才 require 真模块 ----------
local Asker = require("ui/asker")
local Cache = require("ywbf/cache")
local Config = require("ywbf/config")
local _ = require("gettext")
local DeepSeek = require("ywbf/deepseek")
local Favorites = require("ui/favorites")
local Prompts = require("ywbf/prompts")
local Store = require("ywbf/store")
local Util = require("ywbf/util")

io.stdout:setvbuf("line")

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

-- ---------- ③ 环境：一律写测试目录，绝不动插件自己的 data/ ----------
Config:init(TEST_DIR)
DeepSeek:setApiKey("sk-check-favorites-fake-key")
ok(DeepSeek:getApiKey() ~= nil, "假 API Key 装好了（不出网，只为走通 pipeline）")

--[[--
缓存必须每轮清干净，否则整个脚本只对"第一次跑"有效。

`cache_enabled` 默认是 true，而**命中缓存的那一轮不写历史**（asker.lua 里那个 early
return，设计如此：同样的问题不重复花 token）。所以第二轮开始，askSync / submitAsync
全部走缓存、一条历史都不写，凡断言"有没有写进历史"的用例统统变红——
那种红是上一轮自己留下的缓存，跟被测代码一点关系都没有。
第 19 节就栽在这一次上：头一次 129/0，紧接着再跑就 125/4。

还有个坑：`Cache:get` 只在 index 已经是表时才查（它自己不会 init），
而 init 只有 main.lua 和 `Cache:set` 会触发。所以第一轮这里是"意外冷缓存"，
第二轮因为前面几节的 askSync 已经把磁盘索引加载进内存，第 19 节才真正吃到命中。
**必须先 init 再 clear**：不 init 的话 index_file 还是 nil，clear 写不回磁盘，
后面某个 set 一 init 又把旧数据读回来。
--]]
Cache:init()
Cache:clear()
ok(Cache:count() == 0, "缓存已清空（否则第二次跑起来全在走缓存，测不到写入）")

-- 每轮都从干净状态起：否则"收藏了几条"这种断言会带着上一轮的残留
local FP_A = "favcheck_book_a"
local FP_B = "favcheck_book_b"
local FP_L = "favcheck_legacy"
local FP_F = "favcheck_ui"
Store:clear(FP_A)
Store:clear(FP_B)
Store:clear(FP_L)
Store:clear(FP_F)
--[[--
"老数据没有书名"必须用**专门的新指纹**测，不能用 FP_A。

原因：`Store:noteBook` 是"只增不覆盖"的（已知书名不会被 nil 洗掉，见 store.lua 注释），
前面几节反复往 FP_A 里写过书名，索引里就一直记着"红楼梦"。
用 FP_A 断言 `bookTitle == UNKNOWN_BOOK`，无论实现对错都是红的——
那种红是"测试自己脏"不是"代码错"。从未记过书名的 FP_L 才是干净的输入。
--]]

-- ============================================================ 数据层
print("=== 1. 写入：新字段都在 ===")
local PROG = {
    ok = true, enabled = true, chapter = "第十九章 情切切良宵花解语",
    chapter_index = 19, chapter_total = 120, page = 300, total = 1800, percent = 17,
}
local tid = Store:newTurnId()
Store:append(FP_A, {
    role = "assistant", content = "这是回答正文。",
    kind = "explain", selection = "袭人摘下那块玉",
    turn_id = tid, book_fp = FP_A, book_title = "红楼梦",
    chapter_title = PROG.chapter, chapter_index = PROG.chapter_index, page = PROG.page,
    question = "袭人为什么摘玉？", style = "professional",
})
Store:append(FP_A, {
    role = "user", content = "袭人为什么摘玉？",
    kind = "explain", selection = "袭人摘下那块玉", turn_id = tid,
})
local entries = Store:list(FP_A)
eq(#entries, 2, "1a 写了两条（assistant + user）")
eq(entries[1].role, "assistant", "1b 第一条是回答")
eq(entries[1].turn_id, tid, "1c 回答条带 turn_id")
eq(entries[2].turn_id, tid, "1d 同一轮的提问条带**同一个** turn_id（配对的依据）")
eq(entries[1].book_title, "红楼梦", "1e 书名录进去了")
eq(entries[1].chapter_title, PROG.chapter, "1f 章节名录进去了")
eq(entries[1].chapter_index, 19, "1g 章节序号录进去了")
eq(entries[1].page, 300, "1h 页码录进去了")
eq(entries[1].question, "袭人为什么摘玉？", "1i 提问字段录进去了（列表和检索都靠它）")
eq(entries[1].style, "professional", "1j 风格录进去了（阶段二要按风格筛选，现在不记就补不回来）")
eq(entries[1].favorite, false, "1k 默认是未收藏")

print("=== 2. 提问回查 ===")
eq(Store:questionFor(FP_A, 1), "袭人为什么摘玉？", "2a 从自带 question 字段取到提问")
eq(Store:indexOfTurn(FP_A, tid, "assistant"), 1, "2b 能按 turn_id + role 定位回答条目")
eq(Store:indexOfTurn(FP_A, tid, "user"), 2, "2c 能定位同轮的提问条目")

print("=== 3. 收藏开关 ===")
eq(Store:isFavorite(FP_A, 1), false, "3a 初始未收藏")
eq(Store:setFavorite(FP_A, 1, true), true, "3b 收藏成功，返回新状态 true")
eq(Store:isFavorite(FP_A, 1), true, "3c 收藏状态落盘了")
eq(Store:setFavorite(FP_A, 1, false), false, "3d 取消收藏，返回新状态 false")
eq(Store:isFavorite(FP_A, 1), false, "3e 取消后不再是收藏")
eq(Store:setFavorite(FP_A, 999, true), nil, "3f 越界索引返回 nil（不是 false：调用方能区分'没成功'和'取消了'）")
eq(Store:setFavorite("no_such_book", 1, true), nil, "3g 不存在的书返回 nil")

print("=== 4. 收藏列表：只收回答 + 倒序 ===")
Store:clear(FP_A)
Store:clear(FP_B)
local t1, t2, t3 = Store:newTurnId(), Store:newTurnId(), Store:newTurnId()
Store:append(FP_A, { role = "assistant", content = "回答一", kind = "chat", turn_id = t1, book_title = "红楼梦", question = "问一" })
Store:append(FP_A, { role = "user", content = "问一", kind = "chat", turn_id = t1 })
Store:append(FP_A, { role = "assistant", content = "回答二", kind = "chat", turn_id = t2, book_title = "红楼梦", question = "问二" })
Store:append(FP_A, { role = "assistant", content = "回答三", kind = "chat", turn_id = t3, book_title = "红楼梦", question = "问三" })
-- 同一秒写入会导致 ts 相同，倒序断言就分不出先后：手动把 ts 拉开
local list_a = Store:list(FP_A)
list_a[1].ts = 1000
list_a[3].ts = 3000
list_a[4].ts = 2000
local ok_save = (function()
    -- 直接改内存再写回：Store 没有"改字段"的接口，这里借用 json 层写回
    local json = require("json")
    local raw = Config._read_file(Config.paths.history .. "/" .. FP_A .. ".json")
    local data = require("json").decode(raw)
    data.entries = list_a
    return Config._write_file(Config.paths.history .. "/" .. FP_A .. ".json", json.encode(data))
end)()
ok(ok_save, "4a（前置）时间戳改回写盘成功（否则下面的倒序断言没有意义）")
Store:setFavorite(FP_A, 1, true)
Store:setFavorite(FP_A, 3, true)     -- "回答二"，ts 3000
Store:setFavorite(FP_A, 2, false)    -- user 那条不给收藏
eq(#Store:listFavorites(FP_A), 2, "4b 只列真正被收藏的那 2 条（取消收藏的那条不在）")
local favs = Store:listFavorites(FP_A)
local roles_ok = true
for _i, r in ipairs(favs) do if r.role ~= "assistant" then roles_ok = false end end
ok(roles_ok, "4c 列表里只有回答条目（提问条不会被重复列一遍）")
eq(favs[1].ts, 3000, "4d 倒序：最新的在前")
eq(favs[2].ts, 1000, "4e 倒序：旧的在后")
eq(Store:questionFor(FP_A, favs[1].index), "问二", "4f 列表项能回查出当时的提问")
--[[--
4g–4i 是变异测试补出来的洞：之前这一节先把 user 那条"取消收藏"再断言列表不含它，
于是就算 listFavorites 里的 `role == "assistant"` 判断整个删掉，用例照样全绿
（没有一条 user 记录带着 favorite=true，那条分支根本没走到）。
所以这里**主动把 user 那条标成收藏**，验证脏数据也被挡在列表外面。
--]]
local user_idx = nil
for idx, e in ipairs(Store:list(FP_A)) do
    if e.role == "user" then user_idx = idx end
end
ok(user_idx ~= nil, "4g（前置）这本书里有一条 user 记录（没有的话 4i 就说不清在测什么）")
eq(Store:setFavorite(FP_A, user_idx, true), true, "4h 给 user 那条也打上 favorite 标记")
eq(#Store:listFavorites(FP_A), 2, "4i 被标成收藏的 user 记录也不进列表（列表只收回答）")
local no_user_row = true
for _i, r in ipairs(Store:listFavorites(FP_A)) do
    if r.role == "user" then no_user_row = false end
end
ok(no_user_row, "4j 列表里一条 user 角色都没有")

print("=== 5. 跨书列表 + 书名索引 ===")
Store:clear(FP_B)
local tb = Store:newTurnId()
Store:append(FP_B, { role = "assistant", content = "B 书回答", kind = "chat", turn_id = tb, book_title = "百年孤独", question = "B 问" })
Store:setFavorite(FP_B, 1, true)
--[[--
跨书断言一律**只数自己写进去的那两本**。

为什么不能直接 `eq(#listFavorites(nil), 3)`：跨书接口会遍历目录里的所有书，
万一这个测试目录里还有别人的书（QA 的用例数据就是现成的例子），
计数立刻对不上，而且那种红是"环境脏"不是"代码错"，查起来很费时间。
按 book_fp 过滤之后，断言只跟自己的输入有关。
--]]
local function mine(rows)
    local out = {}
    for _i, r in ipairs(rows or {}) do
        if r.book_fp == FP_A or r.book_fp == FP_B or r.book_fp == FP_F then
            out[#out + 1] = r
        end
    end
    return out
end
local all = mine(Store:listFavorites(nil))
-- 第 4 节末尾 FP_A 上留着 2 条收藏，这里又给 FP_B 加了 1 条：跨书必须是 3 条。
-- 写死 3 而不是"等于两书之和"：两个变量自己跟自己比永远成立，锁不住任何东西。
eq(#all, 3, "5a 跨书列表里应有 A 的 2 条 + B 的 1 条")
eq(#Store:listFavorites(FP_A), 2, "5b（前置）此时 A 自己确实有 2 条（不写这条的话 5a 说不清 3 是哪来的）")
eq(#mine(Store:listFavorites(nil)), #Store:listFavorites(FP_A) + #Store:listFavorites(FP_B),
    "5c 跨书结果 = 各书结果之和（没有多算也没有漏算）")
local books_seen = {}
for _i, r in ipairs(all) do books_seen[r.book_fp] = true end
ok(books_seen[FP_A] == true, "5d 跨书列表里有 A 的书")
ok(books_seen[FP_B] == true, "5e 跨书列表里有 B 的书")
eq(Store:bookTitle(FP_A), "红楼梦", "5f 书名索引能取到 A 书名")
eq(Store:bookTitle(FP_B), "百年孤独", "5g 书名索引能取到 B 书名")
eq(Store:bookTitle("从未见过的书_fp"), Store.UNKNOWN_BOOK, "5h 没记过的书回退成「未知书」")

print("=== 6. 检索：三个字段都要命中 ===")
--[[--
这一节重写过一次。原来的夹具把「麒麟」**同时**塞进了 content 和 selection，
于是 6a 变成<｜hy_place▁holder▁no▁813｜>："命中 1 条"这个结果，只搜 content 也能拿到。
QA 把 store.lua 的 `or in_selection` 删掉验证过：6a 照样 PASS。

教训：**三个字段必须各有各的独占 token**，一个 token 只准出现在一个字段里，
并且要有一条前置断言证明这一点——不然"我想测哪条分支"和"实际测到哪条分支"
没关系，这种用例会静静地空转很多轮。
--]]
Store:clear(FP_A)
local TOK_CONTENT = "靛蓝"    -- 只在回答正文里
local TOK_SELECTION = "橙黄"  -- 只在引用的段落里
local TOK_QUESTION = "凤凰"   -- 只在提问里
local ts_a, ts_b, ts_c = Store:newTurnId(), Store:newTurnId(), Store:newTurnId()
Store:append(FP_A, {
    role = "assistant", content = "回答里写着一个颜色：" .. TOK_CONTENT,
    kind = "chat", selection = "引用的段落是别的话题", question = "这段回答讲了什么？",
    turn_id = ts_a, book_title = "红楼梦",
})
Store:append(FP_A, {
    role = "assistant", content = "这段回答里没有别的颜色",
    kind = "chat", selection = "引用的段落里写着：" .. TOK_SELECTION, question = "这段引用提到了什么？",
    turn_id = ts_b, book_title = "红楼梦",
})
Store:append(FP_A, {
    role = "assistant", content = "这段回答里也没有",
    kind = "chat", selection = "段落里同样没有", question = "提问里有：" .. TOK_QUESTION,
    turn_id = ts_c, book_title = "红楼梦",
})

-- 前置：每个 token 在各自字段里恰好 1 次、在另外两个字段里 0 次。
-- 没有这三条，"命中 1 条"说不清是哪个字段救回来的。
local function hitsInField(tok, field)
    local n = 0
    for _i, e in ipairs(Store:list(FP_A)) do
        if type(e[field]) == "string" and e[field]:find(tok, 1, true) then n = n + 1 end
    end
    return n
end
local function exclusiveAt(tok, own_field, name)
    local others = { content = true, selection = true, question = true }
    others[own_field] = nil
    local clean = hitsInField(tok, own_field) == 1
    for field, _drop in pairs(others) do
        if hitsInField(tok, field) ~= 0 then clean = false end
    end
    ok(clean, name, string.format("%s 在 %s 里 %d 次", tok, own_field, hitsInField(tok, own_field)))
end
exclusiveAt(TOK_CONTENT, "content", "6a（前置）「靛蓝」只出现在回答正文里")
exclusiveAt(TOK_SELECTION, "selection", "6b（前置）「橙黄」只出现在引用的段落里")
exclusiveAt(TOK_QUESTION, "question", "6c（前置）「凤凰」只出现在提问里")

eq(#Store:search(TOK_CONTENT, FP_A), 1, "6d 正文里的关键词能搜到")
eq(#Store:search(TOK_SELECTION, FP_A), 1, "6e 只出现在引用段落里的关键词也能搜到（否则「我记得我引过那段」全落空）")
eq(#Store:search(TOK_QUESTION, FP_A), 1, "6f 只出现在提问里的关键词也能搜到（否则「我记得我问过…」全落空）")
eq(#Store:search("绝无此词xyz", FP_A), 0, "6g 无关关键词返回空")
eq(#Store:search("", FP_A), 0, "6h 空关键词返回空（不能返回全部）")
local hits = Store:search(TOK_CONTENT, nil)
ok(#hits >= 1, "6i 跨书检索也能命中（对照组：检索不是整体失灵）", "#hits=" .. tostring(#hits))
-- 命中必须是**精确**的：只属于其中一条的关键词，不能把另一条也带出来
eq(#Store:search("别的话题", FP_A), 1, "6j 只属于其中一条的关键词不会误命中另一条")

print("=== 7. 向后兼容：老数据没有新字段 ===")
-- 写进 FP_L（从未记过书名的干净指纹，理由见上面的注释）
local json = require("json")
local legacy = {
    entries = {
        { ts = 1, role = "assistant", content = "老回答", kind = "chat", selection = "老段落" },
        { ts = 2, role = "user", content = "老提问", kind = "chat", selection = "老段落" },
    },
}
Config._write_file(Config.paths.history .. "/" .. FP_L .. ".json", json.encode(legacy))
local old = Store:list(FP_L)
eq(#old, 2, "7a 老格式文件读得出来")
eq(old[1].content, "老回答", "7b 老内容没被改写")
eq(Store:questionFor(FP_L, 1), "", "7c 没有 question 字段时回退成空串（不报错、不返回 nil）")
eq(Store:isFavorite(FP_L, 1), false, "7d 没有 favorite 字段时视为未收藏")
eq(Store:bookTitle(FP_L), Store.UNKNOWN_BOOK, "7e 没记过书名的书回退成「未知书」（不返回 nil：拼字符串更安全）")
eq(Store:setFavorite(FP_L, 1, true), true, "7f 老条目也能被收藏（收藏就是加个字段）")
eq(#Store:listFavorites(FP_L), 1, "7g 老条目收藏后能进列表")
eq(Store:listFavorites(FP_L)[1].book_title, nil, "7h 行里 book_title 仍是 nil（书名交给索引回退，不就地编造）")

print("=== 8. 删除之后收藏列表同步 ===")
Store:delete(FP_L, { 1 })
eq(#Store:listFavorites(FP_L), 0, "8a 删掉那条之后收藏列表不再有它（真身只有一份的好处）")

-- ============================================================ 接线层
print("=== 9. askSync 写入的条目字段齐全 + 第六个返回值 ===")
Store:clear(FP_A)
NEXT_CONTENT = "这是模型给的回答。"
NEXT_FINISH = "stop"
local content, _err, _from_cache, _hit, _trunc, stored = Asker:askSync({
    kind = "explain",
    selected = "袭人摘下那块玉",
    page_text = "（已读）屋里只剩他两个。",
    book_fp = FP_A,
    book_title = "红楼梦",
    question = "袭人为什么摘玉？",
    progress = PROG,
})
ok(type(content) == "string" and content ~= "", "9a 请求成功（前置）")
ok(type(stored) == "table", "9b 第六个返回值是表（收藏按钮靠它定位）", tostring(stored))
eq(stored and stored.book_fp or nil, FP_A, "9c stored 带 book_fp")
eq(stored and stored.index or nil, 1, "9d stored.index 指向刚写下的**回答**条目（不是提问那条）")
local e1 = Store:list(FP_A)[1]
eq(e1.role, "assistant", "9e 第一条是回答")
eq(e1.chapter_title, PROG.chapter, "9f 章节名写进去了（进度是现成的，没有重新发请求）")
eq(e1.book_title, "红楼梦", "9g 书名一路传到位了")
eq(e1.question, "袭人为什么摘玉？", "9h 提问写进去了")
eq(e1.style, Prompts.normalizeStyleKey(Config:get("reply_style")), "9i 风格写进去了")
eq(#Store:list(FP_A), 2, "9j 一轮问答写两条（回答 + 提问）")
eq(Store:list(FP_A)[2].turn_id, e1.turn_id, "9k 两条共用 turn_id")

print("=== 10. ideas 仍然不进历史 ===")
Store:clear(FP_A)
NEXT_CONTENT = "1. 问题一？\n2. 问题二？"
local _c10, _e10, _f10, _h10, _t10, stored10 = Asker:askSync({
    kind = "ideas", selected = "袭人摘下那块玉", book_fp = FP_A,
    book_title = "红楼梦", progress = PROG,
})
eq(#Store:list(FP_A), 0, "10a ideas 不落历史（它不是一轮问答）")
eq(stored10, nil, "10b ideas 也不给 stored（没有条目可收藏）")

print("=== 11. 结果卡片挂收藏按钮 ===")
Store:clear(FP_A)
local tid11 = Store:newTurnId()
Store:append(FP_A, {
    role = "assistant", content = "可以收藏的回答", kind = "chat",
    selection = "段落", turn_id = tid11, book_title = "红楼梦", question = "问？",
})
local ref11 = { book_fp = FP_A, index = 1 }
notified = {}
notify_sources = {}
last_viewer = nil
Asker:showResult("远望书友", "可以收藏的回答", nil, "问？", ref11)
ok(type(last_viewer) == "table", "11a（前置）真创建了 TextViewer（否则下面都是假绿）")
local fav_spec = nil
if type(last_viewer) == "table" and type(last_viewer.buttons_table) == "table" then
    for _r, row in ipairs(last_viewer.buttons_table) do
        for _c, spec in ipairs(row) do
            if type(spec) == "table" and spec.id == Asker.FAVORITE_BUTTON_ID then fav_spec = spec end
        end
    end
end
ok(fav_spec ~= nil, "11b 结果卡片上挂出了收藏按钮")
eq(fav_spec and fav_spec.text or nil, _("收藏"), "11c 未收藏时按钮写「收藏」")
ok(type(fav_spec) == "table" and type(fav_spec.callback) == "function", "11d 按钮有回调（不是摆设）")
if type(fav_spec) == "table" and type(fav_spec.callback) == "function" then
    fav_spec.callback()
    eq(Store:isFavorite(FP_A, 1), true, "11e 点一下真的写进了收藏")
    local btn = last_buttons[Asker.FAVORITE_BUTTON_ID]
    eq(btn and btn:getText() or nil, _("取消收藏"), "11f 按钮文字切换成「取消收藏」（没重建整个页面）")
    ok(#notified >= 1, "11g 发出了一条提示（用户得知道收藏成功了）")
    eq(notify_sources[1], 1, "11h 提示带了 SOURCE_ALWAYS_SHOW（不传会被静默丢弃，真机踩过）")
    local said = table.concat(notified, "|")
    ok(said:find(_("已收藏"), 1, true) ~= nil, "11i 提示文案说的是「已收藏」", said)
    fav_spec.callback()
    eq(Store:isFavorite(FP_A, 1), false, "11j 再点一下取消收藏")
    eq(last_buttons[Asker.FAVORITE_BUTTON_ID]:getText(), _("收藏"), "11k 按钮文字切回「收藏」")
end

print("=== 12. 没有定位信息时不挂按钮 ===")
last_viewer = nil
Asker:showResult("远望书友", "没有来源的回答", nil, nil, nil)
local has_fav_12 = false
if type(last_viewer) == "table" and type(last_viewer.buttons_table) == "table" then
    for _r, row in ipairs(last_viewer.buttons_table) do
        for _c, spec in ipairs(row) do
            if type(spec) == "table" and spec.id == Asker.FAVORITE_BUTTON_ID then has_fav_12 = true end
        end
    end
end
ok(not has_fav_12, "12a 没有 ref 时不挂收藏按钮（挂了就是点了没反应的死按钮）")
eq(last_viewer and last_viewer.buttons_table or nil, nil, "12b 没有 ref 时干脆不传 buttons_table（沿用原来的样子）")

print("=== 13. locateStoredTurn：缓存命中时按回答原文回查 ===")
Store:clear(FP_A)
local tid13 = Store:newTurnId()
Store:append(FP_A, {
    role = "assistant", content = "之前那次问到的回答", kind = "chat",
    selection = "段落", turn_id = tid13, book_title = "红楼梦", question = "问？",
})
local ref13 = Asker:locateStoredTurn(FP_A, "之前那次问到的回答", nil)
ok(type(ref13) == "table", "13a 没有 stored 时按回答原文找回来了", tostring(ref13))
eq(ref13 and ref13.index or nil, 1, "13b 找回的是那条 assistant 记录")
eq(Asker:locateStoredTurn(FP_A, "历史上没有这句话", nil), nil, "13c 找不回来就返回 nil（不瞎指一条）")
eq(Asker:locateStoredTurn(nil, "随便", nil), nil, "13d 没有 book_fp 时返回 nil")

print("=== 14. recordTurn 直测：字段与定位 ===")
Store:clear(FP_A)
local ref14 = Asker:recordTurn({
    kind = "chat", selected = "选中文本", book_fp = FP_A,
    book_title = "红楼梦", question = "直接测一轮？",
}, "直接测的回答", PROG, "snarky")
ok(type(ref14) == "table", "14a recordTurn 返回定位信息")
local e14 = Store:list(FP_A)[ref14.index]
eq(e14.content, "直接测的回答", "14b 定位到的是回答条目")
eq(e14.style, "snarky", "14c 传入的 style 被记下来了")
eq(e14.chapter_index, 19, "14d 传入的进度章节被记下来了")
eq(Asker:recordTurn({ kind = "chat", selected = "x" }, "没 fp 的一轮", PROG, "professional"),
    nil, "14e 没有 book_fp 时返回 nil（不写历史、也不给定位）")

print("=== 15. Favorites 列表页：分组、摘要、去重 ===")
--[[--
这一节测 `ui/favorites.lua` 本身。前十四节全绿也说明不了它是对的：
`Store` 里的数据正确，和"列表怎么把这批数据画出来"是两件事。
FP_F 在开头就 clear 过，这里直接用。
--]]
local tf1, tf2 = Store:newTurnId(), Store:newTurnId()
Store:append(FP_F, {
    role = "assistant", content = "第一条回答：这里写得很长，长到列表页必须把它收成摘要才放得下",
    kind = "chat", selection = "引用段落一", question = "第一问问的是什么？",
    turn_id = tf1, book_title = "测试书名", chapter_title = "第三章",
    chapter_index = 3, page = 42,
})
Store:append(FP_F, { role = "user", content = "第一问问的是什么？", kind = "chat", turn_id = tf1 })
Store:append(FP_F, {
    role = "assistant", content = "第二条回答", kind = "chat",
    selection = "引用段落二", turn_id = tf2, book_title = "测试书名",
})
Store:append(FP_F, { role = "user", content = "第二轮的上下文行", kind = "chat", turn_id = tf2 })
Store:setFavorite(FP_F, 1, true)
Store:setFavorite(FP_F, 3, true)
local rows15 = Store:listFavorites(FP_F)
eq(#rows15, 2, "15a 两条回答进了收藏列表（对照组：列表不是空的）")

-- 倒序是"ts 大的在前"，两条同一秒写入时次序不稳定，所以按内容取行而不是按下标取
local function rowWith(rs, c)
    for _i, r in ipairs(rs or {}) do
        if r.content == c then return r end
    end
    return nil
end
local r15a = rowWith(rows15, "第一条回答：这里写得很长，长到列表页必须把它收成摘要才放得下")
local r15b = rowWith(rows15, "第二条回答")
ok(r15a ~= nil and r15b ~= nil, "15b（前置）两条行都取到了")

local txt15a = Favorites:rowText(r15a, true)
ok(txt15a:find("测试书名", 1, true) ~= nil, "15c 行里带书名", txt15a)
ok(txt15a:find("第 3 章 第三章", 1, true) ~= nil, "15d 行里带位置（章节号 + 章节名）", txt15a)
ok(txt15a:find("第一问问的是什么？", 1, true) ~= nil, "15e 行里带提问（不是带回答正文）", txt15a)
ok(txt15a:find("这里写得很长", 1, true) == nil, "15f 行里不放回答正文（一行只放得下提问）", txt15a)
-- 摘要必须按**字符**截：裸 string.sub 会把汉字切一半，这里是它的哨兵
ok(Util.utf8len(txt15a) > 0 and txt15a:find("�", 1, true) == nil,
    "15g 摘要没有字节级半个字符（乱码哨兵）")

local txt15b = Favorites:rowText(r15b, true)
ok(txt15b:find("第二轮的上下文行", 1, true) ~= nil,
    "15h 没有 question 字段时退回同轮 user 那条（长按直译的场景）", txt15b)

local body15 = Favorites:entryText(r15a)
local p_sel = body15:find("【引用的段落】", 1, true)
local p_q = body15:find("【你的提问】", 1, true)
local p_reply = body15:find("【" .. Prompts.PERSONA_NAME .. "的回复】", 1, true)
ok(p_sel ~= nil and p_q ~= nil and p_reply ~= nil, "15i 详情页四个块都在", body15)
ok(p_sel < p_q and p_q < p_reply, "15j 详情页按「段落 → 提问 → 回复」排序（回想时的自然顺序）")
ok(body15:find("测试书名 · 第 3 章 第三章", 1, true) ~= nil, "15k 详情页开头是「书名 · 位置」")

print("=== 16. 列表页的空态与分组 ===")
infos = {}
last_menu = nil
Favorites:showList(_("全部收藏"), {}, nil, true, nil)
ok(last_menu == nil, "16a 一条都没有时不建 Menu（画个空列表没有任何意义）")
eq(#infos, 1, "16b 一条都没有时给一条说明（对照组：别让用户对着黑屏猜）")
infos = {}
last_menu = nil
-- 跨书分组：先取跨书列表，但只留自己这两本（理由同第 5 节）
local cross15 = mine(Store:listFavorites(nil))
ok(#cross15 >= 2, "16c（前置）跨书列表里至少有自己的两条", "#cross15=" .. tostring(#cross15))
Favorites:showList(_("全部收藏"), cross15, nil, true, nil)
ok(last_menu ~= nil, "16d 有行时真的建了 Menu")
local items16 = last_menu and last_menu.item_table or {}
local header16 = items16[1]
eq(header16 and header16.select_enabled, false, "16e 第一行是分组标题（select_enabled = false）")
-- 分组标题的先后按书名字符串的字节序，中文具体的先后没必要锁死；
-- 这里锁"它是一个已知书名"，锁具体哪本只会让用例脆。
ok(header16 and (header16.text == "测试书名" or header16.text == "百年孤独"),
    "16f 分组标题是本批数据里的某个书名", header16 and header16.text)
eq(#items16, #cross15 + 2, "16g 两本书各多一条标题行（行没丢也没多）")

print("=== 17. 检索：去重与输入回调 ===")
--[[--
列表页现在多了一行"筛选入口"，所以数 item 个数时要把它剔掉，
不然每次列表结构一变，这里的计数就得跟着改一遍（而且改的时候分不清
是"去重坏了"还是"多了一行"）。
--]]
local function contentRows(items)
    local out = {}
    for _i, it in ipairs(items or {}) do
        local text = type(it.text) == "string" and it.text or ""
        if text:find(_("筛选"), 1, true) ~= 1 then out[#out + 1] = it end
    end
    return out
end
-- 同一个词同时出现在提问和 user 那条里：不去重的话列表里会出现完全相同的两行
last_menu = nil
Favorites:runSearch("第一问问", FP_F)
local items17 = last_menu and last_menu.item_table or {}
eq(#items17 - #contentRows(items17), 1,
    "17a（前置）列表里确实多了一行筛选入口（下面计数要先剔掉它，别把结构变化当成去重坏了）")
eq(#contentRows(items17), 1, "17b 提问与 user 行同时命中时只出一行（去重）")

last_input_dialog = nil
infos = {}
Favorites:askSearch(FP_F)
ok(type(last_input_dialog) == "table", "17c（前置）弹出了输入框")
if type(last_input_dialog) == "table" then
    local btn_search = last_input_dialog.buttons and last_input_dialog.buttons[1]
        and last_input_dialog.buttons[1][2]
    last_input_dialog._text = "   "
    btn_search.callback()
    eq(#infos, 1, "17d 全是空格时给提示（不能拿着空词去搜出全部）")
    last_menu = nil
    last_input_dialog._text = "第二条回答"
    btn_search.callback()
    local items17d = last_menu and last_menu.item_table or {}
    eq(#items17d - #contentRows(items17d), 1, "17e（前置）这条路径同样多了一行筛选入口")
    eq(#contentRows(items17d), 1, "17f 从输入框一路点到结果列表：能搜到那一条")
end

print("=== 18. 设置里的「我的收藏」入口 ===")
--[[--
这一节看着像配置检查，其实是**防崩**：settings.lua 里多了一个 require("ui/favorites")，
模块名写错的话整张设置页在真机上直接打不开（KOReader 吞异常，用户只会看到菜单进不去）。
所以这里真的 require 一次、真的把三个入口各点一遍。
--]]
local SettingsUI = require("ui/settings")
local sub18 = SettingsUI:buildFavoritesMenu({})
ok(type(sub18) == "table", "18a buildFavoritesMenu 返回菜单表")
--[[--
为什么这里盯的是**个数**而不只是"有那三个字"：阶段二往这个菜单里加了两个导出入口，
任何一处把整张表换掉（比如误写成只返回三个旧条目）都能被这条钉住——
只断言三项各自的 text 存在，会把"多出来的两个去哪了"放过去。
--]]
eq(#sub18, 5, "18b 五个入口：本书/全部/搜索/导出本书/导出全部")
local texts18 = {}
for _i, it in ipairs(sub18 or {}) do texts18[it.text] = true end
ok(texts18[_("本书收藏")] == true, "18c 有「本书收藏」")
ok(texts18[_("全部收藏")] == true, "18d 有「全部收藏」")
ok(texts18[_("搜索收藏与历史")] == true, "18e 有「搜索收藏与历史」")
ok(texts18[_("导出 Markdown（本书）")] == true, "18f 有「导出 Markdown（本书）」")
ok(texts18[_("导出 Markdown（全部）")] == true, "18g 有「导出 Markdown（全部）」")
-- 对照组：只可能在阶段二之前存在过的名字不该出现在菜单里
-- （没有这条，"18b 绿"也可能来自别处多塞了一个无关条目）
local stale18 = nil
for _i, it in ipairs(sub18 or {}) do
    if type(it.text) == "string" and it.text:find("Markdown", 1, true) ~= nil
        and it.text ~= _("导出 Markdown（本书）") and it.text ~= _("导出 Markdown（全部）") then
        stale18 = it.text
    end
end
ok(stale18 == nil, "18h（对照组）菜单里没有第三个多余的 Markdown 条目", tostring(stale18))

local function findEntry(sub, label)
    for _i, it in ipairs(sub or {}) do
        if it.text == label then return it end
    end
    return nil
end
local all18 = findEntry(sub18, _("全部收藏"))
last_menu = nil
infos = {}
all18.callback()
ok(last_menu ~= nil, "18i 点「全部收藏」画出了列表页（不是空态）")
local search18 = findEntry(sub18, _("搜索收藏与历史"))
last_input_dialog = nil
search18.callback()
ok(type(last_input_dialog) == "table", "18j 点「搜索收藏与历史」弹出了输入框")
local book18 = findEntry(sub18, _("本书收藏"))
-- 假插件：返回值全 nil（模拟"当前没打开书"），走 InfoMessage 分支而不是崩
infos = {}
book18.callback()
eq(#infos, 1, "18k 没打开书时点「本书收藏」给提示而不报错")
-- 有书时应当按书名索引带出列表
local plugin18 = {
    bookFingerprint = function() return FP_F end,
    bookTitle = function() return "测试书名" end,
}
local sub18b = SettingsUI:buildFavoritesMenu(plugin18)
last_menu = nil
findEntry(sub18b, _("本书收藏")).callback()
ok(last_menu ~= nil, "18l 打开书时点「本书收藏」按那本书画出列表")
eq(last_menu and last_menu.title, "《测试书名》的收藏", "18m 列表标题是《书名》的收藏")
--[[--
设置页的导出入口也要真的点一遍。
第 25 节测的是 Favorites:exportBook / exportAll 本身；这里测的是**从设置菜单能不能走到那**
（回调里漏写 `Favorites:` 前缀、写成 `.` 调用，在这一层才会红）。
--]]
--[[--
按名字点一项也会失败（变异时就是故意删掉入口），这里统一改成"点了算通过、
点了不吃到 nil 就当时显式判死"，不让整个脚本崩在第 18 节。
--]]
local function callEntry(sub, label)
    local it = findEntry(sub, label)
    if it and type(it.callback) == "function" then
        it.callback()
        return true
    end
    ok(false, "（前置）菜单里找不到可点的「" .. tostring(label) .. "」")
    return false
end
local Export18 = require("ywbf/export")
infos = {}
if callEntry(sub18b, _("导出 Markdown（本书）")) then
    local msg18 = infos[1] and infos[1].info_text or ""
    ok(msg18:find(Export18.DIR_NAME or "export", 1, true) ~= nil,
        "18n 点「导出 Markdown（本书）」真的导出了（提示里带着文件路径）", msg18)
end
infos = {}
if callEntry(sub18b, _("导出 Markdown（全部）")) then
    local msg18b = infos[1] and infos[1].info_text or ""
    ok(msg18b:find(Export18.DIR_NAME or "export", 1, true) ~= nil,
        "18o 点「导出 Markdown（全部）」也真的导出了", msg18b)
end
infos = {}
if callEntry(sub18, _("导出 Markdown（本书）")) then
    local msg18c = infos[1] and infos[1].info_text or ""
    eq(msg18c:find("export", 1, true), nil,
        "18p（对照组）没打开书时点导出本书，给的是「没有打开的书」而不是路径", msg18c)
end

print("=== 19. 轻问路径（toastcard → submitAsync）的书名透传 ===")
--[[--
这一节是 toastcard 补 `book_title` 之后加的，也是**唯一**能证明那条链路真的接通的测试：
submitAsync 走的是异步通道（Queue + Trapper），跟 askSync 不是一条路，
书目在它这一侧丢没丢，前面十八节一条也测不出来。
--]]
local ToastCard = require("ui/toastcard")
-- 指纹每轮换一个：书名索引是**只增不覆盖**的（books.json 跨轮留存，也没有"忘掉"接口），
-- 用固定指纹的话，19f 会被上一轮留下的索引救回来——那种绿跟这次的改动无关。
local FP_T = "favcheck_toast_" .. tostring(os.time())
Store:clear(FP_T)
NEXT_CONTENT = "轻问问到的回答"
NEXT_FINISH = "stop"
local plugin19 = {}   -- submitAsync 只需要一个能接 last_reply 的表
last_input_dialog = nil
ToastCard:open(plugin19, {
    selected = "袭人摘下那块玉",
    page_text = "（已读）屋里只剩他两个。",
    book_fp = FP_T,
    book_title = "轻问时的书名",
    question = "轻问问了什么？",
    progress = PROG,
})
local btns19 = last_input_dialog and last_input_dialog.buttons or {}
ok(type(last_input_dialog) == "table", "19a（前置）轻问输入框弹出来了")
last_input_dialog._text = "轻问问了什么？"
btns19[#btns19][1].callback()
local t19 = Store:list(FP_T)
eq(#t19, 2, "19b 轻问这条异步路径也写下了两条历史（回答 + 提问）")
local a19 = nil
for _i, e in ipairs(t19) do
    if e.role == "assistant" then a19 = e end
end
ok(type(a19) == "table", "19c（前置）写下的历史里有回答条目")
eq(a19 and a19.book_title or nil, "轻问时的书名",
    "19d 轻问路径写下的书名 == 喂进去的那个书名（不是占位常量）")
eq(a19 and a19.content or nil, "轻问问到的回答",
    "19e（防假绿）这条是刚发的请求写下的，不是缓存回灌的（缓存命中那一轮不写历史）")
eq(Store:bookTitle(FP_T), "轻问时的书名", "19f 书名索引记下了同一个书名（「全部收藏」分组靠它）")
-- 对照组：不带书名时确实没有书名。没有这条，"19d 绿"也可能只是别处写死了同一个值。
-- 换一段选中文本、换一个回答正文：不然这一轮会命中上一轮/上一条的缓存，啥也测不到。
Store:clear(FP_T)
NEXT_CONTENT = "对照组回答"
last_input_dialog = nil
ToastCard:open(plugin19, {
    selected = "另一段被选中的文字", book_fp = FP_T, progress = PROG,
})
local btns19b = last_input_dialog and last_input_dialog.buttons or {}
last_input_dialog._text = ""
btns19b[#btns19b][1].callback()
local ctrl19 = nil
for _i, e in ipairs(Store:list(FP_T)) do
    if e.role == "assistant" then ctrl19 = e end
end
ok(type(ctrl19) == "table", "19g（前置）对照组也写下了一条回答")
eq(ctrl19 and ctrl19.book_title or nil, nil,
    "19h 对照组：opts 不给书名时条目就没有书名（19d 那个值不可能来自别处）")
eq(ctrl19 and ctrl19.content or nil, "对照组回答",
    "19i（防假绿）对照组也是真的发了请求（19h 得在真的写盘了的前提下才作数）")

print("=== 20. ideas 永不进收藏池 ===")
--[[--
这条守的是**未来**：今天唯一会写历史的入口（asker.lua 的 recordTurn）已经把 ideas 挡在
外面了，真机 data/history/ 里一条 ideas 都没有。所以这条守卫现在防不住任何真实数据——
留着它是为了不让"ideas 不是一轮问答"这条数据层语义押在**一个调用点**上。
阶段二要加导入 / 批量整理，append 的入口一多，单点迟早漏。

测试也必须绕过 asker 直写 Store，模拟那个未来的入口：
走 asker 的话，asker 自带的那道关会把 ideas 挡住，这条守卫永远轮不到上场。
--]]
local FP_I = "favcheck_ideas_" .. tostring(os.time())
Store:clear(FP_I)
Store:append(FP_I, {
    role = "assistant", content = "候选问题一？", kind = "ideas",
    turn_id = Store:newTurnId(), book_title = "红楼梦", question = "候选问题一？",
})
Store:append(FP_I, {
    role = "assistant", content = "真回答", kind = "explain",
    turn_id = Store:newTurnId(), book_title = "红楼梦", question = "真的问过？",
})
Store:setFavorite(FP_I, 1, true)
Store:setFavorite(FP_I, 2, true)
eq(Store:isFavorite(FP_I, 1), true,
    "20a（前置）ideas 那条确实被标上了收藏（没有这条，20b 说不清是被挡住还是根本没标）")
-- QA 建议补的这条：20a 只证明了"标得上"，没证明"两条都真的写进去了"。
-- 少了它，万一 ideas 那条 append 静默失败，症状会落到 20e（want=2 但历史只有 1 条），
-- 归因要多绕一步。
eq(#Store:list(FP_I), 2, "20a'（前置）两条都真的写进历史了")
local fav20 = Store:listFavorites(FP_I)
eq(#fav20, 1, "20b 收藏列表里只剩那条真回答（ideas 那条被挡住了）")
eq(fav20[1] and fav20[1].kind or nil, "explain", "20c 留下来的不是 ideas")
-- 回查要同一口径：列表里没有它，按原文也不许把它找回来
-- （缓存命中时 locateStoredTurn 走的就是 indexOfContent，那是收藏的第二条入口）
eq(Store:indexOfContent(FP_I, "候选问题一？", "assistant"), nil,
    "20d 按原文回查也找不回 ideas（收藏池不能从另一条路漏出去）")
eq(Store:indexOfContent(FP_I, "真回答", "assistant"), 2,
    "20e 对照组：真回答按原文找得回来（20d 的 nil 不是“一律找不回来”）")

print("=== 21. 备注与标签（数据层）===")
--[[--
落盘断言一律**直接 json.decode 磁盘文件**：只看内存的话，"改了没存"和"改了存了"
长得一模一样（QA 的硬规矩，我照抄）。
--]]
local FP_N = "favcheck_note_" .. tostring(os.time())
Store:clear(FP_N)
local tn1 = Store:newTurnId()
Store:append(FP_N, {
    role = "assistant", content = "有备注的回答", kind = "chat",
    selection = "段落", turn_id = tn1, book_title = "红楼梦",
    question = "会写备注的那一条？", style = "professional",
})
Store:setFavorite(FP_N, 1, true)
local rawNote = function()
    local json21 = require("json")
    local raw = Config._read_file(Config.paths.history .. "/" .. FP_N .. ".json")
    return json21.decode(raw).entries
end

eq(Store:noteOf(FP_N, 1), nil, "21a 没写过备注时返回 nil（不是空串：UI 要区分「有」和「没有」）")
eq(#Store:tagsOf(FP_N, 1), 0, "21b 没写过标签时返回空表（不返回 nil，调用方不必判空）")
eq(Store:setNote(FP_N, 1, "这里要对照第五回的判词"), true, "21c 写备注成功")
eq(Store:noteOf(FP_N, 1), "这里要对照第五回的判词", "21d 读回的是刚写的那条")
eq(rawNote()[1].note, "这里要对照第五回的判词", "21e 备注真的落到磁盘上了")
-- 对照组：只改了 note，其余字段一个都不许变（补默认值覆盖老字段 = 数据损坏）
eq(rawNote()[1].question, "会写备注的那一条？", "21f 写备注没有把提问冲掉")
eq(rawNote()[1].favorite, true, "21g 写备注没有把收藏标记冲掉")
eq(rawNote()[1].style, "professional", "21h 写备注没有把风格冲掉")

-- 标签：中英文逗号混用、带空格、有重复、有空项
eq(Store:setTags(FP_N, 1, "伏笔，人物, 伏笔 ,, 细节 ,"), true, "21i 写标签成功")
local tags21 = Store:tagsOf(FP_N, 1)
eq(#tags21, 3, "21j 中文与英文逗号都能切、去空白、去重、丢空串（伏笔/人物/细节）")
eq(tags21[1], "伏笔", "21k 第一个标签是「伏笔」（顺序按用户输入的先后）")
eq(tags21[3], "细节", "21l 最后一个标签是「细节」")
eq(rawNote()[1].tags[1], "伏笔", "21m 标签也真的落盘了")
eq(Store:setTags(FP_N, 1, { "人物", "  ", "人物", "" }), true, "21n 传数组也能写")
eq(#Store:tagsOf(FP_N, 1), 1, "21o 数组里的空项与重复项同样被清掉")
eq(Store:setTags(FP_N, 1, nil), true, "21p 清空标签的接口是通的")
eq(#Store:tagsOf(FP_N, 1), 0, "21q 清空之后没有标签")
eq(rawNote()[1].tags, nil, "21r 清空后磁盘上是 nil 而不是空数组（「有」「没有」不留歧义）")
--[[--
再补一条"输入不是 nil、但一个标签都没剩下"的情形。

只有 `setTags(fp, i, nil)` 这一条的话，normalizeTagList 里那句
`if #out == 0 then return nil end` 是碰不到的——nil 输入在更靠前的分支就已经返回了，变异把那行改成 `return out`（写 {} 进文件）
依然 257/0 全绿。也就是说"清空的另一种写法"根本没有用例兜着，这就是一次**变异幸存**。
用户真实会这么干：标签框里敲几个逗号再保存。
--]]
eq(Store:setTags(FP_N, 1, "  ， ，"), true, "21r2 输入全是空白与逗号时也能写（清空的另一种写法）")
eq(#Store:tagsOf(FP_N, 1), 0, "21r3 全空白输入没有留下标签")
eq(rawNote()[1].tags, nil,
    "21r4 全空白输入时磁盘上同样是 nil 而不是空数组（\"有没有标签\"不留歧义）")
eq(Store:setNote(FP_N, 1, ""), true, "21s 用空串也能清备注")
eq(Store:noteOf(FP_N, 1), nil, "21t 清完之后备注是 nil")

-- 老数据兼容：没有 note/tags 键的条目
Store:clear(FP_N)
local json21b = require("json")
Config._write_file(Config.paths.history .. "/" .. FP_N .. ".json", json21b.encode({
    entries = { { ts = 1, role = "assistant", content = "老回答", kind = "chat", selection = "老段落" } },
}))
eq(Store:noteOf(FP_N, 1), nil, "21u 老条目的备注是 nil（没被补成空串）")
eq(#Store:tagsOf(FP_N, 1), 0, "21v 老条目的标签是空表（没被补成 nil 以外的怪东西）")
eq(Store:setNote(FP_N, 1, "给老条目补一条备注"), true, "21w 老条目也能写备注")
eq(Store:noteOf(FP_N, 1), "给老条目补一条备注", "21x 老条目的备注读得回来")
eq(Store:list(FP_N)[1].content, "老回答", "21y 老条目的正文没被动过")

print("=== 22. 按时间与风格筛选 ===")
local FP_S = "favcheck_filter_" .. tostring(os.time())
Store:clear(FP_S)
local DAY = 86400
local now22 = os.time()
-- 三条：一条今天（有风格）、一条 10 天前（另一种风格）、一条 40 天前（**没有** style 字段）
Store:append(FP_S, {
    role = "assistant", content = "今天的回答", kind = "chat", turn_id = Store:newTurnId(),
    book_title = "红楼梦", question = "今天问的？", style = "snarky", ts = now22,
})
Store:append(FP_S, {
    role = "assistant", content = "十天前的回答", kind = "chat", turn_id = Store:newTurnId(),
    book_title = "红楼梦", question = "十天前问的？", style = "professional", ts = now22 - 10 * DAY,
})
Store:append(FP_S, {
    role = "assistant", content = "很久以前的老回答", kind = "chat", turn_id = Store:newTurnId(),
    book_title = "红楼梦", question = "很早问的？",
})
-- Store:append 会用 os.time() 覆盖 ts（makeRecord 不收 ts），所以这里直接改磁盘上的 ts
local json22 = require("json")
local data22 = json22.decode(Config._read_file(Config.paths.history .. "/" .. FP_S .. ".json"))
data22.entries[1].ts = now22
data22.entries[2].ts = now22 - 10 * DAY
data22.entries[3].ts = now22 - 40 * DAY
ok(Config._write_file(Config.paths.history .. "/" .. FP_S .. ".json", json22.encode(data22)),
    "22a（前置）三条时间戳改回写盘成功")
eq(#Store:filterRows(Store:list(FP_S), nil), 3, "22b 不传筛选条件时全部保留（老调用方行为不变）")
eq(#Store:search("回答", FP_S), 3, "22c search 不传 opts 时跟以前一样（尾部参数没改变既有调用方）")
eq(#Store:filterRows(Store:list(FP_S), { since = now22 - 7 * DAY }), 1,
    "22d 最近 7 天：只留今天那条")
eq(#Store:filterRows(Store:list(FP_S), { since = now22 - 30 * DAY }), 2,
    "22e 最近 30 天：今天的和十天前的")
-- 端点含：正好等于边界的那一条必须留下来（用户选"7 天"时脑子里包含此刻）
eq(#Store:filterRows(Store:list(FP_S), { since = now22 }), 1, "22f 起点端点含：ts == since 的留下")
eq(#Store:filterRows(Store:list(FP_S), { ["until"] = now22 - 40 * DAY }), 1,
    "22g 截止端点含：ts == until 的留下")
eq(#Store:filterRows(Store:list(FP_S), { since = now22 - 5 * DAY, ["until"] = now22 - 20 * DAY }), 0,
    "22h 区间内没有条目时返回空（不是返回全部）")
-- 风格：老数据（缺 style）按"未知风格"单独筛，不能被当成任意一种风格
eq(#Store:filterRows(Store:list(FP_S), { style = "snarky" }), 1, "22i 按风格筛：毒舌那条")
eq(#Store:filterRows(Store:list(FP_S), { style = "professional" }), 1, "22j 按风格筛：专业那条")
eq(#Store:filterRows(Store:list(FP_S), { style = Store.UNKNOWN_STYLE }), 1,
    "22k 老数据（没有 style）能被「未知风格」单独筛出来")
local unk22 = Store:filterRows(Store:list(FP_S), { style = Store.UNKNOWN_STYLE })
-- 写成 `unk22[1] and ... or nil`：万一这里一条都查不到（变异时就会），
-- 也不能让整个脚本崩在第 22 节——崩了 23/24/25 三节全跑不到，故障面被放大到看不清归因。
eq(unk22[1] and unk22[1].content or nil, "很久以前的老回答",
    "22l 被筛出来的正是那条老回答（不是随手挑了一条）")
eq(#Store:filterRows(Store:list(FP_S), { style = "snarky", since = now22 - 7 * DAY }), 1,
    "22m 时间 + 风格可以叠加（两个条件都满足才留）")
eq(#Store:filterRows(Store:list(FP_S), { style = "snarky", since = now22 - 20 * DAY }), 1,
    "22n 叠加时风格优先，时间放宽也不多留（毒舌那条只有一条）")
eq(#Store:search("回答", FP_S, { since = now22 - 7 * DAY }), 1,
    "22o search 带 opts：关键词 + 时间一起生效")
-- 标签筛选
Store:setTags(FP_S, 1, "人物，伏笔")
eq(#Store:filterRows(Store:list(FP_S), { tag = "人物" }), 1, "22p 按标签筛：命中打了标签的那条")
eq(#Store:filterRows(Store:list(FP_S), { tag = "没有这个标签" }), 0, "22q 没有的标签筛出空")

print("=== 23. Export.render（纯函数，不碰磁盘）===")
local Export = require("ywbf/export")
local FP_E = "favcheck_export_" .. tostring(os.time())
-- 分组是按 **book_fp** 走 Store:bookTitle 的，不是按条目里的 book_title 字段，
-- 所以"B 书"必须真的是另一个指纹（另一个文件），否则两本会并成一个分组标题。
local FP_E2 = "favcheck_export_other_" .. tostring(os.time())
Store:clear(FP_E)
Store:clear(FP_E2)
Store:append(FP_E, {
    role = "assistant", content = ("这是一段很长的回答正文"):rep(20), kind = "chat",
    selection = ("这是引用的段落"):rep(10), turn_id = Store:newTurnId(),
    book_title = "红楼梦", chapter_title = "第十九章 情切切良宵花解语", chapter_index = 19,
    page = 300, question = "袭人为什么摘玉？", style = "professional", ts = now22,
})
Store:append(FP_E2, {
    role = "assistant", content = "B 书的回答", kind = "chat", turn_id = Store:newTurnId(),
    book_title = "百年孤独", question = "B 问？", ts = now22 - 3 * DAY,
})
-- 同一本书里的第二条（更早）：组内时间倒序只有同组才测得到，
-- 拿 A 书一条和 B 书一条比位置，比的其实是分组顺序。
Store:append(FP_E, {
    role = "assistant", content = "A 书更早的一条", kind = "chat", turn_id = Store:newTurnId(),
    book_title = "红楼梦", question = "A 书更早的问？", style = "friendly", ts = now22 - 1 * DAY,
})
local json23 = require("json")
local data23 = json23.decode(Config._read_file(Config.paths.history .. "/" .. FP_E .. ".json"))
data23.entries[1].ts = now22
data23.entries[2].ts = now22 - 1 * DAY
ok(Config._write_file(Config.paths.history .. "/" .. FP_E .. ".json", json23.encode(data23)),
    "23a（前置）导出夹具落盘成功")
Store:setFavorite(FP_E, 1, true)
Store:setFavorite(FP_E, 2, true)
Store:setFavorite(FP_E2, 1, true)
Store:setNote(FP_E, 1, "对照第五回判词")
Store:setTags(FP_E, 1, "人物，伏笔")
-- 两条书各一条 + 同书的第二条：跨书分组和组内倒序都能测
local rows23 = {}
for _i, r in ipairs(Store:listFavorites(FP_E)) do rows23[#rows23 + 1] = r end
for _i, r in ipairs(Store:listFavorites(FP_E2)) do rows23[#rows23 + 1] = r end
eq(#rows23, 3, "23b（前置）三条都进了收藏列表")
local md23 = Export:render(rows23, { title = "测试导出" })
ok(type(md23) == "string" and #md23 > 0, "23c render 返回非空字符串")
ok(md23:find("# 测试导出", 1, true) ~= nil, "23d 标题用的是传入的 title")
ok(md23:find("## 《百年孤独》", 1, true) ~= nil, "23e 按书分组：B 书单独一节")
ok(md23:find("## 《红楼梦》", 1, true) ~= nil, "23f 按书分组：A 书单独一节")
ok(md23:find("《百年孤独》", 1, true) < md23:find("《红楼梦》", 1, true),
    "23g 分组按书名排序（两节都出现，且次序稳定）")
ok(md23:find("- 位置：第 19 章 第十九章 情切切良宵花解语", 1, true) ~= nil, "23h 带上章节名")
ok(md23:find("【引用的段落】", 1, true) ~= nil, "23i 带上引用的段落")
ok(md23:find("【我的提问】", 1, true) ~= nil, "23j 带上我的提问")
ok(md23:find("【" .. Prompts.PERSONA_NAME .. "的回复】", 1, true) ~= nil,
    "23k 角色名从 PERSONA_NAME 拼出来（不写死「AI」）")
ok(md23:find("【我的备注】", 1, true) ~= nil, "23l 带上备注")
ok(md23:find("- 标签：人物、伏笔", 1, true) ~= nil, "23m 带上标签（顺序按用户写的先后：人物、伏笔）")
-- 对照组：标签分隔用「、」且顺序不能反，反着也搜得到的话说明上面那条在比错东西
ok(md23:find("- 标签：伏笔、人物", 1, true) == nil,
    "23m'（对照组）标签顺序没有被重排（== 上面那条比的是有意义的东西）")
local time_line = md23:match("- 时间：%d%d%d%d%-%d%d%-%d%d %d%d:%d%d")
ok(time_line ~= nil, "23n 时间是格式化过的（不是裸时间戳）", tostring(time_line))
ok(md23:find(tostring(now22), 1, true) == nil, "23o 导出物里没有裸时间戳")
-- 完整：正文不许被截短（"回顾"不是"摘要"）
ok(md23:find(("这是一段很长的回答正文"):rep(20), 1, true) ~= nil,
    "23p 回答正文完整保留（没有为了排版砍掉）")
ok(md23:find(("这是引用的段落"):rep(10), 1, true) ~= nil, "23q 引用段落也完整保留")
ok(md23:find("…", 1, true) == nil, "23r 正文里没有截断省略号（标题行除外，本夹具没有长提问）")
-- 中文安全：不许出现半个字（U+FFFD 替换字符哨兵）
ok(md23:find("\239\191\189", 1, true) == nil, "23s 导出物里没有半个汉字（乱码哨兵）")
-- 组内时间倒序（两条同在《红楼梦》里：新的必须在前）
local pos_new = md23:find("袭人为什么摘玉？", 1, true)
local pos_old = md23:find("A 书更早的问？", 1, true)
ok(pos_new ~= nil and pos_old ~= nil and pos_new < pos_old,
    "23t 组内按时间倒序（今天那条在前，昨天那条在后）")
local md23_empty = Export:render({}, {})
ok(md23_empty:find("这一批没有可导出的收藏", 1, true) ~= nil,
    "23u 没有行时也给一篇完整的文档（不是空字符串，也不是 nil）")

print("=== 24. Export.write（只写在 data/ 之内）===")
-- 返回值是 **(path, err)**：路径在第一位，失败时第一个是 nil、第二个是原因。
-- 不要写成 (ok, path)——那样 `local p = Export:write(...)` 会拿到 true，
-- 而 true 是 truthy，`if p then` 照样通过、然后拿 true 当路径用，会静默出错。
local path24, err24 = Export:write(rows23, { title = "落盘测试" })
-- 成功时**第二位必须是 nil**：只断言"第一位是路径"的话，
-- `return path, "假的错误原因"` 这种实现照样全绿（错误通道没人把着，QA 的 M20 实证过）。
ok(type(path24) == "string" and path24 ~= "" and err24 == nil,
    "24a 写盘成功（且没有夹带错误原因）", tostring(err24))
-- 前缀用 Export:dir() 而不是字面量 "/data/export/"：跟 24g 同一口径，
-- 否则将来数据目录一改，这里会假红。
local dir24 = Export:dir()
ok(type(dir24) == "string" and type(path24) == "string"
    and path24:sub(1, #dir24 + 1) == (dir24 .. "/"),
    "24b 文件落在插件 data/export/ 之内（零污染）", tostring(path24))
local disk24 = Config._read_file(path24)
ok(type(disk24) == "string" and #disk24 > 0, "24c 磁盘上真的有内容")
eq(Export:render(rows23, { title = "落盘测试" }), disk24,
    "24d 写进去的字节 == render 的输出（没有第二套渲染逻辑）")
local path24b = Export:write(rows23, {})
ok(type(path24b) == "string" and path24b ~= path24,
    "24e 同一秒连着导出两次不会互相覆盖（短随机后缀）")
local path24c, err24c = Export:write({}, {})
-- 注意别写成 `tostring(err24c) or tostring(path24c)`：tostring 恒返回非空字符串、
-- 非空字符串在 Lua 里恒 truthy，所以 or 右侧**永不执行**，失败时反而看不到原因。
ok(type(path24c) == "string" and path24c ~= "",
    "24f 空行也导出成功（给一篇说明文档，而不是失败）", tostring(err24c or path24c))
eq(Export:dir(), (Config.paths.data .. "/export"), "24g 导出目录是 data/export")

-- 失败分支必须返回 (nil, 原因)：三条失败路径（dir 未准备好 / ensureDir 失败 /
-- _write_file 失败）过去一条都没验，"写失败要能说出来"这个契约没人把着。
-- 这里把数据目录指到一个建不出来的位置，逼它走失败路径。
do
    -- 两个替身的**取值和还原都放在 pcall 外面**：区段内一旦有东西抛异常，
    -- pcall 吞掉之后被改坏的 Config 会一直留着，污染后面 24l/24m 和第 25 节，
    -- 表现为"一片红"而不是"一条红"，排查时会误判成导出整体坏了。
    local saved_data = Config.paths.data
    local saved_write = Config._write_file
    local ok_pcall = pcall(function()
        -- 分支 1：dir() 没准备好（paths.data 为空）——export.lua 的第一条 return
        Config.paths.data = nil
        local p1, e1 = Export:write(rows23, {})
        ok(p1 == nil and type(e1) == "string" and e1 ~= "",
            "24h 数据目录没准备好时返回 (nil, 原因)", tostring(p1))
        Config.paths.data = saved_data

        -- 分支 2：ensureDir 失败——目录建不出来的落点
        -- （用 /dev/null 之下的路径：不依赖 /proc 一定存在）
        Config.paths.data = "/dev/null/ywbf_no_such_dir"
        local p2, e2 = Export:write(rows23, {})
        ok(p2 == nil and type(e2) == "string" and e2 ~= "",
            "24i 导出目录建不出来时返回 (nil, 原因)", tostring(p2))
        Config.paths.data = saved_data

        -- 分支 3：_write_file 自己失败——把落盘函数临时换成必失败的替身
        Config._write_file = function() return false end
        local p3, e3 = Export:write(rows23, {})
        ok(p3 == nil and type(e3) == "string" and e3 ~= "",
            "24j 写文件失败时返回 (nil, 原因)", tostring(p3))
    end)
    Config.paths.data = saved_data
    Config._write_file = saved_write
    ok(ok_pcall, "24k 失败路径用例本身跑完了（没崩在断言里）")
end

-- 越界写：文件名里带 `../../` 也必须写回导出目录之内。
-- 今天 UI 不传 name（不可达），但既然加了 safeName 这道输入校验，
-- 就得有一条断言盯着它——否则它哪天被改掉没人知道。
do
    -- 必须**精确相等**，不能只查前缀：不设防时返回的字符串是
    -- `dir .. "/" .. "../../evil_probe.md"`，它照样以 `dir .. "/"` 开头，
    -- 前缀断言会绿——越界是文件系统解析之后才发生的，字符串形状看不出来。
    -- （这条踩过：第一版写成前缀比较，去掉 safeName 的变异仍然 264/0 全绿。）
    local evil = Export:write(rows23, { name = "../../evil_probe.md" })
    ok(type(evil) == "string" and evil == (dir24 .. "/evil_probe.md"),
        "24l 文件名里带 ../ 也写不到插件目录之外（会被收成纯文件名）", tostring(evil))
    -- 控制字符（含 NUL）必须被清掉：C 层会把 `probe\0.md` 截断成 `probe` 落盘，
    -- 返回的路径里却仍带 NUL —— **返回值撒谎**，谁拿去读都读不到。
    local nul_path = Export:write(rows23, { name = "probe\0.md" })
    ok(type(nul_path) == "string" and nul_path:find("%c") == nil,
        "24m 文件名里的控制字符被清掉（返回的路径就是真实落点）", tostring(nul_path))
    -- 24m 验的是**字符串形状**；这条验**落点**：返回的路径必须真的打得开。
    -- 否则"返回的名字清干净了、真实落盘仍被 C 层截断成 probe"这种实现照样绿——
    -- 这跟上面那条前缀比较是同一类坑，只是规模小得多。
    local f_nul = type(nul_path) == "string" and io.open(nul_path, "r") or nil
    ok(f_nul ~= nil and nul_path == (dir24 .. "/probe.md"),
        "24n 控制字符清理后返回的路径真的打得开（路径 == 真实落点）", tostring(nul_path))
    if f_nul then f_nul:close() end
end

print("=== 25. UI 接线：备注 / 标签 / 筛选 / 导出 ===")
-- 详情页的备注与标签按钮
Store:clear(FP_E)
local te1 = Store:newTurnId()
Store:append(FP_E, {
    role = "assistant", content = "可以加备注的回答", kind = "chat", selection = "段落",
    turn_id = te1, book_title = "红楼梦", question = "加了备注的那条？", style = "professional",
})
resetUiEvents()
last_viewer = nil
Favorites:showEntry({ book_fp = FP_E, index = 1 }, nil)
local bt25 = (type(last_viewer) == "table" and type(last_viewer.buttons_table) == "table")
    and last_viewer.buttons_table or {}
local function findButton(rows, wanted_id)
    for _r, row in ipairs(rows or {}) do
        for _c, spec in ipairs(row) do
            if type(spec) == "table" and spec.id == wanted_id then return spec end
        end
    end
    return nil
end
local btn_note = findButton(bt25, "ywbf_fav_note")
local btn_tags = findButton(bt25, "ywbf_fav_tags")
ok(btn_note ~= nil, "25a 详情页挂出了「备注」按钮")
ok(btn_tags ~= nil, "25b 详情页挂出了「标签」按钮")
--[[--
下面整段都放在 `if btn_note and btn_tags` 里：做变异验证时会真的把这两个按钮摘掉，
摘掉以后还要保证脚本**到这里就判死而不是崩在一个 nil 上**——
崩了的话后面十来条用例一条都跑不到，"备注按钮没了"这一个故障就会把整节都染红，
归因变成猜谜。
--]]
if not (btn_note and btn_tags) then
    ok(false, "25b'（前置）备注 / 标签按钮缺了一个，25c 之后的用例无从执行")
else
-- 叠弹层是这条线上的头号坑：点按钮必须先关掉详情页再开输入框
resetUiEvents()
last_input_dialog = nil
btn_note.callback()
ok(type(last_input_dialog) == "table", "25c 点「备注」弹出了输入框")
ok(firstEvent("close", last_viewer) ~= nil, "25d 弹输入框之前先把详情页关了（不然键盘会压住输入区）")
-- 先把两个下标取出来再比：少了这一步，"没发那一帧事件"会在比较运算上炸掉脚本，
-- 而不是老老实实地在这一条上报红。
local ev25_close = firstEvent("close", last_viewer)
local ev25_show = firstEvent("show", last_input_dialog)
ok(ev25_close ~= nil and ev25_show ~= nil and ev25_close < ev25_show,
    "25e 顺序是「先关详情页 → 再开输入框」，不是同时开着")
-- 真的存一条备注进去
eq(Store:noteOf(FP_E, 1), nil,
    "25e'（前置）写之前这条本来没有备注（25f 那个值只能来自这次输入）")
last_input_dialog._text = "从 UI 写进去的备注"
local save25 = last_input_dialog.buttons[1][2]
save25.callback()
eq(Store:noteOf(FP_E, 1), "从 UI 写进去的备注", "25f 从输入框保存的备注进数据层了")
eq(firstEvent("close", last_input_dialog) ~= nil, true, "25g 保存时先关掉输入框（不叠层）")
ok(#infos >= 1, "25h 保存成功给了提示（用户得知道存住了）")
-- 标签：中文逗号也要切得开
resetUiEvents()
last_input_dialog = nil
findButton(bt25, "ywbf_fav_tags").callback()
eq(#Store:tagsOf(FP_E, 1), 0,
    "25i'（前置）写之前这条本来没有标签（25i/25j 的结果只能来自这次输入）")
last_input_dialog._text = "伏笔，人物"
last_input_dialog.buttons[1][2].callback()
eq(#Store:tagsOf(FP_E, 1), 2, "25i 中文逗号在 UI 这条路上也能切成两个标签")
eq(Store:tagsOf(FP_E, 1)[1], "伏笔", "25j 第一个标签是「伏笔」")
end

-- 筛选菜单
resetUiEvents()
last_menu = nil
local filtered_done = 0
Favorites.filter.time = "all"
Favorites.filter.style = nil
local menu25 = Favorites:showFilterMenu(function() filtered_done = filtered_done + 1 end)
local items25 = last_menu and last_menu.item_table or {}
-- 精确个数：两组标题 + 全部时间预设 +（全部风格 + 每种风格 + 未知风格）
-- 写成等式而不是"至少有这么多"：少一项（比如忘了加未知风格）也算错。
eq(#items25, 2 + #Favorites.TIME_PRESETS + 1 + #Prompts.STYLES + 1,
    "25k 筛选菜单候选齐全（时间预设 + 风格 + 未知风格，每一项都不多不少）")
eq(#Prompts.STYLES >= 2, true, "25k'（前置）Prompts.STYLES 里确实有多种风格（25m 才有意义）")
eq(items25[1].select_enabled, false, "25l 第一项是分组标题（不可点）")
-- 风格候选必须来自 Prompts.STYLES，不许另抄一份
local style_labels = {}
for _i, s in ipairs(Prompts.STYLES) do style_labels[#style_labels + 1] = Prompts.styleText(s.key) end
local missing_style = nil
for _i, label in ipairs(style_labels) do
    local found = false
    for _j, item in ipairs(items25) do
        if type(item.text) == "string" and item.text:find(label, 1, true) then found = true end
    end
    if not found then missing_style = label end
end
ok(missing_style == nil, "25m 每种风格都在菜单里（候选取自 Prompts.STYLES，不是抄的列表）",
    tostring(missing_style))
-- 点一个时间预设：条件改了、菜单关了、回调跑了
local picked = nil
for _i, item in ipairs(items25) do
    if type(item.text) == "string" and item.text:find("最近 7 天", 1, true) then picked = item end
end
ok(picked ~= nil, "25n（前置）菜单里有「最近 7 天」")
picked.callback()
eq(Favorites.filter.time, "d7", "25o 选中之后筛选条件真的变了")
eq(filtered_done, 1, "25p 选中之后回调跑了（列表会被重建）")
ok(firstEvent("close", menu25) ~= nil, "25q 选中之后筛选菜单自己关掉了（不叠在列表上）")

--[[--
专门钉住"回到不限风格"这一项。

favorites.lua 曾经用 `local style_keys = { nil }` 当候选列表的头：Lua 里 `{ nil }`
是一张**空表**（# == 0），ipairs 一步也不走，于是"全部风格"这一项凭空消失——
用户一旦选了某种风格，就再也找不到回到"全部"的路。
断言"每种风格都在菜单里"（25m）查不出这个洞：那一条只看有没有缺，而这里缺的
是"什么都没选"这一项。所以这里按名字精确计数，并且真的点它一下。
--]]
local all_style, all_style_n = nil, 0
for _i, item in ipairs(items25) do
    if type(item.text) == "string" and item.text:find(_("全部风格"), 1, true) then
        all_style = item
        all_style_n = all_style_n + 1
    end
end
eq(all_style_n, 1, "25r' 菜单里有且只有一项「全部风格」（回得到「不限风格」）")
if all_style then
    Favorites.filter.style = "snarky"
    all_style.callback()
    eq(Favorites.filter.style, nil, "25r'' 选「全部风格」能把风格条件清掉（不是死胡同）")
end
ok(all_style ~= nil, "25r'''（前置）上面那条真的点到了「全部风格」这一项")
Favorites.filter.style = nil

-- 列表页应用筛选
local FP_L2 = "favcheck_listfilter_" .. tostring(os.time())
Store:clear(FP_L2)
Store:append(FP_L2, { role = "assistant", content = "新收藏", kind = "chat",
    turn_id = Store:newTurnId(), book_title = "红楼梦", question = "新问？", style = "snarky" })
Store:append(FP_L2, { role = "assistant", content = "老收藏", kind = "chat",
    turn_id = Store:newTurnId(), book_title = "红楼梦", question = "老问？", style = "professional" })
local json25 = require("json")
local data25 = json25.decode(Config._read_file(Config.paths.history .. "/" .. FP_L2 .. ".json"))
data25.entries[1].ts = os.time()
data25.entries[2].ts = os.time() - 60 * DAY
ok(Config._write_file(Config.paths.history .. "/" .. FP_L2 .. ".json", json25.encode(data25)),
    "25r（前置）列表筛选夹具落盘成功")
Store:setFavorite(FP_L2, 1, true)
Store:setFavorite(FP_L2, 2, true)
Favorites.filter.time = "all"
Favorites.filter.style = nil
last_menu = nil
Favorites:showList(_("全部收藏"), Store:listFavorites(FP_L2), nil, false, nil, { show_filter = true })
local items25b = last_menu and last_menu.item_table or {}
eq(#items25b, 3, "25s 不筛选时：1 条筛选入口 + 2 行内容")
ok(type(items25b[1].text) == "string" and items25b[1].text:find(_("筛选"), 1, true) ~= nil,
    "25t 第一行是筛选入口", items25b[1].text)
Favorites.filter.time = "d7"
last_menu = nil
Favorites:showList(_("全部收藏"), Store:listFavorites(FP_L2), nil, false, nil, { show_filter = true })
eq(#(last_menu and last_menu.item_table or {}), 2,
    "25u 最近 7 天：只剩 1 条筛选入口 + 1 行（那条 60 天前的被筛掉）")
Favorites.filter.style = "snarky"
last_menu = nil
Favorites:showList(_("全部收藏"), Store:listFavorites(FP_L2), nil, false, nil, { show_filter = true })
eq(#(last_menu and last_menu.item_table or {}), 2, "25v 再加风格筛选，仍然只剩那条毒舌的")
Favorites.filter.style = "professional"
infos = {}
last_menu = nil
Favorites:showList(_("全部收藏"), Store:listFavorites(FP_L2), nil, false, nil, { show_filter = true })
ok(last_menu == nil, "25w 筛没了的时候不画列表（没有行可画）")
local msg25x = infos[1] and infos[1].info_text or nil
ok(#infos == 1 and type(msg25x) == "string" and msg25x:find(_("筛选"), 1, true) ~= nil,
    "25x 筛没了和本来就没有是两种提示（提示里点明是筛选的缘故）", tostring(msg25x))
-- 对照组：没开筛选、本来就没有行时，给的是"还没有收藏"那一类提示
infos = {}
last_menu = nil
Favorites:showList(_("全部收藏"), {}, nil, false, _("还没有收藏。"), { show_filter = true })
ok(#infos >= 1 and (infos[1].info_text == nil
        or infos[1].info_text:find(_("筛选"), 1, true) == nil),
    "25y 对照组：本来就没有行时提示里不提筛选", infos[1] and infos[1].info_text)
Favorites.filter.time = "all"
Favorites.filter.style = nil

-- 导出入口
infos = {}
local ok25z, path25z = Favorites:exportBook(FP_L2)
ok(ok25z == true, "25z 导出本书收藏成功", tostring(path25z))
local msg25aa = infos[1] and infos[1].info_text or nil
ok(type(msg25aa) == "string" and msg25aa:find(tostring(path25z), 1, true) ~= nil,
    "25aa 导出后把文件路径告诉了用户（他要连电脑去拷）", tostring(msg25aa))
infos = {}
local ok25bb = Favorites:exportBook(nil)
eq(ok25bb, false, "25bb 没打开书时导出直接拒绝（不去建一个空文件）")
infos = {}
local ok25cc, path25cc = Favorites:exportAll()
ok(ok25cc == true, "25cc 导出全部收藏成功", tostring(path25cc))
ok(path25cc ~= path25z, "25dd 两次导出是两个文件（不互相覆盖）")

print(string.format("=== 合计 %d 通过 / %d 失败 ===", passed, failed))
if failed > 0 then os.exit(1) end
os.exit(0)
