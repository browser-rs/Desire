# v0.8.38 规划稿（2026-11-02，待过目）—— 连成一片：常规迭代 + Remote 2.0 + API 2.0

> 0.8.33–0.8.37 新增了 81 个工具箱工具、电子书/翻译/朗读、媒体剪辑、办公查看器、跨设备同步；
> **Remote app 和 API 没有同步跟上**：手机还看不到书架/工具/媒体，API 还没有配额、
> 账号生命周期、可观测性和能力声明。本版是三轨并行的平台版：
> ① 常规四主题迭代不能缺席；② Remote 2.0 把新内容接到手机；③ API 2.0 把服务端补齐。

## 一、现状核实（规划前，2026-11-02）

**常规线（0.8.37 及 backlog 遗留）**

- **工作区**：`WorkspaceStore.save(name:tabManager:)` 可保存标签快照，workspace 域已同步；
  但没有"一键把当前标签交给另一台设备"的入口，Remote 也看不到工作区。
- **Agent 成本**：主对话 token/成本有记账，`modelPrices` 精确匹配；但 critic/标题生成/
  记忆整理/crew 旁路调用**不进对话成本**（AGENTS 已知缺口）。
- **发送到手机**：Remote 是"手机拉 Mac 快照"；Mac 侧没有"把当前页/选区/书摘主动发到手机"。
- **工具箱**：81 个工具单次执行；没有"多步骤流水线/批处理"。
- **媒体**：剪辑/播放/下载齐全；**没有视频转码、视频→GIF**（0.8.33 明确"下一版"）。
- **Office**：查看/编辑器/转换在；没有文件夹级批量转换队列 UI（目前靠 Agent 或逐个）。
- **Agent 工具面**：toolDefs 已含 toolbox/media/books/sync 等新工具；能力页/评估集
  尚未系统性覆盖这些族。

**Remote app（apps/ios/DesireRemote）**

- 三 Tab：会话 / Agent / 设置；已有会话、聊天、审批、提问、计划、子代理、白板只读、
  统计、轨迹、模型、任务、通知策略、下载、最近文件、摘录、简报、互动、记忆、归档。
- **没有阅读页**：看不到书架/进度/书签/高亮/阅读统计；不能"在 Mac 上继续读"。
- **没有工具箱**：81 个纯工具手机端不可用。
- **通知只有 `turnDone`**：审批/提问没有即时通知，后台/锁屏容易错过。
- **没有离线缓存/发件箱**：断网时列表空白，输入的消息只能丢。
- **iPad/横屏未专门适配**：TARGETED_DEVICE_FAMILY 1,2，但界面仍是 iPhone 单列。
- **没有工作区入口**：Mac 的工作区/标签接力手机看不到、打不开。
- **文件/媒体只有文件名**：没有缩略图/元数据/详情。
- **连接体验**：配对/重连/延迟/设备列表分散，断线后缺少明显状态。

**API（crates/api）**

- 已有：auth（注册/登录/refresh/改密/设备/QR/key escrow）、sync（15 域/GC/
  key check/分页/500 条上限/256KB payload）、remote（配对 10 分钟 TTL、inbox 24h TTL、
  pull/WS/push）、growth、demo；`cargo test` 覆盖。
- **没有按用户/域的配额**（行数/字节/日推送量），sync 高频写入没有每用户限流。
- **remote inbox 只有 delivered_at**，没有客户端 ack/游标/分页与清理指标。
- **没有账号删除/数据导出**接口；设备有 revoke，但没有"全部吊销/最后在线"。
- **OpenAPI 注解不全**：sync/remote/growth 部分端点缺 `#[utoipa::path]`/schema。
- **没有服务端能力声明**：客户端不知道服务端支持哪些同步域（ebooks 未部署只能靠失败）。
- **可观测性**：`/health` 很浅，无 request id、无结构化错误码、无 metrics。
- **admin CLI 单薄**：缺用户/设备/配额/inbox/GC 的运营命令。
- **配对安全**：TTL 有，claim 频率/失败审计/一键吊销全部设备的运营面不足。

## 二、目标

1. **常规线不断档**：四主题每块至少 1–2 件实质功能，且能独立发版。
2. **Remote 2.0**：手机能看/能操作新内容（阅读、工具箱、工作区、通知、离线、iPad）。
3. **API 2.0**：配额/限流、inbox 可靠性、账号生命周期、OpenAPI、可观测性、admin、
   配对安全、能力声明。
