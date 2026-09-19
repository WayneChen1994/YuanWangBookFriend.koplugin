-- QA 小工具：把持久化的 cache_enabled 设成指定值，用来验证"上一轮残留配置"会不会污染下一轮。
--
-- 用法：
--   YWBF_TEST_DIR=<目录> ./luajit qa_setcache.lua false|true [<目录>]
--
-- 目录为什么不能再写死：最初这脚本把目录硬编码成 /mnt/us/ywbf_dev/testdata，
-- 工程师拿它去投毒 trunc_data 时，毒其实下在 testdata 上，第一次对照实验因此**全绿**，
-- 差点得出"钉基线没用"的反向结论（他查到第二遍才发现投错了目录）。
-- 写死目录的风险在于：你以为在给 A 目录投毒、实际毒在 B 目录，于是"没污染"是个假结论。
-- 所以目录优先取环境变量、其次取第二个参数，都不给才回落到默认目录。
package.path = "/mnt/us/koreader/plugins/YuanWangBookFriend.koplugin/?.lua;common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;/mnt/us/koreader/common/?.so;" .. package.cpath
pcall(require, "ffi/loadlib")

local Config = require("ywbf/config")

local dir = os.getenv("YWBF_TEST_DIR") or (arg and arg[2]) or "/mnt/us/ywbf_dev/testdata"
Config:init(dir)
local v = arg and arg[1] or "true"
Config:set("cache_enabled", v == "true")
print("dir =", dir)
print("cache_enabled now =", tostring(Config:get("cache_enabled")))
