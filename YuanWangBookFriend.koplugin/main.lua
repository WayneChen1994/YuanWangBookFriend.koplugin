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

-- 供设置菜单展示轻问的异步回复
function YuanWangBookFriend:showLastReply()
    if not self.last_reply or Util.isEmpty(self.last_reply.content) then
        UIManager:show(InfoMessage:new{ text = _("还没有异步回复。用「轻问」提交问题后会在这里看到结果。") })
        return
    end
    Asker:showResult(self.last_reply.title or _("轻问回复"), self.last_reply.content)
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