4. **三轨共用同一质量门**：harness、Rust tests、Remote 构建、本地 Release 零警告。

## 三、四主题覆盖（常规线，不含 Remote/API 专轨）

| 主题 | 本版内容 |
|---|---|
| ① 浏览器基础 | 工作区与标签接力（一键保存/恢复/跨设备交接）；新标签页/侧栏入口 |
| ② Agent 基础 | 旁路调用成本归账 + 预算告警；工具面/评估集覆盖新工具族 |
| ③ 融合 | 当前页/选区/书摘一键发到手机；Remote 回执/在 Mac 打开 |
| ④ 替人干活 | 工具箱多步流水线 + 文件夹批处理；视频转码/视频→GIF；Office 批量转换队列 |

## 四、Track A：常规迭代（7 件，必须独立成立）

### A1. 工作区与标签接力

- **现状**：`WorkspaceStore.save` 可存当前窗口标签；workspace 域可同步；无"交接"入口，
  Remote 看不到。
- **增量**：
  - 菜单/标签栏右键「把当前窗口交给其他设备」→ 保存为
    `Handoff · <device> · <time>` 工作区（复用 workspace 域），并提示"已同步/同步未开启"。
  - 另一台 Mac 在 Workspaces 面板看到，可一键替换当前窗口；恢复前弹确认（标签数/来源设备）。
  - Remote 通过 B6 列出工作区，发 `openWorkspace` 让 Mac 恢复。
- **验收**：A 保存 → B 出现 → 恢复标签数/URL 一致；workspace 域关闭时明确提示；
  重名不覆盖（自动加序号）。

### A2. Agent 会话分叉（旁路成本已由既有实现覆盖）

- **现状核实**：`recordBypassUsage` + `CostBreakdown` 已覆盖标题/记忆/critic/crew 的
  token 与成本，成本页有主/旁路/子代理分类，`CostBudgetMonitor` 有日/月预算告警——
  **原规划的"旁路成本归账"已交付，不重复开发**。
- **增量（替代项）**：从任意一条 user 消息分叉出新会话——复制该消息及之前的上下文，
  新会话带 `<Fork of …>` 标记与独立 id；原会话不变；分叉后可继续追问。
  入口：消息右键/长按菜单「Fork from Here」；Remote 在会话页可选（P2）。
- **验收**：从第 2 条 user 消息分叉 → 新会话消息数/内容与原前缀一致、id 不同；
  原会话不受影响；分叉会话可正常继续；标题自动生成。

### A3. Agent 工具面与评估集刷新

- **现状**：toolDefs 已含新工具，但能力页分组/评估集仍以旧工具为主。
- **增量**：
  - Agent 能力页按新族补齐（Toolbox/Media/Books/Sync/Office），工具数从 toolDefs 生成，
    禁止手写清单。
  - `tests/agent-eval.py` 增加 6 条确定性用例：runToolboxTool、analyzeMedia、
    readBook/searchLibrary、syncStatus、saveWebPageToLibrary、addBookNote（假端点轨迹断言）。
  - Remote 能力页自动跟随（已有 capabilities 帧）。
- **验收**：能力页工具数 == toolDefs 数；新增 eval 全过；无工具描述漂移。

### A4. 发送到手机

- **现状**：Remote 只拉 Mac 快照；Mac 无主动发送。
- **增量**：
  - 页面右键/选区/阅读器书摘/工具结果「发送到手机」→ `RemoteControlStore` 推
    `sendToPhone` 帧（title/url/text/kind），落 Remote 收件箱；手机本地通知。
  - Remote 收件箱可"在 Mac 打开/复制/问 Agent"；发送失败（未配对）明确提示。
  - 隐私：只发用户明确选中的内容；不自动发整页/登录态。
- **验收**：Mac 发 URL/选区/书摘 → 手机收件箱出现并可操作；未配对报错；
  内容长度上限（如 8KB）截断提示。

### A5. 工具箱多步流水线 + 文件夹批处理

- **现状**：81 工具单次执行，无链式/批量。
- **增量**：
  - `ToolboxPipelineCore`（纯逻辑，进 harness）：步骤数组（工具 + 参数映射 + 输入引用），
    支持文本/文件产物在步骤间传递；失败停止并保留中间产物。
  - UI：流水线编辑器（添加步骤、上下移、参数表单），保存为"我的流水线"；
    文件夹批处理：对目录内匹配文件逐个跑同一流水线，汇总成功/失败。
  - 首批模板：PDF 拆分→OCR→重命名；图片转换→压缩；字幕转换→重命名。
