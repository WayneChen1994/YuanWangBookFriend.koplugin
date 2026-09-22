--[[--
远望书友 YuanWangBookFriend.koplugin
KOReader AI 辅助阅读插件

@module koplugin.YuanWangBookFriend
--]]--

-- 关键：插件加载期间 PluginLoader 会把插件根目录注入 package.path，
-- 因此所有 require 必须在文件顶部完成（运行时再 require 子模块会找不到路径）。
local Config = require("ywbf/config")
local Chapter = require("ywbf/chapter")
local Crypto = require("ywbf/crypto")
local DeepSeek = require("ywbf/deepseek")
local Queue = require("ywbf/queue")
local Cache = require("ywbf/cache")
local Store = require("ywbf/store")
local Context = require("ywbf/context")
local Prompts = require("ywbf/prompts")
local Spoiler = require("ywbf/spoiler")
local Util = require("ywbf/util")
local SettingsUI = require("ui/settings")
local Asker = require("ui/asker")
local ChatDialog = require("ui/chatdialog")
local ToastCard = require("ui/toastcard")

local Dispatcher = require("dispatcher")  -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local YuanWangBookFriend = WidgetContainer:extend{
    name = "yuanwangbookfriend",
    is_doc_only = false,
}

function YuanWangBookFriend:init()
    -- self.path 由 PluginLoader 注入（插件自身根目录），全部数据只写在这里
    Config:init(self.path or "plugins/YuanWangBookFriend.koplugin")
    Crypto:init()
    Queue:init()
    Cache:init()

    -- 结构性兜底：任何提问入口即使忘了传 progress，Asker 也能自己把进度取回来
    Asker:setProgressProvider(function() return self:progress() end)

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self:registerHighlightButtons()
    logger.info("YWBF: plugin initialized, plugin path =", Config.paths.plugin)
end

-- ---------- 选中文本与书籍信息 ----------

function YuanWangBookFriend:bookFingerprint()
    local doc = self.ui and self.ui.document
    local path = doc and doc.file
    if not path then return "unknown" end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local size, mtime = nil, nil
    if ok_lfs then
        local attr = lfs.attributes(path)
        if attr then size, mtime = attr.size, attr.modification end
    end
    return Util.bookFingerprint(path, size, mtime)
end

--[[--
真的打开了一本书吗？

**不要拿 `bookFingerprint()` 的返回值判空**：它没书时返回字符串 `"unknown"`，
不是 nil。曾经 `ui/settings.lua` 用 `(fp ~= nil)` 判断"有没有书"，于是那个判断恒为真，
没开书时「本书收藏」「导出 Markdown（本书）」照样挂在那儿，点进去只会弹一句
"当前没有打开的书"（真机反馈 Bug 1）。

为什么不顺便把 bookFingerprint 改成返回 nil：它有 5 个调用点
（本文件 noteCurrentBook / gather / showLastReply、ui/settings.lua 的 currentBookFp），
历史文件的键名、展示文案都建在"永远是个字符串"这个前提上。改它波及面太大，
不如补一个只回答"有没有书"的布尔接口。

@return bool
--]]
function YuanWangBookFriend:hasOpenBook()
    local doc = self.ui and self.ui.document
    if type(doc) ~= "table" then return false end
    local path = doc.file
    return type(path) == "string" and path ~= ""
end

