# Desire 路线图（0.1.x → 0.2.x）

> 基线：v0.1.0（2026-09-18）。
> 定位：**AI 原生浏览器**——浏览器本体是 Agent 的执行环境。证据即结构：
> `Features/Agent/` 为最大模块（45 文件：20+ 工具面、多模型路由、MCP 客户端、
> 审批/记忆/技能/调度），40+ 端点自动化桥是对外驱动与 QA 的一等接口。
> 节奏：0.1.x 每 1–2 周一个 tag；每个版本含桥端点与回归验收。
> 通用浏览器功能不丢，但只在服务主线时提前（见 backlog）。

## 版本总览

| 版本 | 主题 | 一句话 |
|---|---|---|
| 0.1.1 | Agent 可靠性 | 审批/定时任务全链路桥测，BUG-K 诊断 |
| 0.1.2 | 交互补漏 | savePage、密码提示条、下载通知节流 |
| 0.1.3 | 质量门 | CI 启动冒烟、启动性能基线、崩溃诊断导出 |
| 0.1.4 | 桥事件流 | SSE 推送替代轮询 |
| 0.1.5 | 桥自描述+安全 | `GET /` 端点索引、可选 token 鉴权 |
| 0.1.6 | MCP Server v1 | 外部 AI 直连驱动 Desire（核心工具面） |
| 0.1.7 | MCP Server v2 | 多标签/下载/审批联动，真实客户端联测 |
| 0.1.8 | 多窗口 Agent | 跨窗定位、并行任务 |
| 0.1.9 | 无人值守作业 | 运行历史、失败通知、重试策略 |
| 0.1.10 | 页面监控 | watch/diff/notify 预设 |
| 0.1.11 | 结构化提取 | 表格/列表 → JSON/CSV |
| 0.1.12 | 媒体流水线 | 嗅探+下载+ffmpeg 技能包 |
| 0.1.13 | 网络拦截 v1 | mock/改写（Agent 测试台） |
| 0.1.14 | 网络拦截 v2 | 真节流 + pixelRatio，响应式正名 |
| 0.1.15 | Agent 记忆与技能管理 | 记忆可查可编辑、技能导入/版本化 |
| 0.1.16 | 视觉与命令面板 | 全页/元素截图、⌘K 统一入口 |
| 0.2.x | 成熟弧线 | 见文末（passkey、Profiles、WebExtension、自动更新…）✅ |
| 0.3.x | 智能体浏览器 | Tab Crew 并行作业、页面感知、WebExtension v2、同步… |

---

## 0.1.x 详细规划（✅ 已全部完成 — v0.1.16，2026-09-19）

> 实际交付与下述规划一致，另顺带修复多个真 bug（查找计数、会话恢复、
> 阅读模式卡死、密码弹窗阻塞、真实网络捕获、handler 崩溃等）。

### 原始规划（存档）

### 0.1.1 — Agent 可靠性
- BUG-K 退出挂起诊断：关闭期枚举存活 URLSession 任务与未决 continuation 并打日志，定位后修。
- 审批全链路桥测：定时任务触发 → 工具审批挂起 → `/approvals` 代决策 → 任务完成。
- 定时任务与 Agent 会话的边界修整：任务失败时的会话清理与状态复位。
- 验收：桥回归新增审批/调度用例全绿；连续 100 次 SIGTERM 无挂起。

### 0.1.2 — 交互补漏
- savePage：⌘S 保存页面（webarchive），同步成为 Agent 存档原语。
- 密码提示条：sheet → 地址栏下方轻条（"保存/本次不/永不再问此站"），桥可代答。
- 下载完成通知节流：批量完成聚合为一条 + Dock 角标。
- beforeunload 提示与密码提示条同层复用（同一非阻塞条组件）。

### 0.1.3 — 质量门
- CI 启动冒烟：Release 产物 `open --args --automation` + `GET /state` 200 才上传。
- 启动性能基线：冷启动到首窗可交互打点（os_signpost），立预算（<400ms）。
- 崩溃/卡顿诊断导出：MetricKit 数据在设置页一键导出（配合 issues 反馈）。
- x86_64 编译检查跑一次 CI，或宣布 arm64-only。

### 0.1.4 — 桥事件流
- `GET /events`（SSE）：页面就绪、下载开始/完成、审批挂起、标签增删、
  beforeunload 挂起、导航提交——驱动方从轮询升级为事件响应。
- 事件去重与背压：慢消费者丢中间态、保留终态。
- 验收：用 curl 驱动一整套"导航→等就绪事件→读取→下载→等完成事件"流程。

