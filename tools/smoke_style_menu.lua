--[[--
AI 回复风格菜单的运行时冒烟测试（不用真机点菜单）。

为什么必须有这个脚本：本项目踩过一次 P0 —— 循环变量 `_` 遮蔽了 gettext 的 `_`，
症状是"点了菜单没反应，而且连报错都没有"。静态检查能抓到写法，但真正证明
"点下去没事"要靠把 menu item 的 text_func / checked_func / callback 真跑一遍。

做法：把 UI 与 DeepSeek 层用桩替掉（package.loaded 预置，require 会直接返回桩），
其余（Config / Prompts / Cache）用真源码，然后：
  1. 遍历 buildMenu 的一级项，逐个调 text_func（会触发所有 _("…") 调用）；
  2. 找出「AI 回复风格」，确认 7 个风格项齐全、key 正确；
  3. 逐个点一遍（调 callback），确认不报错、且 Config 里真的落了值；
  4. 用落下的风格跑 Prompts.build，确认 AI 实际会按这个风格说话；
  5. 把用户的 reply_style 还原成原值。

用法：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     ./luajit /mnt/us/ywbf_dev/smoke_style_menu.lua
--]]

local PLUGIN_DIR = os.getenv("YWBF_PLUGIN_DIR")
    or "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"
local TMP_DIR = os.getenv("YWBF_TMP_DIR") or "/mnt/us/ywbf_dev/smoke_data"

io.stdout:setvbuf("line")

package.path = PLUGIN_DIR .. "/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