- **验收**：模板跑 fixture 目录 3 文件，产物/命名正确；中间失败可定位；
  流水线配置可持久化/复用。

### A6. 媒体转码与视频→GIF

- **现状**：剪辑/导出/下载有；无转码/GIF。
- **增量**：
  - 工具箱新增 `mediaConvert`（mp4/webm/mov/m4a 等，按 ffmpeg 能力表）与
    `videoToGIF`（palettegen/paletteuse，帧率/宽度/起止时间）。
  - 使用现有 ffmpeg 探测与长任务模式：立即返回任务、进度、取消、产物落源目录。
  - 无 ffmpeg 时禁用并提示安装（不内置）。
- **验收**：fixture 视频转 mp4/GIF，ffprobe 校验容器/时长/分辨率；取消无残件；
  无 ffmpeg 路径给出明确说明。

### A7. Office 批量转换队列

- **现状**：单文件转换/查看器在；无文件夹队列 UI。
- **增量**：
  - 选择文件夹 → 预览将转换的文件/目标格式 → 队列执行（docx/pdf/xlsx/pptx/图片/文本），
    每项状态/失败原因/重试/打开产物；并发上限。
  - 结果目录默认同级 `Converted/`，重名自动加序号；不覆盖原文件。
- **验收**：fixture 文件夹混合格式 → 全部转换成功/失败项可重试；原文件未改；
  取消后已完成项保留。

## 五、Track B：Remote 2.0（8 件）

### B1. Remote 阅读页

- **现状**：无书架/进度/笔记。
- **增量**：Mac 新帧 `books`（书架摘要、进度、最近高亮、阅读统计）；Remote 新增
  「阅读」页：继续阅读、按书查看章节/进度/高亮；动作 `openBook`（让 Mac 打开到章节）、
  `askAboutBook`（预填 Agent）；不承诺手机端渲染 EPUB。
- **验收**：配对后列表与 Mac 一致；进度/高亮刷新；openBook 在 Mac 落章；
  未同步书显示"本机没有"。

### B2. Remote 工具箱

- **现状**：手机端不可用。
- **增量**：Mac 帧 `toolboxCatalog` + `toolboxRun`；Remote 搜索/分类/收藏、参数表单、
  运行纯文本工具（base64/JSON/时间戳/哈希/单位等），结果复制/分享/问 Agent；
  文件类工具标记"需在 Mac 上运行"。
- **验收**：catalog 计数 == ToolboxCatalog；运行 10 个代表工具结果与 Mac 一致；
  文件类工具给明确提示；长结果分页/截断。

### B3. Remote 通知升级

- **现状**：只有 `turnDone` 本地通知。
- **增量**：Mac 在审批/提问/任务完成/发送到手机时推 `notify` 帧；Remote 建
  通知类别（Allow/Deny/回答/打开），点击深链到对应会话/审批卡；前台去重；
  免打扰/分级沿用 Mac 策略。
- **边界**：仍为本地通知（app 被杀不保证），APNs 不在本版。
- **验收**：审批/提问出现通知并可操作；点通知直达对应界面；同事件不重复。

### B4. Remote 离线缓存与发件箱

- **现状**：断网列表空白，消息丢失。
- **增量**：本地缓存最近会话列表/最新快照/任务/摘录（只读，带时间戳）；输入框在离线时
  进发件箱，恢复连接后按顺序发送并标记；审批/回答离线时禁用并说明。
- **验收**：断网重开 app 仍能看到最近内容；离线发 2 条 → 联网按序到达 Mac；
  缓存有上限/清理入口。

### B5. Remote iPad / 横屏 / 多任务

- **现状**：TARGETED_DEVICE_FAMILY 1,2，但界面单列。
- **增量**：`NavigationSplitView`（会话列表 + 对话/详情）；Agent 首页两栏；
  横屏/分屏下工具栏与输入区适配；键盘快捷键（⌘↩ 发送、Esc 取消）。
- **验收**：iPad 横屏/分屏不挤压输入框；会话切换保留选中；iPhone 布局不回归。

### B6. Remote 工作区 / 标签接力

- **现状**：无。
- **增量**：Mac 帧 `workspaces`（名称/标签数/来源设备/时间）；Remote 列表 +
  「在 Mac 打开」→ `openWorkspace`；与 A1 的 Handoff 工作区联动。
