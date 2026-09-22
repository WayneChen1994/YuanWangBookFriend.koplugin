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
    --[[--
    章末总结：输出要"详细、全面、多角度"，5 个小标题铺下来 2500 token 根本不够
    （真机第 8 轮望仔：总结被截断、提示"结尾可能不完整"）。

    `deepseek-chat` 的 max_tokens 上限是 8192，取 **4000**：够铺开 5 个角度，
    离硬上限还留一倍余量，不至于一次把额度烧穿。

    ⚠️ 光改这个数对**老用户不生效**（`load()` 只在键不存在时才用 DEFAULTS 补），
    望仔机器上的 settings.json 里躺着的就是 2500。真正的生效靠
    `MAX_TOKENS_CHAPTER_SUMMARY_MIN` 那道钳 + 回写，见 `Config:load()`。
    --]]
    max_tokens_chapter_summary = 4000,
    api_key_enc = nil,                -- 加密后的 API Key（密文，永不明文落盘）

    -- 上下文与请求
    context_chars = 800,              -- 选中位置前后各取多少字符
    request_timeout = 60,
    max_retries = 2,

    -- 缓存
    cache_enabled = true,
    --[[--
    缓存上限 4 MB（原来是 50 MB = 设备内存的 10.2%）。

    降它的理由不是"现在会炸"——按 3 次/天 × 约 7.5 KB 算，填满要两千多天；
    而是两件事今天就不对：① 这个值完全不可见，没有任何日志在报；
    ② `Cache:save()` 每次写入都 `json.encode` **整个索引**，最坏那一次分配
    是"整个上限"那么大的字符串，50 MB 上限 = 一次 50 MB 字符串分配
    （再加 encode 过程中的中间量）。KPW4 MemTotal 只有 490 MB。

    代价要说清楚：老缓存会被更早淘汰，下次重发请求多花 token，**无数据丢失**。
    --]]
    cache_max_bytes = 4 * 1024 * 1024,

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

    --[[--
    章末总结：读完一章后要不要**主动**问一句"要不要总结本章"。
      "off"              —— 不问（默认）
      "ask_each_chapter" —— 翻到新章第一页时问一次

    默认关的理由：「轻问」这类入口是用户自己点了才花钱，而章末提示是
    **系统主动发起**，每章都真花钱。性质不同，默认必须是"绝不悄悄花钱"那一侧。
    开关关掉的用户照样能用主菜单里常驻的「总结本章」。
    --]]
    chapter_summary_prompt = "off",

    --[[--
    自动弹窗**一天最多弹几次**（0 或负 = 不限次）。

    为什么要有这条：一本回目极多的书（探针实测哈利波特 254 条目录）一晚上翻十几章，
    每章都问一次就是骚扰——用户会被烦到把整个开关关掉，那这一期就白做了。
    同一章一天只弹一次是另一条闸，写在 `Chapter.canAuto` 里（倒着翻回去再翻过来
    是最常见的动作，不记"这一章弹没弹过"就会反复弹同一章）。
    --]]
    chapter_summary_max_per_day = 3,

    -- 超长章的硬截上限（字）。超过就只总结前 N 字，并在结果卡片上明说。
    -- 上限做成配置项：一本回目特别长的书（章回小说、合集）用户自己能放宽。
    chapter_summary_max_chars = 12000,

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
    -- load() 里钳过的项必须回写，否则文件里始终躺着那个旧值（真机上就是
    -- 52428800），下次有人去读会被误导成"上限还是 50 MB"。
    if self._clamped_on_load then
        -- 先备份再写：`save()` 是非原子写，而这个文件里含 api_key_enc。
        -- 详见 Config:backupSettings 那段。
        self:backupSettings()
        self:save()
    end
    return self
end

--[==[
**旧配置不会自动跟着默认值走** —— 这是改 2 差一点白做的那个坑，单独写清楚。

`load()` 只在 `loaded[k] == nil` 时才用 `DEFAULTS` 补。也就是说：
**只要 settings.json 里已经有了这个键，改 `DEFAULTS` 对老用户完全不生效。**

真机实测（`data/settings.json`，2026-09-22 只读读取）：
    "cache_max_bytes":52428800
那是 `cache_max_bytes` 还是 50 MB 那版写进去的。我们把 `DEFAULTS` 降到
4 MB 之后，望仔那台机器读到的**仍然是 50 MB** —— 界面上、日志里都看不出来，
只有去读那个文件才发现。等于改 2 在他那儿没做。

所以凡"有上界的数值项"都要在这里**钳一次**（不是只做一次性迁移）：
一次性迁移只能救今天这一个值，以后再写进一个离谱的值它又会放过。
钳完还要**回写文件**，否则每次启动都重算一遍、文件里始终躺着那个旧值，
下次再有人去读会被误导。
--]==]
-- 缓存上限的硬天花板。`cache_max_bytes` 在 UI 里没有入口（只有 DEFAULTS 和测试
-- 会写它），所以钳成常量是安全的；将来若开放给用户调，这里要跟着改。
Config.CACHE_MAX_BYTES_CEILING = 4 * 1024 * 1024