### 0.1.5 — 桥自描述 + 安全
- `GET /`：机器可读端点索引（路径/方法/参数/示例 JSON），任意 AI 免文档上手。
- 可选 token 鉴权：`--automation-token` 启动参数；默认 localhost 裸奔不变，
  公网/局域网暴露场景有锁可用。
- CORS 与并发策略整理：多驱动同时连接的行为定义。
- curl 速查文档：`docs/BRIDGE.md` 按场景组织（浏览/下载/Agent/断言）。

### 0.1.6 — Desire as MCP Server v1
- Streamable HTTP MCP Server（复用桥服务器骨架 + BrowserToolProvider 工具定义）。
- 首批工具：navigate / getPageSnapshot / click / fill / pressKey / waitForText /
  screenshot / pageText。
- 会话模型：一个 MCP 连接绑定一个窗口（默认活动窗）。
- 验收：Claude Desktop / 任意 MCP 客户端真实连上并完成一个多步网页任务。

### 0.1.7 — MCP Server v2
- 工具面补全：多标签（newTab/switch/close）、下载（start/进度事件）、
  find、history/bookmarks 检索、setUploadFile。
- 审批联动：MCP 侧的危险工具走应用内审批 UI（或按配置自动放行）。
- 事件桥接：MCP notifications 推送页面就绪/下载完成。
- 多客户端并发语义定义（连接级窗口锁）。

### 0.1.8 — 多窗口 Agent 联动（挂账转正）
- 工具与提示词支持目标窗口：`window` 参数（"在窗口 2 执行"）。
- 并行任务：每窗一个 Agent 会话，互不串台；`/state` 按窗呈现。
- Agent 面板窗口指示器 + 跨窗任务编排提示词模板。

### 0.1.9 — 无人值守作业
- 定时任务运行历史：起止/结果摘要/失败原因持久化（DiskStore）。
- 失败通知（系统通知）+ 桥事件；重试策略（次数/间隔）。
- 任务暂停/恢复/手动触发（面板 + 桥端点）。

### 0.1.10 — 页面监控
- `watchPage` 预设：定时重读 URL + 内容 diff（正文指纹/选择器文本）。
- 变更通知（系统通知 + SSE + 任务历史），diff 摘要入结果。
- 场景包装：价格/库存/公告监控一键模板。
- 验收：桥测"改测试页内容 → 下一轮询周期收到变更事件"。

### 0.1.11 — 结构化提取
- `extractTable` / `extractList` 工具：页面表格/列表 → 结构化 JSON/CSV。
- 选择器或 AI 引导两种模式；大表分页抓取与去重。
- 落工作区（复用 writeFile）→ 与定时任务组合即采集流水线。

### 0.1.12 — 媒体流水线技能包
- 内置 `media` 技能：嗅探（已有）→ 下载（已有）→ ffmpeg 转码/抽音频/
  截片段（runCommand 已有）编排成一句话任务。
- 失败自愈：格式不支持时自动换源（嗅探列表降级）。
- 技能清单页展示内置技能与来源。

### 0.1.13 — 网络拦截 v1
- 请求 mock/改写/阻断（WebKit Network Interception），规则按标签生效。
- 桥端点：`POST /intercept`（规则增删查）——Agent 测试台的核心原语。
- 场景：mock 第三方 API 做可复现 Agent 测试；屏蔽规则的真实执行层。

### 0.1.14 — 网络拦截 v2
- 真网络节流（预设：3G/慢4G/自定义）接入响应式模式，**拆掉假 UI**。
- pixelRatio/DPR 模拟补齐（响应式挂账清零）。
- 拦截规则录制：从网络面板一键转 mock 规则。

### 0.1.15 — Agent 记忆与技能管理
- 记忆可查可编辑：MemoryExtractor 产出在面板中审阅/修改/删除（当前黑盒）。
- 技能导入：从本地目录/repo URL 装载技能包，带版本与更新检查。
- 记忆作用域：全局 vs 按域（某站点专属偏好不污染全局）。

### 0.1.16 — 视觉与命令面板
- 视觉工具：全页截图（滚动拼接）、元素级截图（ref 定位）、截图直入模型
  （视觉模型路由时）。
- ⌘K 命令面板：全部浏览器命令/设置项/标签/书签统一模糊入口
  （BrowserCommand 枚举即清单，CommandBus 即执行层）。
- 面板内直接唤起 Agent（选中结果回车 = 让 Agent 执行）。

---

## 0.2.x — 成熟弧线（详细规划，✅ 0.2.0 已发布）

> 0.2.0（外部 AI 完全体：MCP 鉴权、事件心跳、官方驱动示例）已发布。
> 以下为 0.2.1 → 0.2.16 的逐版规划，按依赖排序：分发闭环 → 两大功能
> 山头（Profiles、Passkey）→ Agent/工程深化 → UX 批次。