- **验收**：Mac 保存 Handoff → 手机出现 → 打开后 Mac 标签恢复；workspace 同步关闭时提示。

### B7. Remote 文件 / 媒体详情

- **现状**：最近文件只有文件名/类型；下载只有状态。
- **增量**：Mac 下发缩略图/大小/时长/分辨率等元数据；Remote 列表显示缩略图与详情，
  可"在 Mac 打开/复制路径/问 Agent"；不做大文件传输。
- **验收**：图片/视频/PDF 显示缩略图或类型占位；元数据正确；无缩略图不崩。

### B8. Remote 连接与配对体验

- **现状**：配对/重连/延迟分散，断线不明显。
- **增量**：连接状态条（在线/重连中/离线+最后在线）、延迟测量、配对二维码/手动码
  分步引导、设备列表（最后在线/吊销）、一键重新配对；错误文案可操作。
- **验收**：断网/恢复状态实时变化；吊销后手机立即退出；配对失败有明确下一步。

## 六、Track C：API 2.0（9 件）

### C1. Sync 配额与限流

- **现状**：有 500 条/请求、256KB payload 上限；无按用户/域的配额/频率限制。
- **增量**：迁移新增 `sync_usage`（user/domain/rows/bytes/day）或 Redis 计数；
  push/pull 每用户每分钟限流；超限 429/413 带 `Retry-After`；配额可在配置/env 调整；
  管理端可查/重置。
- **验收**：压测单用户高频 push 返回 429；大 payload 413；正常同步不受影响；
  配额计数与 DB 行数对账。

### C2. Remote inbox ack / TTL / 清理 / 指标

- **现状**：`delivered_at` + 24h TTL；无客户端 ack/游标/分页/指标。
- **增量**：`GET /remote/pull?since=` 增量 + `POST /remote/ack`；inbox 清理任务
  （TTL + 每设备上限）；`GET /remote/stats`（pending/delivered/oldest）；
  WS 断线重连补拉。
- **验收**：模拟断线后补拉不丢不重；ack 后不再返回；过期清理；指标正确。

### C3. 账号生命周期

- **现状**：有改密/设备吊销；无删除/导出/全吊销/最后在线。
- **增量**：
  - `DELETE /auth/account`（二次确认 + 密码/验证码）→ 级联删除 users/sync/remote；
  - `POST /auth/devices/revoke-all`；设备 `last_seen_at`；
  - **数据导出走客户端**（E2E 密文服务端不可读），API 只提供删除/吊销；
  - `desire-admin` 可代删/重置。
- **验收**：删除后登录失败、sync/remote 行级联清理；revoke-all 所有 token 失效；
  最后在线显示正确。

### C4. OpenAPI / 文档补齐

- **现状**：部分端点缺注解/schema；文档页不全。
- **增量**：auth/sync/remote/growth 全端点 `#[utoipa::path]` + DTO schema；
  `/openapi.json` 校验；生成 docs 页；错误码表。
- **验收**：OpenAPI 覆盖全部路由（脚本比对）；schema 可生成；CI 校验不漂移。

### C5. DB 索引与查询审计

- **现状**：sync_items/remote_inbox 有基础索引；无系统性查询审计。
- **增量**：迁移补复合索引（sync pull `(user_id,domain,updated_at,id)`、remote inbox
  `(user_id,desktop_device_id,id)`、growth）；对关键查询跑 EXPLAIN；分页/GC 查询
  避免全表扫；连接池配置审查。
- **验收**：EXPLAIN 命中索引；10 万行 fixture 下 pull/GC < 目标阈值；迁移可回放。

### C6. 可观测性

- **现状**：`/health` 浅；无 request id/结构化错误/metrics。
- **增量**：`/health` 细分 DB/Redis/磁盘；请求 ID 注入日志与响应头；统一错误码
  （`code/message/request_id`）；可选 Prometheus `/metrics`（sync/remote/auth 计数/
  延迟/错误）；慢查询日志。
- **验收**：断 DB/Redis 健康检查报错；响应带 request_id；metrics 可见请求量；
  错误码客户端可识别。

### C7. Admin CLI 扩展

- **现状**：`desire-admin` 有迁移/GC 等有限命令。
- **增量**：`user list/info/reset-password/delete`、`device list/revoke`、
  `sync stats/usage/domain-gc`、`remote stats/cleanup`、`quota set/reset`；
  默认 dry-run，危险操作二次确认。
