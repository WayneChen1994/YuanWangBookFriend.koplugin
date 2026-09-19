--[[--
QA 边界探针（只读，不改业务逻辑）：把余额查询与 fillLine 的极端输入过一遍，
看每种情况是「可读错误 / 合理降级 / 崩溃」。

在设备上执行：
  cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
     ./luajit /mnt/us/ywbf_dev/qa_boundary_check.lua > /mnt/us/ywbf_dev/boundary.log 2>&1
--]]

local PLUGIN_DIR = "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin"

package.path = "./?.lua;common/?.lua;frontend/?.lua;" .. PLUGIN_DIR .. "/?.lua;" .. package.path
package.cpath = "./?.so;common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

local Util = require("ywbf/util")
local Config = require("ywbf/config")
local Crypto = require("ywbf/crypto")
local HttpClient = require("ywbf/httpclient")
local DeepSeek = require("ywbf/deepseek")

local TEST_DIR = "/mnt/us/ywbf_dev/testdata"
Config:init(TEST_DIR)
Crypto:init()

-- UI 层能不能在无头环境里加载（不能就跳过展示层检查，并明确记一笔）
local SettingsUI = nil
local ui_ok, ui_mod = pcall(require, "ui/settings")
if ui_ok then SettingsUI = ui_mod end
print("ui/settings 可加载:", tostring(ui_ok), ui_ok and "" or tostring(ui_mod))

---- ---------- 1. 余额接口：各种畸形/边界响应 ----------
print("")
print("========== 1. DeepSeek:balance() 边界响应 ==========")

local https_mod = require("ssl.https")
local ltn12 = require("ltn12")
local real_request = https_mod.request
local captured = nil
local function stub(body, code)
    https_mod.request = function(p)
        captured = p
        if p.sink and body then
            ltn12.pump.all(ltn12.source.string(body), p.sink)
        end
        return 1, code or 200, {}, "HTTP/1.1 " .. tostring(code or 200) .. " X"
    end
end

Config:set("api_key_enc", Crypto:encrypt("sk-qa-boundary-key"))