### 0.2.1 — UX 快赢批次（本版）
- **书签栏**：工具栏下方常驻，叶子直达/文件夹下拉/与面板同源。
- **剪贴板 URL 直达**：地址栏聚焦且剪贴板为 URL 时首行建议。
- **错误页文案复核**：DNS/TLS/断网分类映射全查。

### 0.2.2 — 稳定性专项
- MetricKit 载荷趋势本地看板；50 标签 × 8h soak；内存水位休眠 v1。

### 0.2.3 — 反馈闭环 v2 ✅（v0.2.3）
- 更新横幅（查看/跳过此版本）+ 设置页手动检查按钮。

### 0.2.4 — MCP 会话与窗口绑定（窗口绑定 ✅ v0.2.4；listChanged 未做）
- Mcp-Session-Id → 窗口绑定（工具带 window 参数覆盖）。
- tools/listChanged 通知；--mcp-token 鉴权文档化进 README。

### 0.2.5 — MCP resources 与 prompts ✅（v0.2.12 交付）
- page://<tab>/text|html|screenshot 作为 MCP resource；常用任务 prompt 模板。
- 长任务进度经 SSE progress 通知。

### 0.2.6 — 审批策略引擎 ✅（提前为 v0.2.5 交付）
- 按工具/按域放行规则（持久化 + 面板管理）；审批历史日志，桥可查。

### 0.2.7 — 记忆 v2 ✅（v0.2.7）
- 记忆搜索 + 导入导出 + Agent 可编程读写（MCP 工具）。
- 低命中老旧事实自动降权（pinned 豁免）；右键"记住此站"。

### 0.2.8 — 媒体流水线 v2 ✅（v0.2.8）
- HLS 多码率画质选择；批量队列 UI；音频抽取预设。

### 0.2.9 — Profiles v1（人物级隔离）✅（基础设施 v0.2.9 + 窗口绑定/切换器 v0.2.10）
- Profile 模型 + 独立 WKWebsiteDataStore + 窗口绑定 + 切换器。
- Agent 按 Profile 取上下文。

### 0.2.10 — Profiles v2（部分：按 Profile 数据作用域/导入导出未完成）
- 书签/历史/密码/快拨按 Profile 作用域；导入导出（密码走 Keychain）。

### 0.2.11 — 密码中心 ✅（v0.2.11）
- 生成器 + CSV 导入导出 + 修改密码检测。

### 0.2.12 — Passkey（entitlement 门控）
- WebAuthn 平台凭据创建/认证 UI；Agent 代登录打通。

### 0.2.13 — WebExtension API v1 ✅（v0.2.16 交付）
- storage.local / tabs 事件 / notifications 子集；兼容性测试站。
- 交付说明：API 挂在 `desireExtensions` 隔离世界（页面不可见），
  宿主为内置 PluginStore 用户脚本（Greasemonkey 形态），桥可编程
  装插件并直读隔离世界。

### 0.2.14 — 性能与加固 ✅（v0.2.15 交付）
- 长会话（50+ 标签）回归；下载高危类型落地确认；混合内容警示。

### 0.2.15 — 分屏浏览 ✅（v0.2.13 交付，含菜单补全/书签栏开关）
- 同窗口双标签并排（ResizableDivider 已有地基）。

---

## 0.3.x — 智能体浏览器（规划中，2026-09-19）

> 定位跃迁：0.1.x 把浏览器做成 Agent 的执行环境（桥/MCP/工具面），
> 0.2.x 补齐浏览器本体的成熟弧线。0.3.x 的主线是**把 Agent 变成
> 浏览器的一等公民**：多标签并行作业、页面级感知、扩展生态闭环、
> 性能与分发成熟化。发布号继续按时间顺延（当前已至 v0.2.19）。

### 0.3.1 — Agent 多标签并行作业（Tab Crew v1）✅
- Agent 会话可声明"作业组"：一次任务派发 N 个标签并行浏览
  （搜索多引擎比对、多商品比价、批量信息收集），结果聚合回主会话。
- 作业组视图：Agent 面板显示并行标签的进度瓦片（复用标签概览的
  活 webview 瓦片）；取消单个子任务不影响其他。
- 桥 `/agent/crew`（create/status/cancel）；SSE 事件
  crewTaskStarted/Finished/Failed。
- 验收：一句话任务"在 3 个电商比价 X 并汇总最低价"→ 3 标签并行 →
  结构化汇总。

### 0.3.2 — 页面感知 v1（Page Awareness）✅（DOM 订阅留 v2）
- Agent 工具面增加 `waitFor(selector|text|networkIdle)`：替代
  sleep 轮询，页面就绪即继续（超时可配）。