- **验收**：每条命令有测试/演练；误操作可 dry-run；输出 JSON 可脚本化。

### C8. 配对安全与审计

- **现状**：10 分钟 TTL、revoke；无频率限制/审计。
- **增量**：pairing start/claim 按用户/IP 限流；失败审计（不记明文码）；配对列表
  显示设备/时间/最后在线；一键吊销全部；异常配对通知（routine）。
- **验收**：暴力 claim 被限流；审计可查；吊销全部后所有 remote 设备断开。

### C9. 服务端能力声明与灰度

- **现状**：客户端不知道服务端支持哪些同步域，ebooks 未部署只能靠失败。
- **增量**：`GET /meta/capabilities` 返回 `sync_domains`、`remote_frames`、
  `api_version`；客户端据此禁用/提示不支持的域；支持按用户/百分比灰度新域。
- **验收**：旧服务端缺少 ebooks → 客户端不推该域并显示"服务端需更新"；
  新服务端正常；灰度只影响目标用户。

## 七、批次（5 批）

- **批一（常规地基）**：A1 + A4 —— 工作区接力、发送到手机（`8c09af6`，
  A2「会话分叉」移到批五；旁路成本经核实已由既有实现覆盖，不重复开发）。
- **批二（Remote 阅读/工具）**：B1 + B2 + B6 —— 手机看书架/跑工具/开工作区
  （Mac `books/bookOpen/toolboxCatalog/toolboxRun/workspaces/openWorkspace` 帧 +
  Remote 书架/工具箱/工作区三页）。
- **批三（Remote 体验）**：B3 + B4 + B8 + B5 + B7 —— 通知/离线/连接/iPad/文件详情
  （通知类别与 Allow/Deny 动作、离线缓存与发件箱、连接状态条与延迟、iPad 分栏、
  文件缩略图/下载元数据）。
- **批四（API 地基）**：C1 + C2 + C9 + C6 —— 配额/inbox/能力声明/可观测
  （`sync_usage` 0019 + 日配额与 429/Retry-After、`/meta/capabilities` 与客户端域门控、
  remote `ack/stats/cleanup` 与单设备 pending 上限、`/health` 细分 + `/metrics` + `x-request-id`）。
- **批五（常规产出 + API 收口）**：A5（流水线核心 + 编辑器；文件夹批处理留待下版）
  + A6（转码/GIF）+ C3（删号/全设备吊销）+ C5（查询索引 0020）+ C8 部分
  （remote 一键全吊销；配对审计/异常通知留后）+ C4 部分（新端点 OpenAPI 注解）。**A2 已由 v0.8.20 交付**（assistant 气泡菜单 fork），
  不再重复开发；A7（Office 批量队列）与 C7（admin CLI 扩展）体量较大，留下一版。

## 八、技术地图

**常规线**

- `Features/Browsing/WorkspaceHandoff.swift`（或 WorkspaceStore 扩展）+ 菜单/右键；
- `AgentSessionStore.forkConversation(from:)` + 消息右键入口；
- `Features/Remote/SendToPhoneService.swift`（RemoteControlStore 帧）；
- `Features/Tools/ToolboxPipelineCore.swift`（纯逻辑，进 harness）+
  `ToolboxPipelineView.swift`；
- `Features/Tools/MediaTranscodeCore.swift` / `MediaTranscodeViews.swift` +
  ToolboxCatalog 两个新工具；
- `Features/Office/OfficeBatchQueue.swift` + 批量转换视图。

**Remote**

- `RemoteModels.swift`：Book/Reading/Toolbox/Workspace/Notification/Media 模型；
- `RemoteClient.swift`：`handleInner` 新帧 + `requestBooks/runTool/openWorkspace/...`；
- `Views/RemoteBooksView.swift`、`RemoteToolboxView.swift`、`RemoteWorkspacesView.swift`、
  `RemoteConnectionStatusView`；`ChatView` 通知深链；
- `RemoteOfflineStore.swift`（磁盘缓存/发件箱）；
- `MainView` iPad `NavigationSplitView` 自适应；
- Mac `RemoteControlStore`：`books`/`toolboxCatalog`/`toolboxRun`/`workspaces`/
  `openWorkspace`/`sendToPhone`/`notify` 帧。

**API**

- `crates/common/migrations/00xx_sync_usage.sql`、`00xx_remote_ack.sql`、
  `00xx_indexes.sql`、`00xx_device_last_seen.sql`；