-- 取当前页文本用于构造上下文；失败返回 nil（退化为只用选中内容）
function YuanWangBookFriend:pageText(highlight)
    local doc = self.ui and self.ui.document
    if not doc then return nil end
    local xp = highlight and highlight.selected_text and highlight.selected_text.pos0
    if not xp and doc.getXPointer then
        local ok_xp, cur = pcall(doc.getXPointer, doc)
        if ok_xp then xp = cur end
    end
    local txt = nil
    if doc.getTextFromXPointer and xp then
        local ok, t = pcall(doc.getTextFromXPointer, doc, xp)
        if ok and type(t) == "string" and t ~= "" then txt = t end
    end
    if not txt and doc.info and doc.info.has_pages and doc.getPageText then
        local page = (self.ui.paging and self.ui.paging.current_page) or 1
        local ok2, ptxt = pcall(doc.getPageText, doc, page)
        if ok2 and type(ptxt) == "string" and ptxt ~= "" then txt = ptxt end
    end
    if txt then
        logger.info("YWBF: page text len =", #txt)
    else
        logger.info("YWBF: page text unavailable, fallback to selection only")
    end
    return txt
end

--[[--
当前书名（只给展示和收藏列表用）。

两级取法，都做了 pcall：
  · 文档元数据里的 title（epub 的 dc:title，最准）；
  · 取不到就用文件名（去目录、去扩展名）——PDF 和元数据缺失的 epub 靠它。

拿不到就返回 nil，由 Store 侧回退显示"未知书"。
绝不在 ywbf/ 纯逻辑层里摸 UI：这里取到的是字符串，传下去的也是字符串。
--]]
function YuanWangBookFriend:bookTitle()
    local doc = self.ui and self.ui.document
    if doc and doc.getProps then
        local ok, props = pcall(doc.getProps, doc)
        if ok and type(props) == "table" and type(props.title) == "string" and props.title ~= "" then
            return props.title
        end
    end
    local path = doc and doc.file
    if type(path) == "string" and path ~= "" then
        local name = path:match("([^/\\]+)$") or path
        name = name:gsub("%.[^./\\]+$", "")
        if name ~= "" then return name end
    end
    return nil
end

--[[--
取当前文档的目录；拿不到返回 nil。

pcall 包住：不同引擎的 getToc 在损坏的书上会抛异常，而"拿不到目录"只意味着
这一次回填做不了——绝不能因为它把整个「我的问答收藏」入口带崩。
--]]
local function currentToc(ui)
    local doc = type(ui) == "table" and ui.document or nil
    if type(doc) ~= "table" or type(doc.getToc) ~= "function" then return nil end
    local ok, toc = pcall(doc.getToc, doc)
    if not ok or type(toc) ~= "table" or #toc == 0 then return nil end
    return toc
end

--[[--
把"细粒度章节"（真正的回目）**回填到已经存在的收藏上**。

为什么非补这一刀不可：收藏里的章节原本取自防剧透那套**粗粒度**结果
（《红楼梦》会把第 19 回、第 25 回都归到一级条目「红楼梦 上」），
老数据里因此只有错的那一对字段。只改写入路径的话，用户现在那几条收藏
还是写着「红楼梦 上」，他打开列表会认为我们根本没修（真机反馈的 Bug 2）。

范围：**只补当前打开的那本书**（别的文件我们手上没有它的目录，
拿别的书的目录去给一条记录算章节，等于编数据）。这不是偷懒，是这件事的边界——
写进注释里，别让以后有人"顺手"放宽它。

哪些条目需要补：**有 `page`**（没有页码定位不了）**且两个 fine 字段都缺**
（已经有了的不动，避免把后来写入的值覆盖回去）。

@return number 实际改动条数（0 = 没书 / 没目录 / 没有要补的）
--]]
function YuanWangBookFriend:backfillFineChapters()
    if not self:hasOpenBook() then return 0 end
    local toc = currentToc(self.ui)
    if not toc then return 0 end
    local fp = self:bookFingerprint()

    local ok_patch, changed = pcall(Store.patch, Store, fp, function(entry)
        if type(entry) ~= "table" then return nil end
        if entry.chapter_fine_title ~= nil or entry.chapter_fine_index ~= nil then
            return nil
        end
        local page = type(entry.page) == "number" and entry.page or nil
        if page == nil then return nil end
        local fine = Spoiler.fineChapterInfo(toc, page)
        local patch = {}
        if type(fine.title) == "string" and fine.title ~= "" then
            patch.chapter_fine_title = fine.title
        end
        if type(fine.index) == "number" then
            patch.chapter_fine_index = fine.index
        end
        if patch.chapter_fine_title == nil and patch.chapter_fine_index == nil then
            return nil
        end
        return patch
    end)

    if not ok_patch then
        logger.info("YWBF: fine chapter backfill failed, keeping entries untouched")
        return 0
    end
    if type(changed) == "number" and changed > 0 then
        logger.info("YWBF: fine chapter backfilled, count =", changed)
    end
    return type(changed) == "number" and changed or 0
end

--[[--
当前这本书的元数据（`doc:getProps()` 的结果）。

pcall 包住是必须的：不同文档引擎的 getProps 实现不一样，crengine / pdf / djvu
都可能在某些书上抛异常（或损坏的元数据上）。拿不到就返回 nil，由 Store 那边
回退到"从书名串里认"——**拿不到元数据不能把记书名这件事一起搞砸**。

@return table|nil
--]]
function YuanWangBookFriend:bookProps()
    local doc = self.ui and self.ui.document
    if doc and doc.getProps then
        local ok, props = pcall(doc.getProps, doc)
        if ok and type(props) == "table" then return props end
    end
    return nil
end

--[[--
把"当前这本书叫什么"记进书名索引。

为什么要在打开书时单独记一次：跨书收藏列表要按书名分组，而书名索引的兜底来源
是"写入历史时顺带写"（ywbf/store.lua 的 append）。一本刚打开、还没有任何问答的书
根本不会走到那里，跨书列表里就找不到它的名字。
只在 onReaderReady 里调（每本书一次），不放 gather：gather 每次长按都会跑，
没必要为了一条没变的信息反复写文件。
--]]
function YuanWangBookFriend:noteCurrentBook()
    local fp = self:bookFingerprint()
    local title = self:bookTitle()
    if fp and title then
        -- 第三个参数是 doc:getProps()：作者/出版社/ISBN 从它那儿来，
        -- 拿不到（nil）也不会影响记书名本身。
        Store:noteBook(fp, title, self:bookProps())
        logger.info("YWBF: book noted, title =", tostring(title))
    end
end

function YuanWangBookFriend:selectionOf(highlight)
    local sel = ""
    if highlight and highlight.selected_text and highlight.selected_text.text then
        sel = highlight.selected_text.text
    end
    return sel
end

--[[--
读当前阅读进度（防剧透 F4.2 的输入）。
EPUB 走 xpointer/crengine 页码，PDF 走 ui.paging.current_page；
任何一步失败都退化成"进度未知"，只影响防剧透精度，不影响提问。
--]]
function YuanWangBookFriend:progress()
    local prog = Spoiler.readProgress(self.ui, Spoiler.currentConfig())
    if prog.ok then
        logger.info("YWBF: progress =", Spoiler.progressLabel(prog),
            " source=", tostring(prog.source))
    else
        logger.info("YWBF: progress unavailable, spoiler degrades to prompt-only")
    end
    return prog
end

function YuanWangBookFriend:gather(highlight)
    local selected = self:selectionOf(highlight)
    return {
        selected = selected,
        page_text = self:pageText(highlight),
        book_fp = self:bookFingerprint(),
        -- 书名一路传到 askSync，落进历史条目（收藏列表要按它分组）。
        -- 传的是字符串，不是 document 之类的 UI 对象——纯逻辑层不许摸 UI。
        book_title = self:bookTitle(),
        progress = self:progress(),
    }
end

-- ---------- 长按文本菜单（PRD F6.2） ----------

function YuanWangBookFriend:registerHighlightButtons()
    local highlight = self.ui and self.ui.highlight
    if not (highlight and highlight.addToHighlightDialog) then return false end

    highlight:addToHighlightDialog("90_ywbf_explain", function(this)
        return {
            text = _("远望书友-AI解释"),
            show_in_highlight_dialog_func = function()
                return (this.selected_text and this.selected_text.text or "") ~= ""
            end,
            callback = function()
                local g = self:gather(this)
                this:onClose()
                Asker:askAndShow({
                    kind = "explain", title = _("远望书友-AI解释"),
                    selected = g.selected, page_text = g.page_text, book_fp = g.book_fp,
                    progress = g.progress,
                })
            end,
        }
    end)

    highlight:addToHighlightDialog("91_ywbf_summary", function(this)
        return {
            text = _("远望书友-AI摘要"),
            show_in_highlight_dialog_func = function()
                return (this.selected_text and this.selected_text.text or "") ~= ""
            end,
            callback = function()
                local g = self:gather(this)
                this:onClose()
                Asker:askAndShow({
                    kind = "summary", title = _("远望书友-AI摘要"),
                    selected = g.selected, page_text = g.page_text, book_fp = g.book_fp,
                    progress = g.progress,
                })
            end,
        }
    end)

    highlight:addToHighlightDialog("92_ywbf_light", function(this)
        return {
            text = _("远望书友-轻问"),
            show_in_highlight_dialog_func = function()
                return (this.selected_text and this.selected_text.text or "") ~= ""
            end,
            callback = function()
                local g = self:gather(this)
                this:onClose()
                ToastCard:open(self, g)
            end,
        }
    end)

    highlight:addToHighlightDialog("93_ywbf_chat", function(this)
        return {
            text = _("远望书友-深聊"),
            show_in_highlight_dialog_func = function()
                return (this.selected_text and this.selected_text.text or "") ~= ""
            end,
            callback = function()
                local g = self:gather(this)
                this:onClose()
                ChatDialog:open(self, g)
            end,
        }
    end)

    return true
end

function YuanWangBookFriend:onReaderReady()
    -- 文档就绪后再注册长按菜单（部分设备上 init 时 highlight 模块还没建好）
    self:registerHighlightButtons()
    -- 记一次书名：跨书收藏列表靠它显示书名（见 noteCurrentBook 的说明）
    self:noteCurrentBook()
    -- 章索引在这里算一次就缓存住（见 chapterIndex 的说明）
    self:chapterIndex()
end

--[[--
当前页码（PDF / 分页走 ui.paging，EPUB 走 getCurrentPage）。
@return number|nil
--]]
function YuanWangBookFriend:currentPage()
    local doc = self.ui and self.ui.document
    if type(doc) ~= "table" then return nil end
    if type(self.ui.paging) == "table"
        and type(self.ui.paging.current_page) == "number"
        and self.ui.paging.current_page > 0 then
        return self.ui.paging.current_page
    end
    if type(doc.getCurrentPage) == "function" then
        local ok, v = pcall(doc.getCurrentPage, doc)
        if ok and type(v) == "number" and v > 0 then return v end
    end
    return nil
end

--[[--
当前这本书的**章索引**（目录 → 每章的起止锚点与"最后一页"）。

为什么必须缓存：`onPageUpdate` 是个**很热的钩子**（11 个模块在消费它），
而 `Chapter.build` 要遍历整份目录。每翻一页全量算一遍，大部头（哈利波特 254 条
目录）上就是肉眼可见的卡顿。这里按书籍指纹缓存一次，`onPageUpdate` 里
只剩一次 `Chapter.locate`（线性扫一个数组）+ 整数比较。

@return array Chapter.build 的产物；没有目录 / 没开书时是空数组
--]]
function YuanWangBookFriend:chapterIndex()
    local fp = self:bookFingerprint()
    local cache = self._chapter_cache
    if type(cache) == "table" and cache.fp == fp and type(cache.index) == "table" then
        return cache.index
    end

    local toc = currentToc(self.ui)
    local page_count = nil
    local doc = self.ui and self.ui.document
    if type(doc) == "table" and type(doc.getPageCount) == "function" then
        local ok, v = pcall(doc.getPageCount, doc)
        if ok and type(v) == "number" and v > 0 then page_count = v end
    end

    local index = Chapter.build(toc, page_count)
    self._chapter_cache = { fp = fp, index = index }
    -- 换了书（或第一次建索引）就把跃迁追踪器清零：
    -- 留着上一本书的"上一章"会拿它跟新书的第一章比序号
    self._chapter_tracker = Chapter.newTracker()
    logger.info("YWBF: chapter index built, chapters =", #index)
    return index
end

--[[--
翻页钩子（§8 第 2 步验的是"能不能检出"，第 4 步开始真的去做事）。

两条死规矩，都是踩过的：
  · 插件是 WidgetContainer 的子节点，事件靠 `propagateEvent` 逐个子模块冒泡，
    **遇到第一个返回 true 的就停**，而插件是最后注册的。
  · **绝不能 `return true`**：那会把事件吞掉，可能影响阅读器自己的翻页
    （main.lua 顶上那段注释里记着这条的出处）。这个 handler 什么都不返回，
    且内部所有取数都过 pcall —— 它崩了不能连累阅读器。

"翻到新章第一页"就是 `Chapter.update` 返回非 nil 的那一刻：
它返回的是**刚读完的那一章**，三条例外（跳章 / 倒翻 / 一步跨多章）都返回 nil。
--]]
function YuanWangBookFriend:onPageUpdate(pageno)
    local index = self._chapter_cache and self._chapter_cache.index
    if type(index) ~= "table" or #index == 0 then return end

    local page = tonumber(pageno)
    if page == nil then page = self:currentPage() end
    if page == nil then return end

    local entry = Chapter.locate(index, page)
    if type(self._chapter_tracker) ~= "table" then
        self._chapter_tracker = Chapter.newTracker()
    end
    local finished = Chapter.update(self._chapter_tracker, entry)
    logger.info("YWBF: onPageUpdate page=", tostring(page),
        " now=", tostring(entry and entry.key or "-"),
        " finished=", tostring(finished and finished.key or "-"))
    if not finished then return end

    -- 到这里才做第 4 步的事；出错只记日志，绝不把异常抛回给阅读器的翻页
    local ok, err = pcall(self.onChapterFinished, self, finished)
    if not ok then
        logger.warn("YWBF: onChapterFinished failed: ", tostring(err))
    end
end

--[==[
刚读完一章：要不要弹一句「让小望总结这一章？」（§8 第 4 步）。

三道闸，按顺序，任一不满足就安静走开（**不弹任何东西**）：
  1. 开关必须开（`chapter_summary_prompt == "ask_each_chapter"`）——默认关，
     这条是"系统主动发起、每章都真花钱"的性质决定的；
  2. 频次（同一章一天一次 + 一天最多 N 次），见 `Chapter.canAuto`；
  3. 这一章真的有正文（分隔性条目过滤，探针实测 6–27 字节那批）。

`flush_events_on_show = true` 不是可选项：翻页那一下的点击/滑动事件还在队列里，
框刚弹出来就会被它自己 dismiss 掉 —— 表现成"闪一下就没了"。
--]==]
function YuanWangBookFriend:onChapterFinished(entry)
    local mode = Config:get("chapter_summary_prompt")
    if mode ~= "ask_each_chapter" then return false end
    if type(entry) ~= "table" or type(entry.key) ~= "string" then return false end

    --[[--
    分隔性条目（卷名 / 书目 / 空页）先过滤掉，再谈频次。

    顺序是**故意**把贵的一步（取正文）放在频次判定之前：
    反过来的话，"这一章没有可总结的正文"会先占掉一条当日配额，
    一本回目极多的书里那几个空条目就把一天的额度吃掉了。
    取正文只在**跨章那一下**发生（不是每页），探针实测 1–70 ms，付得起。
    --]]
    local doc = self.ui and self.ui.document
    if type(doc) == "table" then
        local ok_t, txt = pcall(Chapter.textOf, doc, entry)
        if not ok_t or not Chapter.hasContent(txt) then
            logger.info("YWBF: chapter summary auto skipped, reason=no_content")
            return false
        end
    end

    local max_per_day = Config:get("chapter_summary_max_per_day")
    if type(max_per_day) ~= "number" then max_per_day = 3 end

    local path = Chapter.freqPath()
    local freq = Chapter.loadFreq(path)
    local allowed, reason = Chapter.canAuto(freq, entry.key, nil, max_per_day)
    if not allowed then
        logger.info("YWBF: chapter summary auto skipped, reason=", tostring(reason))
        return false
    end

    -- 先记后弹：用户无论选哪个，这一章今天都不该再问第二次
    -- （选"不用了"还要再弹 = 骚扰，那正是要治的东西）
    local marked = Chapter.markAuto(freq, entry.key, nil)
    if marked then Chapter.saveFreq(path, freq) end

    local label = Chapter.label(entry)
    local box = ConfirmBox:new{
        text = T(_("刚读完 %1。要不要让小望总结这一章？"), label),
        -- 翻页那一下的事件还在队列里，不冲掉的话框刚出来就被自己 dismiss 了
        flush_events_on_show = true,
        ok_text = _("总结这一章"),
        cancel_text = _("不用了"),
        ok_callback = function()
            self:summarizeChapterEntry(entry)
        end,
    }
    UIManager:show(box)
    logger.info("YWBF: chapter summary auto asked, chapter=", tostring(entry.key))
    return true
end

function YuanWangBookFriend:onPosUpdate(pos)
    logger.info("YWBF: probe onPosUpdate, pos =", tostring(pos),
        "ts =", tostring(os.time()))
end

--[[--
手动入口「总结本章」（望仔拍板第 3 项：开关关掉的用户也能用）。

**第 5 项（中途不总结）在这里落地**：没读到本章最后一页就只给一句
「读完这一章再让我总结」，不发请求。这不是偷懒——它是防剧透里唯一
不依赖模型自觉的那道闸：正文的取法保证未读文本物理上进不来 payload。

@return bool 是否真的发了请求
--]]
function YuanWangBookFriend:summarizeCurrentChapter()
    if not self:hasOpenBook() then
        UIManager:show(InfoMessage:new{ text = _("当前没有打开的书。") })
        return false
    end

    local index = self:chapterIndex()
    if #index == 0 then
        UIManager:show(InfoMessage:new{
            text = _("这本书没有目录，分不出章节，总结不了某一章。"),
        })
        return false
    end

    local page = self:currentPage()
    local entry = page and Chapter.locate(index, page) or nil
    if not entry then
        UIManager:show(InfoMessage:new{ text = _("定位不到当前所在的章节。") })
        return false
    end

    if not Chapter.isReadThrough(entry, page) then
        UIManager:show(InfoMessage:new{ text = _("读完这一章再让我总结") })
        return false
    end

    return self:summarizeChapterEntry(entry)
end

--[[--
对**指定的一章**发总结请求（手动入口与自动弹窗共用这一份）。

两条路必须共用：手动那条多了"整章读完"的判定（望仔拍板第 5 项），
自动那条天生满足（跨章跃迁 == 上一章读完了）。写两份的话，
"手动要判读完、自动不判"这种偏差迟早会被改出来。

@param entry table Chapter.build 出来的某一章
@return bool 是否真的发了请求
--]]
--[==[
手动入口「总结本章」的**在途锁**（G-1）。

为什么要锁：连点 5 次「总结本章」= 5 份整章正文同时驻留 + **5 次真 API 调用**。
前半是 OOM 的形状（设备 MemTotal 只有 490 MB），后半是真金白银。两条都得堵。

自动弹窗那一路**不需要**这把锁：`markAuto` 是先记后弹，第二个事件（EndOfBook
与 PageUpdate 的双触发）到达时 `canAuto` 已经是 false 了 —— §6.1 第 5 项那条
风险因此降级为观感问题，不用在这里补。

TTL 不是多余：异步那条路如果半路抛异常，`on_done` 不会被调到，锁就永久留在
那儿了 —— 用户会永远点不动。给它一个有效期，超时当作没锁过。
--]==]
local CHAPTER_INFLIGHT_TTL = 300   -- 秒；正常一次总结 1–3 分钟，5 分钟足够宽

function YuanWangBookFriend:chapterSummaryInflight(key)
    if type(self._chapter_inflight) ~= "table" then return false end
    if type(key) ~= "string" or key == "" then return false end
    local at = self._chapter_inflight[key]
    if type(at) ~= "number" then return false end
    if type(os.time) == "function" and (os.time() - at) > CHAPTER_INFLIGHT_TTL then
        self._chapter_inflight[key] = nil   -- 过期当作没锁过
        return false
    end
    return true
end

function YuanWangBookFriend:summarizeChapterEntry(entry)
    if type(entry) ~= "table" then return false end
    if not self:hasOpenBook() then
        UIManager:show(InfoMessage:new{ text = _("当前没有打开的书。") })
        return false
    end

    -- 同一章同一时刻只允许一个在途：期间再点直接挡回去（不排队、不并发）
    local ckey = type(entry.key) == "string" and entry.key or nil
    if self:chapterSummaryInflight(ckey) then
        UIManager:show(InfoMessage:new{ text = _("正在总结这一章，请稍候。") })
        logger.info("YWBF: chapter summary skipped, already inflight, chapter=",
            tostring(ckey))
        return false
    end
    if ckey then
        self._chapter_inflight = type(self._chapter_inflight) == "table"
            and self._chapter_inflight or {}
        self._chapter_inflight[ckey] = (type(os.time) == "function") and os.time() or 0
    end

    local doc = self.ui.document
    local text = Chapter.textOf(doc, entry)
    if not Chapter.hasContent(text) then
        -- 分隔性条目（卷名 / 书目 / 空页）会走到这里：探针实测 6–27 字节那批
        UIManager:show(InfoMessage:new{ text = _("这一章没有可总结的正文。") })
        return false
    end

    -- 超长章：硬截 + 明说（望仔拍板第 4 项）
    local max_chars = Config:get("chapter_summary_max_chars")
    if type(max_chars) ~= "number" or max_chars <= 0 then max_chars = 12000 end
    local used = text
    local note = nil
    if Util.utf8len(text) > max_chars then
        used = Context.truncate(text, max_chars)
        note = T(_("本章过长，只总结了前 %1 字"), tostring(Util.utf8len(used)))
    end

    local title = (entry.title ~= "") and entry.title or Chapter.label(entry)
    Asker:summarizeChapterAsync(self, {
        book_fp = self:bookFingerprint(),
        -- 缓存键必须带章标识，否则每章撞成同一个键（见 asker.lua 里的注释）
        chapter_key = entry.key,
        chapter_label = Chapter.label(entry),
        chapter_text = used,
        progress = self:progress(),
        note = note,
        title = T(_("本章总结：%1"), title),
        -- 结束（成功或失败都算）时解锁：见 chapterSummaryInflight 的注释
        on_done = function()
            if type(self._chapter_inflight) == "table" and ckey then
                self._chapter_inflight[ckey] = nil
            end
        end,
    })
    logger.info("YWBF: chapter summary requested, chapter=", tostring(entry.key))
    return true
end

function YuanWangBookFriend:onDispatcherRegisterActions()
    Dispatcher:registerAction("ywbf_global_assistant", {
        category = "none",
        event = "YWBFOpenAssistant",
        title = _("远望书友：呼出 AI 助手"),
        general = true,
    })
end

function YuanWangBookFriend:addToMainMenu(menu_items)
    -- sorting_hint 用 "tools"：与觅阅·微信读书、Simple UI 同级，导航层级最浅
    -- （"more_tools" 会被收进更深的分组里，不要用）
    menu_items.yuanwang_book_friend = {
        text = _("远望书友"),
        sorting_hint = "tools",
        sub_item_table = SettingsUI:buildMenu(self),
    }
end

-- 全局 AI 助手入口（PRD F1.3）
function YuanWangBookFriend:onYWBFOpenAssistant()
    local g = self:gather(nil)
    ChatDialog:open(self, g)
end

-- 供设置页展示当前识别到的进度（防剧透是否在生效，一眼可见）
function YuanWangBookFriend:currentProgress()
    return self:progress()
end

--[[--
供设置菜单展示轻问的异步回复。

原来的实现只读 `self.last_reply`（纯内存字段），于是"关掉书再进来就是空的"——
而真实的问答一直躺在 data/history/<fp>.json 里，只是没接过来。
现在内存里没有时回退去历史里读当前书最后一条回答：关书、重启都能看到，
这才是用户以为自己在用的功能。

跨书读不到（当前书本来就没有历史）时才维持原来的空提示。
--]]
function YuanWangBookFriend:showLastReply()
    local reply = self.last_reply
    if reply and not Util.isEmpty(reply.content) then
        local ref = (reply.book_fp and reply.index)
            and { book_fp = reply.book_fp, index = reply.index } or nil
        --[[--
        尾传 reply.selection：内存里那条回复自带当初选中的原文，显示在问答上方。
        尾再传 surface：决定这张卡片挂不挂「收藏」。
        `reply.surface or reply.kind` 的回退是给**老记录**留的（那时还没有 surface 字段），
        与今天的行为一致：kind=light/chat 能收藏，explain/summary 不能。
        --]]
        Asker:showResult(reply.title or _("轻问回复"), reply.content, nil, reply.question, ref,
            reply.selection, reply.surface or reply.kind)
        return
    end

    local idx, row = Store:lastAssistant(self:bookFingerprint())
    if not row or Util.isEmpty(row.content) then
        UIManager:show(InfoMessage:new{ text = _("还没有异步回复。用「轻问」提交问题后会在这里看到结果。") })
        return
    end
    local note = _("（来自历史记录）")
    -- 从历史回退读出来的这条同样带 selection；尾参不改变既有调用点的行为。
    -- surface 同上一处：新记录读 surface，老记录回退到 kind。
    Asker:showResult(row.kind == "light" and _("轻问回复") or _("远望书友"),
        row.content, note, Store:questionFor(row.book_fp, idx),
        { book_fp = row.book_fp, index = idx }, row.selection, row.surface or row.kind)
end

-- 供其它模块（后续 UI）复用的简短入口
function YuanWangBookFriend:testConnection(callback)
    Queue:submit({
        name = "test_connection",
        fn = function()
            return DeepSeek:chat({
                { role = "system", content = "你是阅读助手，回答务必简短。" },
                { role = "user",   content = "用一句话说明《红楼梦》的作者是谁。" },
            }, { max_tokens = 128, temperature = 0.3 })
        end,
        on_done = function(result)
            if callback then callback(true, result) end
        end,
        on_error = function(err)
            if callback then callback(false, err) end
        end,
    })
    Queue:process()
end

return YuanWangBookFriend
