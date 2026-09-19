# 远望书友（YuanWangBookFriend.koplugin）开发计划

- **版本**：V1.1
- **日期**：2026-09-19
- **依据文档**：`PRD.md`（评审通过版）
- **工作目录**：`D:\MyKoreaderPlugins\YuanWangBookFriend\`
- **测试书籍**：`test_books\`（已从 D:\epub_books 拷贝，原始目录保持只读、不做任何改动）
- **平台策略（V1.1 修订）**：**Kindle 优先，安卓后置**。M1–M5 全部面向越狱 Kindle（KPW4 主测机、KPW6 次测机）；掌阅 neo3ultra 安卓适配在 Kindle 版稳定后单独立项（见 §10 M6）。

---

## 0. 总体策略

先说清楚三件事，免得后面走弯路：

1. **开发机是 Windows，真机是唯一可信测试环境。** KOReader 官方模拟器依赖 Linux 构建链，Windows 上折腾性价比极低。方案：**本机写代码 + 轻量 mock 单元测试（Python 驱动 Lua 逻辑层）+ Kindle 真机验收**。**KPW4 是主开发验证机，已开启 SSH，PC 通过 SSH/SCP 直连部署与调试**（推文件、看日志、执行命令全走网络，不依赖 USB 拷贝，迭代速度不输 adb）；KPW6 做里程碑验收。安卓版（neo3ultra）M1–M5 期间不投入，Kindle 版稳定后再启动（见 §10 M6）。
2. **逻辑与 UI 严格分层。** 所有不依赖 KOReader UI 的逻辑（HTTP、缓存、截断、prompt 组装、队列、存储）写成纯 Lua 模块，可在本机用 Lua 解释器 + mock 直接测；UI 层只做薄封装。这是低性能设备上控制复杂度的关键，也是本机能测 80% 代码的前提。
3. **每个里程碑冻结一次。** 里程碑验收通过才进下一个，不并行摊大饼。KPW4 既是主测机也是性能红线设备，每个里程碑都要在 KPW4 + KPW6 双机过一轮。

### 里程碑与 PRD 对应关系

| 里程碑 | 覆盖 PRD 需求 | 目标 |
|---|---|---|
| M1 骨架 | F8.1/F8.4/F8.5、F7.4、4.4 | 插件能被 KOReader 加载，Key 加密存储，DeepSeek 连通，队列可用 |
| M2 核心问答 | F1.1–F1.4、F2.1–F2.3、F6.2、F7.1、F7.3 | 完整问答体验（深聊/轻问/释义/摘要/缓存/E-ink UI） |
| M3 防剧透 | F4.1–F4.5 | 工程级防剧透全链路，抓包可证 |
| M4 X-Ray | F3.1–F3.4 | 词条生成/卡片/模糊匹配/剧情回顾 |
| M5 增强与发布 | F2.4、F3.5、F5.1、F5.2、F6.1、F7.2 | 图谱、手势、书库分类、KPW4 精简模式打磨，V1.0 候选 |

P2 需求（F3.6 时间线、F5.3 统计报告）不进本计划，V1.1 再说。

---

## 1. 阶段 0：开发环境搭建（0.5 个工作日）

| 任务 ID | 任务 | 产出/验收 |
|---|---|---|
| T0.1 | 克隆 KOReader 源码（仅作 API 参考，不构建）到 `D:\koreader-src`，checkout 2026.07 tag | 本地可查 `frontend/` 下所有公开 API |
| ~~T0.2~~ | ~~安装本机 Lua 5.1~~ **已取消**：设备自带 `/mnt/us/koreader/luajit`，直接用它跑单测，与真机运行时 100% 一致，也规避了本机 Lua 版本选错的风险 | 单测在设备上用 KOReader 自带 luajit 执行 |
| T0.3 | 初始化 git 仓库，目录结构按下节创建，`.gitignore` 排除 `DeepSeek_API_KEY.txt`、`test_books/`、`*.log` | 首次提交完成 |
| T0.4 | 拷贝测试书籍（已完成 7 本：《人鼠之间》《欧维》《三体》《万历十五年》《红楼梦》《卡拉马佐夫兄弟》《哈利波特》） | `test_books/` 7 本 |
| T0.5 | **验证 KPW4 SSH 连通**：确认设备 IP、端口、登录凭据（越狱 Kindle 常见为 root + 空密码或自设密码）；记录 KOReader 插件路径（通常 `/mnt/us/koreader/plugins/`）；确认 KPW6 部署方式（SSH 或 USB） | PC 上 `ssh root@<kpw4-ip>` 可登录，`scp` 可传文件 |
| T0.6 | 部署脚本：`tools/deploy_kpw4.sh`（tar 管道 + SSH 覆盖推送）、`tools/pull_logs.sh`（拉 crash.log） | 一条命令完成"推送 + 拉日志"闭环；已配好免密登录（`~/.ssh/id_ywbf_kpw4`） |
| T0.7 | 准备 mock 测试框架：`tests/mock_koreader.lua`  stub 掉 `logger`、`UIManager`、`Device`、`DocumentRegistry` 等最小接口；`tests/run_tests.py` 驱动执行 | mock 环境能 require 一个空模块并断言 |

**红线检查**：T0.2 装错 Lua 版本会导致本机测试全绿、真机全挂。必须 5.1 语义。

---

## 2. 插件目录结构（M1 建好后不再大改）

```
YuanWangBookFriend.koplugin/
├── main.lua                  -- 插件入口，WidgetContainer 注册，菜单注入
├── _meta.lua                 -- 插件元数据（名称、版本、描述）
├── ywbf/                     -- 纯逻辑层（本机可测，不 require KOReader UI）
│   ├── config.lua            -- 设置读写、默认值、路径常量
│   ├── crypto.lua            -- API Key 加解密
│   ├── httpclient.lua        -- 网络抽象（真机 socket.http / 本机 mock）
│   ├── deepseek.lua          -- DeepSeek API 封装（chat/completions）
│   ├── queue.lua             -- 串行请求队列（超时/重试/退避）
│   ├── cache.lua             -- 回复缓存（hash 索引 + JSON 持久化）
│   ├── store.lua             -- 对话记录、X-Ray 数据存取（JSON 起步，量大再迁 SQLite）
│   ├── spoiler.lua           -- 防剧透引擎（进度换算、文本截断）
│   ├── context.lua           -- 上下文窗口截取（前后 N 字符、超长摘要）
│   ├── prompts.lua           -- 全部 prompt 模板集中管理
│   └── tokens.lua            -- token 估算与用量统计
├── ui/                       -- KOReader UI 层（真机验证）
│   ├── chatdialog.lua        -- 深聊全屏界面
│   ├── toastcard.lua         -- 轻问底部卡片 + 角标
│   ├── xraycard.lua          -- X-Ray 词条卡片
│   ├── graphview.lua         -- 人物关系图谱（M5）
│   ├── settings.lua          -- 设置页
│   └── menus.lua             -- 长按菜单 / 主菜单 / 手势注册
├── data/                     -- 运行时数据（全部在插件目录内，卸载即净）
│   ├── settings.json
│   ├── key.enc
│   ├── cache/
│   ├── history/
│   └── xray/
└── tools/                    -- 部署与测试脚本（不随包发布）
```

---

## 3. M1 骨架（预计 3 个工作日）

目标：插件在真机上出现菜单，能配置 Key（加密落盘），能通过队列发一次 DeepSeek 请求并把回复打印到日志。

| 任务 ID | 任务 | 关键实现点 | 验收 |
|---|---|---|---|
| T1.1 | `_meta.lua` + `main.lua` 骨架：继承 `WidgetContainer`，`init()` 注册主菜单入口 | 参考 T0.1 源码里 `plugins/` 下官方插件的标准写法 | KOReader 主菜单出现"远望书友"，点击弹空白对话框 |
| T1.2 | `ywbf/config.lua`：设置读写、默认值表、所有路径常量化 | 设置文件写插件目录 `data/settings.json`，**不碰** `G_reader_settings` | 改设置重启后保持；删插件目录后 KOReader 无任何残留（PRD §8.3） |
| T1.3 | `ywbf/crypto.lua`：Key 加密 | 设备唯一标识（`Device:getSerialNumber` 或 MAC hash）派生密钥 + AES；本机 mock 用固定盐 | 落盘文件无明文 Key；重启后解密可用 |
| T1.4 | 设置页 V1：Key 输入（掩码显示）、模型选择、保存/测试连通按钮 | `ui/settings.lua` + `InputDialog` | 真机上完成 Key 配置全流程 |
| T1.5 | `ywbf/httpclient.lua` + `ywbf/deepseek.lua`：POST `chat/completions`，超时 60s | Kindle 的 TLS 是最大未知项，**T1.5 是 M1 的探针任务，最先做** | KPW4 真机实际收到 DeepSeek 回复 |
| T1.6 | `ywbf/queue.lua`：串行队列，超时、2 次指数退避重试、失败回调 | 纯逻辑，本机 mock 测 | 单测覆盖：成功/超时/重试成功/重试耗尽 |
| T1.7 | `ywbf/tokens.lua`：按字符数粗估 token（中文 ≈ 字数的 0.6 倍 + 修正系数），落盘累计用量 | | 设置页可见累计 token |
| T1.8 | mock 单测：config / crypto / queue / tokens | | `run_tests.py` 全绿 |
| **M1 验收** | KPW4 + KPW6 装插件 → 配 Key → 菜单里"测试连通"收到 DeepSeek 回复；卸载插件目录后 KOReader 无变化 | | PRD §8.1/8.3 达成 |

**M1 风险闸门**：T1.5 若 Kindle TLS 失败（证书校验、TLS 版本），当天解决，方案备选：① 插件内置 CA bundle 并指定 `cafile`；② 降级 `https` 参数；③ 最坏情况走设备本地代理。不允许带病进 M2。

---

## 4. M2 核心问答（预计 6 个工作日）

目标：选中文字就能问，深聊/轻问双模式可用，释义/摘要/概念解释三件套上线，缓存生效，E-ink UI 达标。

### 4.1 逻辑层（本机 mock 可测）

| 任务 ID | 任务 | 要点 | 验收 |
|---|---|---|---|
| T2.1 | `ywbf/context.lua`：给定选区，截取前后各 800 字符（可配 400–2000），超长先截断后交由 AI 摘要 | 截断按段落边界对齐，不切断句子中间 | 单测：边界/超上限/文档头尾 |
| T2.2 | `ywbf/prompts.lua`：模板集中管理——释义、段落摘要、章节摘要、概念解释、深聊 system、轻问 system | 每个模板含输出格式约束（释义 ≤200 字、摘要 ≤300 字） | 模板渲染单测 |
| T2.3 | `ywbf/cache.lua`：key = hash(书籍指纹 + 选中文本 + 功能类型)，JSON 文件分书存储，LRU 上限 50MB | 指纹 = 文件路径 + 大小 + mtime 的 hash（不读全文，KPW4 扛不住全文 hash） | 单测：命中/未命中/容量淘汰；相同问题二次提问零请求 |
| T2.4 | `ywbf/store.lua`：对话记录按书分文件持久化（日期+角色+内容+关联选区） | | 单测：增删查、按书隔离 |

### 4.2 UI 层（真机验证）

| 任务 ID | 任务 | 要点 | 验收 |
|---|---|---|---|
| T2.5 | 长按菜单注入（F6.2）：解释 / 轻问 / 深聊 / 摘要 四个入口 | KOReader 高亮菜单扩展点，不用私有 hook | 四本测试书长按均出现菜单 |
| T2.6 | 深聊界面 `chatdialog.lua`（F1.1）：全屏多轮对话，选中文本作引子 | E-ink 规范：纯黑白、无阴影渐变；新消息局部刷新，输入框聚焦才全刷；多轮 >3 轮时历史自动摘要压缩（PRD §4.3） | KPW6 上 10 轮对话无整屏闪；token 消耗可见 |
| T2.7 | 轻问卡片 `toastcard.lua`（F1.2/F1.4）：底部卡片提交即返回，回复异步送达到角标；点击展开，可"转深聊" | 卡片 ≤1/4 屏高，3s 无操作缩为角标；提交到卡片消失 <500ms | 提交后立刻能翻页继续读 |
| T2.8 | 全局 AI 助手（F1.3）：主菜单入口 + 自由提问 | 复用 chatdialog，无选区上下文 | 菜单呼出，自由问答正常 |
| T2.9 | 释义/摘要/概念解释三功能（F2.1–F2.3）接入 UI：结果展示卡片（可复制、可转深聊追问） | 上下文窗口默认前后 800 字符 | 全部测试书各跑一遍三功能 |
| T2.10 | 断网降级：所有本地功能可用，请求失败给明确提示 | | 拔网后历史/缓存可浏览，请求有友好报错 |
| **M2 验收** | PRD §8.6 缓存命中验证；性能红线：KPW4 插件峰值内存 <40MB（`collectgarbage("count")` 采样）；UI 无卡死 | | |

**顺序建议**：T2.1–T2.4（2 天，本机）→ T2.5 + T2.6（1.5 天）→ T2.7（1 天）→ T2.8/T2.9（1 天）→ T2.10 + 验收（0.5 天）。

---

## 5. M3 防剧透（预计 4 个工作日）

目标：未读内容在 payload 中物理不可见，抓包可证。

| 任务 ID | 任务 | 要点 | 验收 |
|---|---|---|---|
| T3.1 | 进度读取适配层：`spoiler.lua` 封装 `ReaderRolling`（EPUB）与 `ReaderPaging`（PDF）两种位置接口，统一换算为"全书字符偏移" | EPUB 用 xp 位置 → 累加各章节纯文本长度估算偏移；PDF 按页号×页均字数估算，标注精度降级 | 四本测试书进度换算误差 <1 章 |
| T3.2 | 截断引擎：所有发往 DeepSeek 的上下文一律先过 `spoiler.truncate(text, progress)` | 按章节边界（默认）或百分比（可选）截断；多轮对话历史同样过管道 | 单测：截断点恰好/跨章/开头结尾 |
| T3.3 | system prompt 双保险：注入当前进度声明 + "禁止引用截断点之后内容" | 模板进 `prompts.lua` | 人工审查 payload |
| T3.4 | 剧透预警（F4.4）：AI 回复含指向未读章节的章节号/未读章节标题关键词时，本地替换为标准化模糊提示 | 本地正则 + 章节标题表，不额外消耗 API 调用 | 构造"问后续情节"用例，返回模糊提示 |
| T3.5 | 防剧透设置（F4.1/F4.5）：全局开关（默认开）、粒度选择（章节/百分比） | | 设置页可配，即时生效 |
| T3.6 | 全功能回归接入：M2 的释义/摘要/深聊/轻问全部走截断管道 | 管道放在 `deepseek.lua` 请求出口，单点强制，不靠各功能自觉 | 代码审查确认无旁路 |
| **M3 验收** | **抓包验证**（PRD §8.2）：Kindle 端开 KOReader 日志 / 本机中间代理记录 payload，构造"读到第 3 章问第 10 章情节"，确认 payload 无任何第 4 章后文本 | | 这是整个插件的卖点，验收从严 |

---

## 6. M4 X-Ray（预计 5 个工作日）

目标：词条生成、卡片展示、模糊匹配、剧情回顾闭环，全部增量、全部受防剧透约束。

| 任务 ID | 任务 | 要点 | 验收 |
|---|---|---|---|
| T4.1 | 章节切分器：EPUB 按 spine/NCX 切章，提取纯文本 | 复用 T3.1 的章节表 | 《三体》切章数与目录一致 |
| T4.2 | 词条抽取（F3.1）：对已读章节调 DeepSeek，结构化输出 JSON（名称/别名/类型[人物/地点/组织/事件]/首次出现章节/简介） | prompt 强制 JSON schema；本地解析容错（模型偶尔返回脏 JSON，重试一次再降级丢弃该章） | 《三体》读 5 章能抽出叶文洁/汪淼等词条 |
| T4.3 | 增量分析调度：记录每书"已分析到第 N 章"，触发时机 = 词条查询时若落后进度则补分析 | 绝不默认全书分析；全书分析做成显式操作 + 预估 token 确认弹窗 | 进度推进后词条自动增量更新 |
| T4.4 | 词条存储：`store.lua` 扩展 X-Ray 表，按书籍指纹关联；文件变更提示重新分析 | | 换同名不同版本的书触发提示 |
| T4.5 | 词条卡片 `xraycard.lua`（F3.2）：选中文字命中时弹卡片（档案 + 出场章节列表 + 跳转） | E-ink 静态渲染 | 选中"汪淼"出卡片，点章节可跳转 |
| T4.6 | 模糊匹配（F3.3）：编辑距离 + 别名表，置信度 <阈值时显示"是否指 XX？"确认 | | 选中"三水"也能匹配"汪淼"（别名），错字截断可匹配 |
| T4.7 | 剧情回顾（F3.4）：距上次打开 >3 天（可配）弹提醒，一键生成截至当前进度的回顾 | 输入 = 已读各章摘要（复用 T2 摘要缓存，控制成本）；输出 ≤500 字 | 模拟 mtime 构造"3 天未读"，回顾内容不含未读情节 |
| **M4 验收** | 《三体》半书流程：读→生成词条→中断 3 天→回顾→续读→词条增量更新，全程 token 消耗记录并符合预期量级 | | |

---

## 7. M5 增强与 V1.0 收尾（预计 5 个工作日）

| 任务 ID | 任务 | 要点 | 验收 |
|---|---|---|---|
| T5.1 | KPW4 精简模式（F7.2）：检测内存 <768MB 或设备为 KPW4 时自动启用——关动画、对话历史加载量减半、图谱降级为列表 | `Device` 能力探测；模式状态写入设置可手动覆盖 | KPW4 全程峰值内存 <40MB |
| T5.2 | 自定义手势（F6.1）：`GestureManager` 注册单指滑动/双指/长按，映射到 呼出助手/轻问/剧情回顾 | 设置页提供手势-功能映射配置 | KPW6 手势触发各功能正常 |
| T5.3 | 人物关系图谱 `graphview.lua`（F3.5）：Lua 力导向简易布局 → 静态灰度图；KPW4 降级列表 | 双指缩放等触控增强留待 M6 安卓适配 | 《三体》关系图可读 |
| T5.4 | 作者介绍（F2.4）：基于书籍元数据生成作者卡片 | 走缓存，一书一次 | 四本测试书作者卡片正常 |
| T5.5 | 书库智能分类（F5.1）：扫书库元数据（只发元数据，不发正文），AI 聚类，分类浏览视图 | 书库 >50 本时分批请求 | 分类结果可浏览、可刷新 |
| T5.6 | 阅读推荐（F5.2）：基于已读书单 + 阅读统计生成书单 | 纯书单文本，无外链 | 输出合理书单 |
| T5.7 | 用量与隐私面板：累计 token、预估费用、网络白名单声明（仅 api.deepseek.com）、发送内容预览（F8.2 P1 项，做简化版） | | 面板数据准确 |
| T5.8 | 全量回归 + KPW4/KPW6 双机验收 + 打包发布清单 | 按 PRD §8 验收标准逐条过（neo3ultra 相关条目移交 M6） | 全部通过 |

---

## 8. 测试策略

### 8.1 三层测试

| 层 | 范围 | 工具 | 频率 |
|---|---|---|---|
| 本机 mock 单测 | `ywbf/` 全部纯逻辑模块 | Lua 5.1 + `tests/run_tests.py` | 每次提交前 |
| 真机功能测试 | UI 层、设备适配、端到端流程 | KPW4（SSH 直连，日常迭代主战场） | 每个任务完成后 |
| 里程碑验收 | 性能红线、抓包、双机矩阵 | KPW4 + KPW6 | 每个里程碑冻结前 |

### 8.2 测试书籍分工

| 书 | 体量 | 用途 |
|---|---|---|
| 《人鼠之间》 | 190K | 日常快速回归（短、加载快） |
| 《一个叫欧维的男人决定去死》 | 303K | 问答/摘要功能基准 |
| 《三体》 | 2.0M | X-Ray 主测试书（人物多、概念多、非线性段落） |
| 《万历十五年》 | 8.1M | 非虚构基准：概念解释、作者介绍、大文件性能 |
| 《红楼梦》 | 3.2M | **用户指定必测**：超大型人物体系（X-Ray 词条量与关系图谱压力测试）、诗词典故（概念解释）、长篇章回体（防剧透按章节粒度） |
| 《卡拉马佐夫兄弟》（耿济之译本） | 3.6M | **用户指定必测**：俄文人名长且多别名/昵称（模糊匹配与别名表的核心测试书）、多线叙事（剧情回顾） |
| 《哈利波特》（全集合卷） | 18M | **用户指定必测**：超大文件加载与内存红线、系列合集章节切分、剧透敏感度高（防剧透端到端用例） |

**注意**：俄文/古典人名的别名匹配（T4.6）以《卡拉马佐夫兄弟》（如"米嘉/德米特里/米坚卡"）和《红楼梦》（如"宝二爷/贾宝玉/怡红公子"）为验收基准；《哈利波特》18M 文件加入 KPW4 每里程碑内存红线测试集。

### 8.3 性能红线（每里程碑必测，KPW4）

- 插件空闲常驻内存 <20MB，峰值 <40MB
- 轻问提交到卡片消失 <500ms
- KOReader 启动时间增量 <300ms
- 连续 5 请求 UI 无卡死

### 8.4 关键专项测试

- **防剧透抓包**（M3）：payload 中搜索未读章节特征串，必须为 0 命中。
- **缓存零请求**（M2）：相同问题第二次提问，DeepSeek 请求计数不增。
- **卸载洁净**（M1 起每里程碑）：删插件目录 → KOReader 重启 → 无任何报错与残留。

---

## 9. 风险跟踪（继承 PRD §7，落实到任务）

| 风险 | 应对任务 | 状态检查点 |
|---|---|---|
| ~~Kindle TLS/证书兼容~~ | **已解除（2026-09-19 实测）**：KPW4 上 luasec(ssl.https) 直连 api.deepseek.com 成功，且**无需指定 cafile**；已用真实 Key 完成 chat/completions 调用（1s 返回 200）。代码保持 `protocol="tlsv1_2"` 与域名白名单即可 | ~~M1 第一天~~ 已完成 |
| 设备 `/var`（含 /tmp）tmpfs 32M 常年 100% 满 | 临时文件一律写 `/mnt/us/...`（如 `/mnt/us/ywbf_dev/`），禁止写 /tmp；`koreader.sh` 启动时会因空间不足报 `cp: write error`，属非致命 | 每次设备操作 |
| KPW4 OOM | T5.1 + 每里程碑红线 | 每里程碑 |
| KOReader 在 KPW4/KPW6 上的 API 行为差异 | T0.1 源码核查 + 双机真机验证 | 每个 UI 任务 |
| KPW4 SSH 断连/不稳定影响迭代效率 | T0.5 验证 + 部署脚本带重试；备选 USB 拷贝 | 阶段 0 |
| 跳读场景"已读"认定 | T3.1 以当前位置为准；手动标记入口列入 V1.1 | M3 评审 |
| 脏 JSON 解析 | T4.2 容错 | M4 |
| 全书分析成本失控 | T4.3 增量默认 + 确认弹窗 | M4 |

---

## 10. 排期汇总

| 阶段 | 内容 | 预估 |
|---|---|---|
| 阶段 0 | 环境搭建（含 KPW4 SSH 部署闭环） | 0.5 天 |
| M1 | 骨架 | 3 天 |
| M2 | 核心问答 | 6 天 |
| M3 | 防剧透 | 4 天 |
| M4 | X-Ray | 5 天 |
| M5 | 增强与收尾（Kindle 版 V1.0） | 5 天 |
| **合计（Kindle 版 V1.0）** | | **约 23.5 个工作日** |
| M6 | 安卓版适配（掌阅 neo3ultra）：adb 部署链路、触控增强、安卓端差异回归——**Kindle 版稳定后另行启动** | 另估（初估 3–5 天） |

缓冲建议：Kindle TLS（T1.5）和图谱布局（T5.3）是两个最可能爆工期的点，各预留 1 天机动，Kindle 版按 **26 个工作日** 预期。

---

## 11. 实测结论与进度（2026-09-19）

### 11.1 设备环境实测（KPW4，192.168.3.89:2222）

| 项 | 结论 |
|---|---|
| KOReader 版本 | v2026.07.2（满足 2026.07+ 要求） |
| 运行时 | `/mnt/us/koreader/luajit`（LuaJIT，Lua 5.1 语义——**没有 5.2 位运算符，必须用 `bit` 库**） |
| HTTPS | `require("ssl.https")`（luasec）+ `/etc/ssl/certs/ca-certificates.crt` 可用；**不指定 cafile 也能握手成功** |
| DeepSeek | 真实调用 1 秒返回 200，usage 正常 |
| 加密 | `ffi/crypto` 提供 PBKDF2 + AES 解密；加密侧 EVP 函数需自行 `ffi.cdef`（已验证 AES-256-ECB 加解密往返一致） |
| 插件自身目录 | PluginLoader 注入 `plugin_module.path`，即 `self.path`（官方插件通用做法） |
| 后台任务 | `frontend/ui/trapper.lua`（`Trapper:wrap`）可用；KOReader 自带 `frontend/httpclient.lua` 走 turbo 且 `verify_ca=false`，**不采用**，自写 luasec 客户端 |
| 模块路径 | `package.path` 只在插件 dofile 期间含插件根目录 → **所有 require 必须写在 main.lua 顶部** |
| 设备坑 | `/var`（含 /tmp）32M tmpfs 常年 100% 满 → 临时文件必须写 `/mnt/us/` |

### 11.2 M1 进度：已完成

- [x] T0.1（以设备源码为参考）/ T0.3 git 初始化 / T0.4 测试书 7 本 / T0.5 SSH 免密 / T0.6 部署脚本 / T0.7 测试框架
- [x] T1.1 插件骨架（菜单已能注册，KOReader 加载无报错）
- [x] T1.2 配置模块（含递归 mkdir、设置持久化、用量统计）
- [x] T1.3 加密模块（AES-256-ECB + PBKDF2，XOR 降级）
- [x] T1.4 设置页 V1（Key 掩码输入、连通性测试、模型切换、防剧透开关、用量、隐私说明）
- [x] T1.5 **DeepSeek 连通探针（最大风险，已解除）**
- [x] T1.6 串行队列（重试 + 指数退避）
- [x] T1.7 Token 估算与用量统计
- [x] T1.8 单测：设备端 24 项全绿

### 11.3 真机验证结果

- 单元测试：24 passed / 0 failed（在 KPW4 上用 KOReader 自带 luajit 跑）
- 端到端集成自检：`配置 → AES 加密 → 域名白名单 → HTTPS → DeepSeek → 用量统计` 全链路 OK
- 插件加载：crash.log 出现 `YWBF: plugin initialized`，KOReader 无报错
- 零污染校验：KOReader 全局 `settings.reader.lua` 中插件相关键为 0，数据全在插件目录内
- API Key：落盘为 `aes1:` 前缀密文，设置文件中不含明文

### 11.5 M2 进度（进行中）

已完成：
- [x] T2.1 `ywbf/context.lua`：前后各 800 字符窗口、段落边界对齐、`fromSelection`（原文/归一化双路匹配）、超长截断
- [x] T2.2 `ywbf/prompts.lua`：释义/摘要/概念/深聊/轻问模板，输出字数硬约束（释义 200、摘要 300）
- [x] T2.3 `ywbf/cache.lua`：md5 键（书籍指纹+选中+功能+模型）、LRU 淘汰、命中零请求
- [x] T2.4 `ywbf/store.lua`：对话历史按书分文件、追加/搜索/删除/清空、X-Ray 存取位
- [x] T2.5 长按菜单注入：`highlight:addToHighlightDialog` 注册 AI 解释 / AI 摘要 / 轻问 / 深聊
- [x] T2.6 深聊：`ui/chatdialog.lua`（多轮追问，历史带入上下文）
- [x] T2.7 轻问：`ui/toastcard.lua` + `Asker:submitAsync`（提交即返回，Notification 送达，菜单查看）
- [x] T2.8 全局助手：主菜单 / Dispatcher 动作 → 深聊界面
- [x] T2.9 释义与摘要结果展示：TextViewer 纯文本阅读
- [x] T2.1–T2.5 单测：设备端 72 项全绿

待真机交互验证（需要人在设备上点，脚本无法模拟触摸）：
- [ ] 长按选中 → 四个 AI 入口出现且点击可用
- [ ] 深聊/轻问/释义/摘要实际返回内容
- [ ] KPW4 内存红线（峰值 <40MB）

关键实现记录：
- 长按菜单扩展点：`ReaderHighlight:addToHighlightDialog(idx, fn)`，fn 返回 `{text, callback, show_in_highlight_dialog_func}`，选中文本在 `this.selected_text.text`
- 上下文来源：`document:getTextFromXPointer(pos0)` 取当前页文本（PDF 兜底 `getPageText`），取不到时退化为只用选中内容，日志会打印 `YWBF: page text len`
- 菜单层级：`sorting_hint = "tools"`，与觅阅·微信读书、Simple UI 同级（`more_tools` 会被收进更深层）
- 重启 KOReader 必须 `setsid nohup ./koreader.sh`，否则 SSH 会话结束时 KOReader 会自行退出

### 11.4 常用命令

```bash
# 推送插件到 KPW4
./tools/deploy_kpw4.sh
# 拉日志
./tools/pull_logs.sh 200
# 设备端单测
ssh -i ~/.ssh/id_ywbf_kpw4 -p 2222 root@192.168.3.89 \
  "cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs \
   YWBF_TEST_DIR=/mnt/us/ywbf_dev/testdata \
   ./luajit /mnt/us/ywbf_dev/tests/run_tests.lua"