- `modules/sync`：配额/限流中间件、usage 计数；
- `modules/remote`：ack/pull since/cleanup/stats；
- `modules/auth`：account delete/revoke-all/last_seen；
- `utils/observability`：request id/错误码/metrics；
- `docs.rs`：OpenAPI 注解；`bin/desire-admin.rs`：新命令；
- `GET /meta/capabilities`。

## 九、验证门

1. **常规 harness**：流水线步骤传递/失败停止、会话分叉前缀、工作区快照、Office 队列状态机。
2. **Remote 构建**：`xcodebuild -project apps/ios/DesireRemote.xcodeproj -scheme DesireRemote
   -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build` 零警告；
   iPad/iPhone 两套布局快照。
3. **Remote E2E**：Mac + iPhone 模拟器/真机，配对 → 阅读页/工具箱/工作区/通知/离线；
   断网恢复；审批通知可操作。
4. **API**：`cargo fmt --check`、`cargo test --workspace`、`cargo clippy`；
   配额 429/413、ack 补拉、账号删除级联、OpenAPI 覆盖、EXPLAIN、health/metrics 脚本。
5. **构建**：macOS Debug + **Release** clean build 零警告；`tests/run.sh` 全绿。
6. **i18n**：macOS + iOS 新键三语零 null（Remote 目前中文硬编码，需单独确认是否做多语）。
7. **发版**：用户说「发」才发；服务端部署另列清单。

## 十、不做（本版明确）

- **APNs 远程推送**：需要 Apple Push 证书/服务端通道；本版只做本地通知 + 前台/后台
  拉取，APNs 另立专项。
- **手机端渲染 EPUB/PDF 正文**：Remote 只做书架/进度/笔记/打开到 Mac，不做手机阅读器。
- **大文件传输/离线下载书籍**：不做；文件仍在 Mac。
- **对话/书籍文件同步**：沿用既定决定（对话不同步；书文件不传）。
- **多档案同步**：仍另开版本。
- **API 微服务化/重写**：只做增量模块与迁移。
- **账号邮箱/短信找回**：无邮件/短信基础设施；本版账号删除/改密/管理员重置，不做找回。
- **A7 Office 文件夹批量队列**：转换引擎已有单文件能力，但队列 UI/并发/重试状态机
  体量较大，留下一版（本版常规线由媒体转码/GIF 与流水线顶上）。
- **C7 admin CLI 扩展**：现有 user/sync gc/stats 命令可用；device/remote/quota 子命令
  留下一版，配额已可通过 env 配置并查 `/sync/usage`。
- **A3 评估集扩充**：工具索引与能力页已从 `toolDefs` 生成；本版未新增 6 条
  `agent-eval.py` 夹具，留到下一版与 Office/流水线工具一起补。

## 十一、风险与取舍

| 风险 | 取舍 |
|---|---|
| 三轨同时铺开 | 常规线独立成批先落；Remote/API 各自可回退；任何一轨滑档不阻塞另两轨 |
| Remote 新帧/E2E | 沿用现有 remote relay 密文帧，API 不解读；新帧版本化（`v` 字段） |
| 通知不可靠 | 本版明确"本地通知 + 拉取兜底"，不承诺杀进程送达；APNs 另立 |
| 离线缓存隐私 | 只缓存用户自己的会话/任务摘要，提供清理；不缓存密钥 |
| 配额误伤 | 默认宽松、可配置；429 带 Retry-After；admin 可查/重置 |
| 账号删除不可逆 | 二次确认 + 密码/验证码；admin dry-run；级联测试 |
| OpenAPI/索引迁移 | 只增不改；迁移可回放；EXPLAIN fixture |
| Remote iPad 适配范围 | 先 `NavigationSplitView` 两栏 + 横屏，不做 Stage Manager 专项 |
| 常规线被平台轨挤占 | 批一先做 A1/A2/A4；每批结束跑四主题清单 |

## 十二、发版口径

CHANGELOG 只用 `scripts/changelog.py add`；WhatsNew 三亮点（工作区/标签接力、Remote
书架/工具箱/工作区、API 2.0 配额与可观测）；产品页同步版本号与 Remote/API 说明；
**发版前 macOS Release clean build 零警告 + Remote 模拟器构建零警告 + Rust 测试**；
服务端迁移/部署另列清单；用户说「发」才发。
