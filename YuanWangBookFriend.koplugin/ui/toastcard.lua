--[[--
轻问模式（PRD F1.2）：输入问题 → 立刻返回阅读界面 → 回复异步送达。
完成后只弹一条轻提示（Notification），结果在「远望书友 → 查看最近回复」里看。

墨水屏适配要点：
· description 只放截断后的摘要（原文过长会把输入框挤出屏幕）
· 需要看全文时点「查看选中原文」用 TextViewer 完整展示
--]]

local Asker = require("ui/asker")
local SuggestPicker = require("ui/suggestpicker")
local Util = require("ywbf/util")

local InputDialog = require("ui/widget/inputdialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local ToastCard = {}

-- description 里最多展示多少个字符（超出部分在「查看选中原文」里看）
local PREVIEW_CHARS = 100

--[[--
生成「已选中：…」预览。
必须用 Util.preview：中文 3 字节，string.sub 按字节切会切在汉字中间变乱码。
--]]
local function previewLine(text)
    local txt, total, truncated = Util.preview(text, PREVIEW_CHARS)
    if txt == "" then return nil end
    if truncated then
        return T(_("已选中：%1…（共 %2 字，点「查看选中原文」看完整内容）"), txt, tostring(total))
    end
    return _("已选中：") .. txt
end

--[[--
@param plugin 插件实例
@param opts { selected, page_text, book_fp, progress }
--]]
function ToastCard:open(plugin, opts)
    opts = opts or {}
    local selected = opts.selected or ""
    local selected_clean = Util.sanitizeForDisplay(selected)
    -- 建议问题：本地算，零 API 调用；关掉开关或算不出来时列表为空，入口自动置灰。
    -- page_text / book_fp / progress 是给「让小望来问」那条路准备的：
    -- AI 出题走 Asker:askSync 同一条管道，缺了 progress 防剧透就是空壳。
    local suggest_opts = {
        kind = "light",
        selected = selected_clean,
        context = opts.page_text,
        page_text = opts.page_text,
        book_fp = opts.book_fp,
        progress = opts.progress,
    }
    local suggestions = SuggestPicker:list(suggest_opts)

    -- prefill：从「你可能想问」选回来时带着问题重新打开，而不是直接提交
    local function openDialog(prefill)
        local dialog
        dialog = InputDialog:new{
            title = _("轻问：提交后继续阅读"),
            description = previewLine(selected),
            input = prefill or "",
            input_hint = _("输入你的问题（可留空，默认解释这段）"),
            buttons = {
                {
                    {
                        text = _("取消"),
                        callback = function() UIManager:close(dialog) end,
                    },
                    {
                        text = _("查看选中原文"),
                        enabled = selected ~= "",
                        callback = function()
                            -- TextViewer 叠在输入框之上，关闭后自然回到输入框
                            UIManager:show(TextViewer:new{
                                title = _("选中的原文"),
                                text = selected_clean,
                            })
                        end,
                    },
                },
                {
                    {
                        -- 不挂条数（同 chatdialog：数字会让人以为"只有这几条"）
                        text = _("你可能想问"),
                        enabled = #suggestions > 0,
                        callback = function()
                            -- 必须先关掉输入框再弹选择层：叠在 InputDialog（连同它的
                            -- 虚拟键盘）之上时，弹层点不动也关不掉（真机实测症状）。
                            UIManager:close(dialog)
                            SuggestPicker:show(suggest_opts, function(q)
                                -- 只回填，不直接提交：误触不该变成一次真实请求
                                openDialog(q)
                            end, suggestions, function()
                                -- 返回/点空白：把输入框还给用户
                                openDialog()
                            end)
                        end,
                    },
                },
                {
                    {
                        text = _("提交"),
                        is_enter_default = true,
                        callback = function()
                            local q = dialog:getInputText()
                            UIManager:close(dialog)
                            q = (q or ""):gsub("^%s+", ""):gsub("%s+$", "")
                            Asker:submitAsync(plugin, {
                                kind = (q == "" ) and "explain" or "light",
                                title = _("远望书友-轻问回复"),
                                selected = selected_clean,
                                page_text = opts.page_text,
                                book_fp = opts.book_fp,
                                question = (q == "") and nil or q,
                                -- 防剧透：进度随提交实时读取，管道在 DeepSeek:chat 出口
                                progress = opts.progress,
                            })
                        end,
                    },
                },
            },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    openDialog()
end

return ToastCard
