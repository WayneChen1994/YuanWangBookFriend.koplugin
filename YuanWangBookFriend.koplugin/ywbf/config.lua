--[[--
配置与路径管理。

铁律（PRD §1.3 / §4.4）：所有数据只落在插件目录内，卸载即删目录即净，
绝不写入 KOReader 的 settings 目录或任何插件目录之外的位置。
--]]--

local json = require("json")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")

local Config = {}

--[[--
插件版本。全项目**只有这一处**版本号。

为什么不放 `_meta.lua`、也不在任一 UI 里再写一遍：两份版本号迟早漂移——
菜单显示 0.2、更新检查拿 0.1 去比，用户就会看到"已是最新"却怎么也拿不到新版本。
本项目已经在别处的重复定义上吃过这个亏，这里不再给第二次机会。
形式必须是 `数字.数字.数字`：OTA 那边按数字分段比较，
`"0.10.0"` 与 `"0.9.0"` 用字符串比会得出错误结论。
--]]
Config.VERSION = "0.2.0"

Config.DEFAULTS = {
    -- AI
    model = "deepseek-chat",          -- 常规任务
    deep_model = "deepseek-reasoner", -- 深聊模式可选
    temperature_chat = 0.7,
    temperature_fact = 0.3,           -- 释义/摘要/词条抽取
    max_tokens_explain = 512,
    max_tokens_summary = 1024,
    max_tokens_chat = 2048,
    -- AI 引导式提问：只要 4 条 ≤20 字的问题，300 token 绰绰有余，
    -- 上限压死在这里，防止模板被改长后悄悄变成"一问就烧掉几千 token"
    max_tokens_ideas = 300,
    api_key_enc = nil,                -- 加密后的 API Key（密文，永不明文落盘）

    -- 上下文与请求
    context_chars = 800,              -- 选中位置前后各取多少字符
    request_timeout = 60,
    max_retries = 2,

    -- 缓存
    cache_enabled = true,
    cache_max_bytes = 50 * 1024 * 1024,

    -- AI 回复风格（可选值见 Prompts.STYLES 的 key；非法值在 Prompts 侧回落到默认）
    reply_style = "professional",

    -- 防剧透（默认开启）
    spoiler_guard = true,
    spoiler_granularity = "chapter",  -- chapter | percent | collection
    spoiler_collection = "auto",      -- 本书是合集：auto | on | off

    -- 轻问：回复到达时是否自动弹出结果卡片（默认弹，用户要求「不用去菜单里找」）。
    -- 关掉则退回「只发通知、不打断阅读流」的原始设计。
    light_auto_popup = true,

    -- 「你可能想问」：在提问框里给几条本地生成的建议问题（零 API 调用）。
    -- 默认开启：需要它的人（提不出问题的人）往往不会主动去设置里打开它。
    show_suggestions = true,

    -- 「你可能想问」里的 AI 出题按钮（kind = ideas）。
    -- 默认开启：本地建议是通用的（"这段讲了什么"），AI 才能问出"袭人为什么偏偏
    -- 在这个时点提起宝玉的玉"这种只有读过这段才问得出口的问题。
    -- 但它会真实消耗一次额度，所以：
    --   · 按钮文案必须写「用一次额度」（不能让用户以为是免费的）；
    --   · 结果进缓存，同一段文字再点不重复花钱；
    --   · 不想花这个钱的人在设置里一键关掉，关掉后仍是零开销的本地建议。
    ai_suggestions = true,

    -- 设备适配
    lightweight = "auto",             -- auto | on | off

    -- 用量统计
    usage = { requests = 0, prompt_tokens = 0, completion_tokens = 0 },
}

Config.paths = {}
Config.settings = nil

-- 递归创建目录（lfs.mkdir 不会自动建父目录）
local function mkdirp(path)
    if not path or path == "" then return end
    if ok_lfs then
        local current = ""
        -- 绝对路径从根开始，相对路径逐段拼接
        local prefix = path:sub(1, 1) == "/" and "/" or ""
        for part in path:gmatch("[^/]+") do
            current = (prefix == "/" and (current .. "/" .. part) or
                      (current == "" and part or current .. "/" .. part))
            if current ~= "" and current ~= "." then
                if lfs.attributes(current, "mode") ~= "directory" then
                    pcall(lfs.mkdir, current)
                end
            end
        end
    else
        os.execute(string.format("mkdir -p '%s'", path))
    end
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function write_file(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

Config._read_file = read_file
Config._write_file = write_file

local function absolutize(p)
    if not p or p == "" then return p end
    if p:sub(1, 1) == "/" then return p end
    if ok_lfs then
        local cwd = lfs.currentdir()
        if cwd then return cwd .. "/" .. p end
    end
    return p
end

function Config:init(plugin_path)
    local base = absolutize(plugin_path)
    self.paths.plugin    = base
    self.paths.data      = base .. "/data"
    self.paths.cache     = base .. "/data/cache"
    self.paths.history   = base .. "/data/history"
    self.paths.xray      = base .. "/data/xray"
    self.paths.settings  = base .. "/data/settings.json"
    self.paths.keyfile   = base .. "/data/key.enc"
    self.paths.usagefile = base .. "/data/usage.json"

    mkdirp(self.paths.data)
    mkdirp(self.paths.cache)
    mkdirp(self.paths.history)
    mkdirp(self.paths.xray)

    self.settings = self:load()
    return self
end

function Config:load()
    local loaded = {}
    local raw = self.paths.settings and read_file(self.paths.settings)
    if raw and #raw > 0 then
        local ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == "table" then
            loaded = decoded
        end
    end
    -- 用默认值补齐缺失项（浅合并 + usage 深合并）
    for k, v in pairs(self.DEFAULTS) do
        if loaded[k] == nil then
            if type(v) == "table" then
                local copy = {}
                for kk, vv in pairs(v) do copy[kk] = vv end
                loaded[k] = copy
            else
                loaded[k] = v
            end
        end
    end
    if type(loaded.usage) ~= "table" then loaded.usage = { requests = 0, prompt_tokens = 0, completion_tokens = 0 } end
    for _, k in ipairs({ "requests", "prompt_tokens", "completion_tokens" }) do
        if type(loaded.usage[k]) ~= "number" then loaded.usage[k] = 0 end
    end
    return loaded
end

function Config:save()
    if not self.paths.settings then return false end
    local ok, encoded = pcall(json.encode, self.settings)
    if not ok then return false end
    return write_file(self.paths.settings, encoded)
end

function Config:get(key)
    if self.settings == nil then return nil end
    return self.settings[key]
end

function Config:set(key, value)
    if self.settings == nil then self.settings = self:load() end
    self.settings[key] = value
    return self:save()
end

function Config:reset()
    self.settings = nil
    self.settings = self:load()
    return self:save()
end

function Config:addUsage(prompt_tokens, completion_tokens)
    if self.settings == nil then return end
    local u = self.settings.usage
    u.requests = (u.requests or 0) + 1
    u.prompt_tokens = (u.prompt_tokens or 0) + (prompt_tokens or 0)
    u.completion_tokens = (u.completion_tokens or 0) + (completion_tokens or 0)
    self:save()
end

return Config