- 视口语义升级：click/fill 支持元素截图回证（act + evidence 对），
  审批面板展示"Agent 要点哪"的截图。
- DOM 变化订阅：`observeDOM(selector, callback)` 工具——
  单页应用的路由跳转/弹窗出现可被 Agent 感知。

### 0.3.3 — WebExtension v2：manifest 装载与 popup ✅
- manifest.json v3 子集装载（name/version/icons/permissions/
  content_scripts），从 .msex zip 包安装（桥 + 面板拖入）。
- 每插件 popup 页（工具栏固定图标点击弹出 HTML 面板，替代/并存
  "运行一次"）。
- 每插件独立 storage 命名空间（`browser.storage.local` 按插件隔离，
  迁移现有共享存储）。
- 验收：写一个真实的小扩展（如 GitHub star 计数）manifest 装载 →
  popup 可用 → 存储隔离。

### 0.3.4 — 性能成熟化 ✅（8h 全量 soak 待长跑窗口，工具已就绪）
- 50+ 标签 × 8 小时 soak 自动化（桥驱动 + RSS/能耗采样入
  TEST-REPORT）；屏幕外瓦片降级快照（概览分级渲染）。
- 启动预算复测：冷启动 <400ms（os_signpost）在真实会话（30 标签
  恢复）下达标；超标则懒加载非关键 Store。
- 下载/网络面板内存：条目上限 + 虚拟化列表。

### 0.3.5 — Profiles 闭环 ✅（多窗口异人物并行留 v2）
- 书签/历史/密码/快拨按 Profile 作用域（0.2.10 挂账转正）。
- Profile 切换器进工具栏（头像菜单）；窗口级"以 X 身份打开"右键。
- 密码导出走 Keychain 授权（0.2.10 规划保留项）。
- Agent 按 Profile 取上下文（工具调用带 profile 参数）。

### 0.3.6 — 智能表单与自动登录 ✅（保存字段级确认留 v2）
- FormAutofill 升级：地址/信用卡字段分类（frosted 自动填充提示条）；
  保存时字段级确认（不是整表覆盖）。
- 检测登录页 → 有存档凭据时一键填充+提交（Agent 可代执行，走审批）。
- 双因素提示条：检测到 OTP 输入框时提醒从密码备注取码。

### 0.3.7 — 阅读与研究模式
- 阅读模式增强：字体/行距/主题设置持久化；内嵌翻译对照。
- 页面批注 v1：选中文本高亮（黄色系四色）+ 侧栏笔记列表 + 导出
  Markdown；高亮数据按 URL+XPath 持久化。
- Agent 联动："总结本页所有高亮"。

### 0.3.8 — 分发成熟化
- Sparkle 式应用内自更新（当前只检查不更新）：下载 + 签名校验 +
  重启安装；SHA256 在 Release notes 固化。
- 首启动引导（onboarding）：权限说明/默认浏览器引导/Agent 配置
  三步走。
- 崩溃回收：异常退出下次启动提示"恢复上次会话"（现有会话恢复的
  兜底分支）。

### 0.3.9 — Passkey（挂账，等 Apple entitlement）
- WebAuthn 平台凭据 UI；Agent 代登录打通（依赖 Apple 审批
  `com.apple.developer.web-browser.passkeys`，材料见
  docs/PASSKEYS-APPLE-REQUEST.md）。

### 0.3.10 — 账号云同步 v1（再议后转正）
- 端到端加密的书签/阅读列表/设置同步（自建对象存储后端，Keychain
  存密钥，服务器零知识）。
- 多设备冲突解决（last-write-wins + 向量时钟）。
- 明确不做：历史/密码上云（密码走 Keychain 本机 + 手动导出）。

## Backlog（浏览器本体，按需提前）

- 书签栏（当 Agent 需要"地址簿"时提前）
- 历史同 URL 归并视图 + 历史搜索
- per-domain JS/自动播放开关（SiteSettings 扩展）
- 标签拖出成窗/回拖合并、分屏浏览（Resizer 已有地基）
- 密码生成器/CSV 迁移（挂 0.2.1 登录主题）
- 错误页文案复核、剪贴板 URL 直达建议

## 明确不做（本阶段）

- iOS/iPadOS 移植、Firefox/Edge 系扩展协议兼容（只做 Chrome/manifest v3 子集）、
  内置 LLM 推理（Agent 走用户配置的云端/端侧模型）。

## 质量门（每版通用）

- CI：Release 编译 + 产物 + 启动冒烟（0.1.3 起生效）。
- 每个功能 PR 必须带桥端点与回归用例；0.1.4 起 SSE 事件纳入断言。
- 发版：全量桥回归绿 → 功能冻结 → tag → Release（附 SHA256）。