--[==[
章末总结输出预算的**下限 4000 / 上限 8192**。

下限为什么必须钳：望仔那台的 settings.json 里存着 2500（老默认值写进去的），
而这个键在设置界面里**没有入口**（只有 DEFAULTS 和测试会写），所以不存在
"用户特意调低"这种情况 —— 抬上去是安全的，不抬就等于这次改动在他那儿没做。

上限 8192 是 `deepseek-chat` 的 max_tokens 硬顶，钳在它是防止哪天写进去一个
离谱的值（超出硬顶会被 API 直接拒，整条链路白跑）。

将来若把这个值开放给用户调，下限那道钳要跟着撤 —— 否则会跟用户对着干。
--]==]
Config.MAX_TOKENS_CHAPTER_SUMMARY_MIN = 4000
Config.MAX_TOKENS_CHAPTER_SUMMARY_MAX = 8192

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

    -- 钳制（见上面的整段说明）：文件里那个 50 MB 不会被 DEFAULTS 覆盖，
    -- 只能在这儿拦。返回 true 表示"改了东西，需要回写"。
    local clamped = false
    local cmb = loaded.cache_max_bytes
    if type(cmb) ~= "number" or cmb < 0 then
        -- 不是数字 / 是负数：直接回默认值
        loaded.cache_max_bytes = self.DEFAULTS.cache_max_bytes
        clamped = true
    elseif cmb > Config.CACHE_MAX_BYTES_CEILING then
        -- 超过天花板：压到天花板（不是压回默认值 —— 天花板才是那条硬线）
        loaded.cache_max_bytes = Config.CACHE_MAX_BYTES_CEILING
        clamped = true
    end

    --[[--
    章末总结的输出预算：老文件里那个 2500 必须被**抬**到 4000。

    与上面那条同因：`load()` 只在键不存在时才用 DEFAULTS 补，所以改 DEFAULTS
    对已经存过值的机器一点用都没有。真机实测望仔那台就是 2500。
    --]]
    local mtcs = loaded.max_tokens_chapter_summary
    if type(mtcs) ~= "number" or mtcs < 1 then
        -- 不是数字 / 非正数：回默认值
        loaded.max_tokens_chapter_summary = self.DEFAULTS.max_tokens_chapter_summary
        clamped = true
    elseif mtcs < Config.MAX_TOKENS_CHAPTER_SUMMARY_MIN then
        -- 老默认值 2500：抬到下限
        loaded.max_tokens_chapter_summary = Config.MAX_TOKENS_CHAPTER_SUMMARY_MIN
        clamped = true
    elseif mtcs > Config.MAX_TOKENS_CHAPTER_SUMMARY_MAX then
        -- 超过 API 硬顶：压回硬顶
        loaded.max_tokens_chapter_summary = Config.MAX_TOKENS_CHAPTER_SUMMARY_MAX
        clamped = true
    end
    self._clamped_on_load = clamped
    return loaded
end

--[==[
把 `settings.json` 复制一份（`<原路径>.bak`）再让自动改写落盘。

为什么非备份不可：`save()` 是**非原子写** —— `io.open(path, "w")` 先把文件截成
0 字节再写，中间掉电/进程被杀就剩一个空文件，而这个文件里含 `api_key_enc`。
真机上那意味着用户要重新填一遍 API Key。

只备在"我们主动发起的自动回写"这条路上（init 里钳完那一次）：用户自己改设置
走 `Config:set`，那本来就是用户发起的写；而且 `addUsage` 每问一次都会落盘，
那条路备下去没完没了。
--]==]
function Config:backupSettings()
    local src = self.paths.settings
    if not src then return false end
    local content = read_file(src)
    if not content or #content == 0 then return false end
    return write_file(src .. ".bak", content)
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