# 重启 KOReader（必须用 setsid 脱离会话，否则会被 SSH 断开带崩）
./tools/restart_koreader.sh
# 端到端验证（读加密 Key → 上下文 → prompt → 真实请求 → 缓存/历史）
scp tools/verify_e2e.lua root@192.168.3.89:/mnt/us/ywbf_dev/
ssh ... "cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs ./luajit /mnt/us/ywbf_dev/verify_e2e.lua"
# 开发期注入 API Key（用设备自带 luajit 跑插件的 Config+Crypto，盐与 KOReader 一致）
scp tools/set_key.lua root@192.168.3.89:/mnt/us/ywbf_dev/
echo "sk-xxx" | ssh ... "cat > /mnt/us/ywbf_dev/api_key_dev.txt"
ssh ... "cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs ./luajit /mnt/us/ywbf_dev/set_key.lua"
```

**已知设备坑（已实测）**：

| 坑 | 现象 | 处理 |
|---|---|---|
| `/var`（32M tmpfs）被塞满 | KOReader 启动脚本 `cp: write error: No space left on device`，起不来 | 清 `/var/tmp/*.raw`（framebuffer 快照，可再生）。临时文件永远写 `/mnt/us/`，不要写 `/tmp` |
| SSH 随 KOReader 一起消失 | kill 掉 KOReader 后 2222 端口连不上 | dropbear 由 KOReader 的 SSH 插件提供。**必须先在设备上手动点 KOReader 图标**，SSH 才会恢复 |
| `deploy` 会删掉用户配置 | API Key、缓存、历史一起被 `rm -rf` 清掉 | `deploy_kpw4.sh` 已改为先把 `data/` 挪出去，部署完再挪回来 |

---

**下一步**：M2 核心问答（T2.1–T2.10）。先做逻辑层（context / prompts / cache / store，本机可测），再做 UI（长按菜单注入 → 深聊界面 → 轻问卡片 → 释义摘要概念解释）。
