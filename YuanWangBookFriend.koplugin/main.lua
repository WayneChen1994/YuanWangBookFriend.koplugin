--[[--
远望书友 YuanWangBookFriend.koplugin
KOReader AI 辅助阅读插件

@module koplugin.YuanWangBookFriend
--]]--

-- 关键：插件加载期间 PluginLoader 会把插件根目录注入 package.path，
-- 因此所有 require 必须在文件顶部完成（运行时再 require 子模块会找不到路径）。
local Config = require("ywbf/config")
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
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

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
        Store:noteBook(fp, title)
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
        Asker:showResult(reply.title or _("轻问回复"), reply.content, nil, reply.question, ref)
        return
    end

    local idx, row = Store:lastAssistant(self:bookFingerprint())
    if not row or Util.isEmpty(row.content) then
        UIManager:show(InfoMessage:new{ text = _("还没有异步回复。用「轻问」提交问题后会在这里看到结果。") })
        return
    end
    local note = _("（来自历史记录）")
    Asker:showResult(row.kind == "light" and _("轻问回复") or _("远望书友"),
        row.content, note, Store:questionFor(row.book_fp, idx),
        { book_fp = row.book_fp, index = idx })
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