local function show(name, body, code)
    stub(body, code)
    local ok, res, err = pcall(DeepSeek.balance, DeepSeek)
    print(string.format("[%s]", name))
    print(string.format("  pcall_ok=%s  返回表=%s  err=%s",
        tostring(ok), tostring(type(res) == "table"), tostring(err)))
    if ok and type(res) == "table" then
        print(string.format("  is_available=%s  balances=%s",
            tostring(res.is_available), tostring(res.balances and #res.balances)))
        for i, b in ipairs(res.balances or {}) do
            print(string.format("   #%d currency=%s total=%s(type=%s) granted=%s topped=%s",
                i, tostring(b.currency), tostring(b.total_balance), type(b.total_balance),
                tostring(b.granted_balance), tostring(b.topped_up_balance)))
        end
    end
    if SettingsUI then
        local dok, txt = pcall(SettingsUI.formatBalance, SettingsUI, res)
        print(string.format("  formatBalance ok=%s", tostring(dok)))
        if dok and type(txt) == "string" then
            print("  display: " .. txt:gsub("\n", " | "))
        end
    end
end

show("A 可用但余额列表为空", '{"is_available":false,"balance_infos":[]}', 200)
show("B balance_infos 字段缺失", '{"is_available":true}', 200)
show("C total_balance 是数字（非字符串）",
    '{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":19.73,"granted_balance":0,"topped_up_balance":19.73}]}', 200)
show("D HTML 错误页（200）", "<html><head><title>502 Bad Gateway</title></head><body><center><h1>502</h1></center></body></html>", 200)
show("E 401 未授权", '{"error":{"message":"Invalid API key"}}', 401)
show("F 空响应体（200）", "", 200)
show("G JSON 被截断", '{"is_available":true,"balance_infos":[', 200)
show("H balance_infos 里混着非对象条目",
    '{"is_available":true,"balance_infos":["junk",null,{"currency":"USD","total_balance":"1.00","granted_balance":"0.00","topped_up_balance":"1.00"}]}', 200)
show("I 响应体是 JSON 数组", '[1,2,3]', 200)
show("J 响应体是 null", 'null', 200)
show("K 200 但字段全是 null", '{"is_available":true,"balance_infos":[{"currency":null,"total_balance":null}]}', 200)
show("L 402 余额不足", '{"error":{"message":"Insufficient balance"}}', 402)
show("M 500 纯文本", 'Internal Server Error', 500)

---- ---------- 2. 请求形态：确认没把书籍内容带出去 ----------
print("")
print("========== 2. 请求形态 / 出站内容检查 ==========")
stub('{"is_available":true,"balance_infos":[]}', 200)

-- 把 HttpClient.post 换成计数器：余额查询绝对不该走 POST（那是携带内容的那条路）
local real_post = HttpClient.post
local post_called = 0
HttpClient.post = function(...)
    post_called = post_called + 1
    return real_post(...)
end

local bal = DeepSeek:balance()
HttpClient.post = real_post

print("余额查询期间 HttpClient.post 被调用次数:", post_called, "(应为 0)")
if captured then
    print("captured.method =", tostring(captured.method))
    print("captured.url    =", tostring(captured.url))
    print("captured.source =", tostring(captured.source), "(应为 nil)")
    print("captured.protocol =", tostring(captured.protocol))
    print("headers:")
    if type(captured.headers) == "table" then
        local keys = {}
        for k in pairs(captured.headers) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local v = captured.headers[k]
            local shown = (k == "Authorization") and ("Bearer " .. string.rep("*", 8)) or tostring(v)
            print(string.format("   %s = %s", k, shown))
        end
        print("   是否含 Content-Length/Content-Type(请求体标志):",
            tostring(captured.headers["Content-Length"] ~= nil or captured.headers["Content-Type"] ~= nil))
    end
    -- 把所有字符串化的请求信息拼起来找"书籍内容"痕迹
    local dump = tostring(captured.url)
    if type(captured.headers) == "table" then
        for k, v in pairs(captured.headers) do dump = dump .. "|" .. tostring(k) .. "=" .. tostring(v) end
    end
    local marks = { "messages", "content", "selected", "page_text", "book_fp", "model" }
    for _, m in ipairs(marks) do
        print(string.format("   请求里出现字段 %-10s : %s", m, tostring(dump:find(m, 1, true) ~= nil)))
    end
end

-- 白名单：GET 对非白名单域名的行为
local gb, gc, gs, ge = HttpClient.get("https://evil.example.com/balance", {}, 5)
print("越界域名 GET: body=", tostring(gb), " code=", tostring(gc), " err=", tostring(ge))
local g2b, g2c, g2s, g2e = HttpClient.get("http://api.deepseek.com/user/balance", {}, 5)  -- http（非 https）
print("http 明文协议 GET: body=", tostring(g2b), " code=", tostring(g2c), " err=", tostring(g2e))
local g3b, g3c, g3s, g3e = HttpClient.get("https://api.deepseek.com.evil.com/balance", {}, 5)
print("后缀混淆域名 GET: body=", tostring(g3b), " err=", tostring(g3e))
https_mod.request = real_request

---- ---------- 3. Util.fillLine 极端参数 ----------
print("")
print("========== 3. Util.fillLine 极端参数 ==========")
local function fl(name, usable, unit, char, measure)
    local ok, out = pcall(Util.fillLine, usable, unit, char, measure)
    print(string.format("[%s] ok=%s out=%s", name, tostring(ok),
        ok and string.format("len_bytes=%d utf8len=%d", #out, Util.utf8len(out)) or tostring(out)))
end

fl("unit 比 usable 大（n 先算成 0）", 10, 20, "—")
fl("usable 极小（1px / 0.5px）", 1, 0.5, "-")
fl("usable 与 unit 相等", 20, 20, "-")
fl("char 是多字节中文", 100, 10, "界")
fl("char 默认（nil）", 100, 10, nil)
fl("usable 极大（触发 500 上限）", 100000, 20, "-")
fl("usable 为负", -100, 20, "-")
fl("usable 是字符串", "1000", 20, "-")
fl("usable 是 bool", true, 20, "-")
fl("measure 抛异常", 100, 10, "-", function(s) error("测量炸了") end)
fl("measure 返回 nil", 100, 10, "-", function(s) return nil end)
fl("measure 返回字符串", 100, 10, "-", function(s) return "宽" end)
fl("measure 一直报超宽（退到底）", 100, 10, "-", function(s) return 1e9 end)
fl("measure 返回 0", 100, 10, "-", function(s) return 0 end)
fl("measure 返回负数", 100, 10, "-", function(s) return -5 end)

-- measure 递减上限：退 10 次后即使仍超宽也停
local steps = 0
local out = Util.fillLine(100, 10, "-", function(s)
    steps = steps + 1
    return 1e9
end)
print("measure 永不满足时: 调用次数=", steps, " 结果字符数=", Util.utf8len(out), "(上限 10 次)")

---- ---------- 4. buildSeparator 在真机/无头环境的实际取值 ----------
print("")
print("========== 4. buildSeparator 环境检查 ==========")
local ok_dev, Device = pcall(require, "device")
if ok_dev and Device and Device.screen and Device.screen.getWidth then
    print("Device.screen 可用, 宽=", Device.screen:getWidth())
else
    print("Device.screen 不可用（无头 luajit）：此时 buildSeparator 走 SEP_FALLBACK(24)")
end

print("")
print("QA_BOUNDARY DONE")