-- ---- 桩：只挡住"会弹窗 / 会联网 / 要键盘"的部件 ----
local shown = {}
package.loaded["ui/uimanager"] = {
    -- 注意冒号调用：`UIManager:show(w)` 传进来的第一个参数是 self，
    -- 写成 show = function(w) 会把 UIManager 表自己当成弹窗记下来。
    show = function(self, w) shown[#shown + 1] = w end,
    close = function(self, w) end,
    scheduleIn = function(self, sec, fn) end,
}
-- `InfoMessage:new{...}` 也是冒号调用，第一个参数是 self，第二个才是参数表。
local function fake_widget(self, t) -- luacheck: ignore
    t.show = function() end
    t.close = function() end
    return t
end
package.loaded["ui/widget/infomessage"] = { new = fake_widget }
package.loaded["ui/widget/inputdialog"] = { new = fake_widget }
package.loaded["ui/widget/confirmbox"] = { new = fake_widget }
package.loaded["ywbf/deepseek"] = {
    getApiKey = function() return nil end,
    hasApiKey = function() return false end,
    setApiKey = function() return true end,
    chat = function() return nil, "stub" end,
    balance = function() return nil, "stub" end,
}

local Config = require("ywbf/config")
local Prompts = require("ywbf/prompts")
local SettingsUI = require("ui/settings")

Config:init(TMP_DIR)

local failures = {}
local function fail(m) failures[#failures + 1] = m; print("  FAIL: " .. m) end
local function pass(m) print("  ok: " .. m) end

print("========== 1. buildMenu 一级项：逐个调 text_func ==========")
local plugin_stub = {
    onYWBFOpenAssistant = function() end,
    showLastReply = function() end,
    currentProgress = function() return nil end,
}
local items = SettingsUI:buildMenu(plugin_stub)
print("一级菜单项数 = " .. tostring(#items))
for _i, it in ipairs(items) do
    local label
    if type(it.text_func) == "function" then
        local ok_t, txt = pcall(it.text_func)
        if not ok_t then fail("第 " .. _i .. " 项 text_func 抛错：" .. tostring(txt)) end
        label = txt
    else
        label = it.text
    end
    print(string.format("  [%d] %s%s", _i, tostring(label),
        it.sub_item_table and ("  (子菜单 " .. #it.sub_item_table .. " 项)") or ""))
end
print("")

print("========== 2. 找到「AI 回复风格」子菜单 ==========")
local style_item = nil
for _i, it in ipairs(items) do
    local label = type(it.text_func) == "function" and it.text_func() or it.text
    if type(label) == "string" and label:find("AI 回复风格", 1, true) then
        style_item = it
        break
    end
end
if not style_item then
    fail("一级菜单里没有「AI 回复风格」")
    print("SMOKE FAILED")
    os.exit(1)
end
pass("找到菜单项，当前显示：" .. tostring(style_item.text_func()))
print("help_text：" .. tostring(style_item.help_text))
local subs = style_item.sub_item_table or {}
if #subs ~= #Prompts.STYLES then
    fail(string.format("子项数量 %d 与风格数 %d 不一致", #subs, #Prompts.STYLES))
else
    pass(string.format("子项 %d 个，与 Prompts.STYLES 一致", #subs))
end
print("")

print("========== 3. 逐个点一遍（callback / checked_func / text） ==========")
local original = Config:get("reply_style")
local expected_keys = {}
for _i, s in ipairs(Prompts.STYLES) do expected_keys[_i] = s.key end

for _i, sub in ipairs(subs) do
    local sub_text = type(sub.text_func) == "function" and sub.text_func() or sub.text
    print(string.format("  --- 点击 [%d] %s ---", _i, tostring(sub_text)))

    local ok_c, checked_now = pcall(sub.checked_func)
    if not ok_c then fail("checked_func 抛错：" .. tostring(checked_now)) end

    local ok_cb, cb_err = pcall(sub.callback)
    if not ok_cb then
        fail("callback 抛错（就是那类点了没反应的坑）：" .. tostring(cb_err))
    else
        local got = Config:get("reply_style")
        if got ~= expected_keys[_i] then
            fail(string.format("点了第 %d 项后 reply_style=%s，期望 %s",
                _i, tostring(got), tostring(expected_keys[_i])))
        else
            pass("reply_style 落值 = " .. tostring(got))
        end
        local ok_ch, now_checked = pcall(sub.checked_func)
        if not (ok_ch and now_checked == true) then
            fail("选中后 checked_func 没有变为 true")
        else
            pass("该项显示为已选中")
        end
        -- 弹出来的 InfoMessage 内容要提到角色名和风格
        local msg = shown[#shown]
        if type(msg) ~= "table" or type(msg.text) ~= "string" then
            fail("callback 没有弹出说明文案")
        else
            print("      弹出说明：" .. msg.text:gsub("\n", " / "):sub(1, 120))
            if msg.text:find(Prompts.PERSONA_NAME, 1, true) then
                pass("说明里带角色名 " .. Prompts.PERSONA_NAME)
            else
                fail("说明里没有角色名 " .. Prompts.PERSONA_NAME)
            end
        end
        -- ④ AI 真的会按这个风格说话
        local sys = Prompts.build("chat", {
            question = "这段为什么不直接说破？",
            style = Config:get("reply_style"),
        })[1].content
        local ins = Prompts.styleInstruction(expected_keys[_i])
        if not sys:find(ins, 1, true) then
            fail(expected_keys[_i] .. "：切完风格后 system 里没有对应指令")
        else
            pass("system 已按新风格拼装")
        end
    end
end
print("")

print("========== 4. 非法值不炸：settings.json 被人手改成乱值时 ==========")
Config:set("reply_style", "not_a_style")
do
    local ok_t, txt = pcall(style_item.text_func)
    if ok_t and type(txt) == "string" then
        pass("乱值时菜单显示：" .. txt
            .. "（应回落为 " .. Prompts.styleText(Prompts.STYLE_DEFAULT) .. "）")
    else
        fail("乱值时 text_func 抛错：" .. tostring(txt))
    end
    local sys = Prompts.build("chat", { question = "x", style = Config:get("reply_style") })[1].content
    if sys:find(Prompts.styleInstruction(Prompts.STYLE_DEFAULT), 1, true) then
        pass("乱值时 system 回落到默认风格")
    else
        fail("乱值时 system 没回落")
    end
end
print("")

Config:set("reply_style", original or Prompts.STYLE_DEFAULT)
print("========== 结论 ==========")
if #failures == 0 then
    print("STYLE MENU SMOKE OK（已还原 reply_style = " .. tostring(Config:get("reply_style")) .. "）")
    os.exit(0)
end
print(string.format("STYLE MENU SMOKE FAILED：%d 项", #failures))
for _i, m in ipairs(failures) do print("  - " .. m) end
os.exit(1)
