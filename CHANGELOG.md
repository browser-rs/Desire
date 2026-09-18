# 更新日志 (Changelog)

本文件记录 Desire 的所有显著变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；
版本号采用 0.x 阶段的宽松语义（次版本 = 功能主题，补丁版本 = 修复与小 UX）。

## [Unreleased]

### 0.2.1 — UX 快赢批次（进行中）

### Added

- **常驻书签栏**：工具栏下方 26pt 高横条——叶子直达导航、文件夹下拉、
  与书签面板/星标同源（BookmarkStore）。默认显示，可在设置关闭。
- **剪贴板 URL 直达**：地址栏聚焦且系统剪贴板为 URL 时，建议首行
  出现"打开剪贴板链接"（scheme/www./IP 三种模式自动检测）。

## [v0.2.0] - 2026-09-19

### 计划中（见 [ROADMAP](docs/ROADMAP.md) 0.2 弧线）

- 0.2.1 Passkey、0.2.2 Profiles、0.2.3 WebExtension 开放、0.2.4 自动更新…

### 计划中（见 [ROADMAP](ROADMAP.md)）

- 0.1.6+ Desire as MCP Server、多窗口 Agent 联动、无人值守作业…

## [Unreleased]

### 0.2.1 — UX 快赢批次（进行中）

### Added

- **常驻书签栏**：工具栏下方 26pt 高横条——叶子直达导航、文件夹下拉、
  与书签面板/星标同源（BookmarkStore）。默认显示，可在设置关闭。
- **剪贴板 URL 直达**：地址栏聚焦且系统剪贴板为 URL 时，建议首行
  出现"打开剪贴板链接"（scheme/www./IP 三种模式自动检测）。

## [v0.2.0] - 2026-09-19

### Added

- **SponsorBlock 类别开关**（设置 ▸ Media）：赞助商&自我推广 /
  片头片尾预告 / 灌水三组独立开关，注入脚本按启用类别拉取分段。
- **更新检查**：启动时静默查询 GitHub Releases 最新 tag，有新版本时
  弹系统通知（点击打开发布页）；仓库转公开后自动生效，当前私有仓库
  下为无害 no-op。

### Fixed

- 全屏 shim 移除 px 几何（黑边根因），单动画全屏 + 视口 CSS。

## [v0.2.0] - 2026-09-19

> 0.2 弧线首版：**外部 AI 完全体**。

### Added

- **MCP Server 鉴权**：`--mcp-token <token>`（Bearer，initialize 在内的
  全部请求 401 门禁；默认 localhost 裸奔不变）。五场景实测全过。
- **桥 /events 心跳**：15 秒 keep-alive 注释帧——死连接以发送错误浮出
  并自动清理，不再滞留 sinks。
- **官方驱动示例**：`examples/desire-driver.py`（纯 stdlib，事件驱动
  全流程，实测跑通）、`examples/desire-mcp-driver.ts`（零依赖 MCP
  客户端：initialize → tools/list → tools/call）。
- README 新增 AI/Automation 章节；路线图标记 0.1.x 全部完成。

### Fixed

- MCPService 鉴权门禁首轮未接线（补丁静默未命中第四次）——E2E 直接
  抓出并修复；脚本化编辑全面改用 assert。

## [v0.1.16] - 2026-09-18

### Added

- **⌘K 命令面板**：30 个浏览器命令的模糊搜索统一入口（前缀优先排序、
  ↑↓/回车/Esc 键盘导航、hover 选中）——BrowserCommand 枚举即清单，
  CommandBus 即执行层。`commandPalette` 映射进快捷键设置（默认 ⌘K）。
- **全页截图上 MCP**：`fullPageScreenshot` 工具——整页滚动内容
  PDF → ~/desire_fullpage.pdf（无保存面板的驱动路径）。

## [v0.1.15] - 2026-09-18

### Added

- **记忆作用域**：MemoryFact 新增 scope（global / 域名）——按域事实仅在
  Agent 当前页面匹配该域时注入提示词（带 [scope] 标签），全局事实照常。
  addFact 支持 scope 参数（旧记录默认 global，自动兼容）。
- **记忆管理上桥**：GET /memory（profile/facts/summaries 快照，不含密码类
  数据）、facts add/update/delete——外部 AI 可审阅并修正自己的记忆。
- **技能管理上桥**：GET /skills、/skills/reload、/skills/delete、
  /skills/import（从 raw markdown URL 导入，name 可选覆盖）。

### Verified

- E2E：全局 + 按域事实入库、技能从 URL 导入（出现在列表）→ 删除（消失）。

## [v0.1.14] - 2026-09-18

### Added

- **拦截规则录制 `POST /intercept/record`**：把网络日志里观察到的请求
  一键转 block 规则（pattern 过滤 + 去重 + 上限；本机基础设施
  8877/8799 自动排除）。MCP 工具 `recordInterceptRules`——
  "首载后切断第三方依赖"的工作流成型。
- **真实网络捕获（修网络面板摆设问题）**：导航响应现记录进 DevTools
  网络面板（此前面板里只有 Preview 占位数据，无任何生产写入）。
  v1 覆盖主框架响应（WebKit 不暴露子资源请求 API，如实记录）。

### Changed

- **响应式/节流的诚实结论**：SDK 探测确认 WebKit 无真网络节流 API
  （仅 idle CPU 调度）——"真节流"不可实现，响应式面板维持无假 UI；
  DPR/请求级拦截同样无公开 API。路线图 0.1.14 的这三项标记为
  「WebKit 平台限制，关闭」。

## [v0.1.13] - 2026-09-18

### Added

- **网络拦截 v1**：`InterceptStore`——block/redirect 规则经
  WKContentRuleList 编译并分发到全部 webview（立即生效、持久化）。
  设计边界诚实声明：WebKit 声明式规则无法返回 canned body，
  mock 响应留待 Service Worker 方案。
- 桥 `/intercept`（list/add/remove/clear）；**MCP 工具 27 → 30**：
  addInterceptRule / listInterceptRules / clearInterceptRules——
  Agent 测试台核心原语（阻断 tracker/mock 依赖/重定向端点）。

### Verified

- E2E：测试页引用 /tracker.js → 无规则时命中 1 次 → 添加 block 规则
  → 重载后命中 0 次（WebKit 拦截真实生效）；MCP 三工具闭环、
  clear 全清。

## [v0.1.12] - 2026-09-18

### Added

- **媒体流水线技能包**：内置 `media-pipeline` 伞形技能（提取 → 确认 →
  下载 → 转码/合成 → 报告，含失败自愈：换源/ffmpeg 直连/提示安装），
  按文件幂等 seed，老安装自动获得。
- **Agent 工具 `downloadFile`**：URL 直下到 Downloads（DownloadStore 托管，
  可暂停/恢复，触发桥事件）——补齐数据管道的通用下载原语
  （media 专用的 downloadMedia/HLS 已有）。
- **媒体能力上 MCP（24 → 27 工具）**：listPageVideos（GET /media，嗅探+
  DOM 扫描结果）、downloadFile、downloadMedia（POST /media/download，
  后台执行不阻塞调用方，完成入 Downloads）。

### Verified

- E2E：MCP downloadFile 真实下载 300KB 文件入下载列表；downloadMedia
  后台启动返回 ok；listPageVideos 空页 shape 正确；自举客户端可见全部
  27 工具；media-pipeline 技能 seed 成功。

## [v0.1.11] - 2026-09-18

### Added

- **结构化提取 `POST /extract`**：页面表格 → `{headers, rows}` JSON 或 CSV
  （引号/逗号/换行正确转义）；列表 → `{text, href}`。选择器模式可锁定
  单张表格或指定条目元素；行数上限 1000/表（truncated 标记）、20 表。
- **MCP 工具 21 → 24**：extractTables / extractTablesCSV / extractList
  ——外部 AI 一句话抽数据；工具映射新增 `const` 支持（固定参数注入）。
- 与 0.1.9 作业/0.1.10 监控组合即采集流水线（watch 变更 → 定时抽取 →
  write 文件）。

### Verified

- E2E：真实 HTML 表格（含含逗号单元格 CSV 转义）、指定列表选择器、
  越界选择器安全返回、MCP extractTablesCSV 全链路。

## [v0.1.10] - 2026-09-18

### Added

- **页面监控（确定性 watcher，不烧模型）**：PageWatch/PageWatchStore——
  隐藏 webview 定期加载 URL、提取正文或指定 CSS 选择器的文本、空白归一化
  后与上次快照 diff；变更 → 系统通知 + `pageWatchChanged` SSE 事件 +
  changeCount 累加。首次检查建立基线。监控配置持久化。
- 桥 `/watches`（list/add/remove/enable/check）：check 强制立即检查并
  返回 changed 布尔。
- **MCP 工具 17 → 21**：watchPage / listWatches / checkWatch / removeWatch
  ——外部 AI 一句话即可布置页面变化监控（价格/库存/公告）。

### Verified

- E2E：基线检查 changed=false → 内容变化后 changed=true →
  pageWatchChanged 事件载荷完整（name/url/changeCount/diff）；
  MCP checkWatch/removeWatch 闭环。

## [v0.1.9] - 2026-09-18

### Added

- **定时任务运行历史**：每次触发记录 RunRecord（firedAt/finishedAt/status/
  success/error/attempts），持久化最近 100 条；桥 `GET /agent/runs?name=` 查询。
- **turn 结果回传**：AgentSessionStore 结束每个 turn 时把结果（成功/失败+
  错误文本）交给注册的 handler——调度器的运行记录从 delivered 实时更新为
  success/failed。
- **失败处理**：turn 失败 → 系统通知 + `scheduledTaskFailed` SSE 事件 +
  30 秒后自动重试一次（同一条 RunRecord 累积 attempts）；成功发
  `scheduledTaskSucceeded`。
- 桥 `POST /agent/tasks/enable`：暂停/恢复任务（缺省为切换）。

### Verified

- E2E：fire → delivered → （真实模型完成 turn）→ success 记录 + SSE
  scheduledTaskSucceeded；两次触发产生两条独立记录。

## [v0.1.8] - 2026-09-18

### Added

- **多窗口 Agent 联动**（挂账转正）：AgentScheduler 新增会话注册表
  （弱引用、窗口关闭自动剪枝）；桥 `GET /agent/windows` 列出全部窗口
  会话（id/标签/busy/审批挂起/消息数/是否 newest）。
- **按窗路由**：`/agent/send`、`/agent/messages`、`/approvals(/resolve)`
  均接受 `window` 参数（UUID），缺省沿用 newest 语义。

### Verified

- 双窗口：按窗投递互不串台（W1/W2 各自收到自己的标记、零泄漏）；
  无参投递落到 newest 窗口；并行 busy 状态按窗可见。

## [v0.1.7] - 2026-09-18

### Added

- **MCP 工具集 9 → 17**：startDownload / listDownloads / pauseDownload /
  resumeDownload（存储级下载，支持断点语义）、listHistory / listBookmarks /
  addBookmark（检索与收藏）、resolveBeforeUnload（表单保护卡住导航时
  MCP 驱动可自行解除）。
- **GET /mcp 事件推送（SSE）**：BridgeEventBus 的 7 类事件以
  `desire/event` JSON-RPC 通知推送给订阅的客户端，15 秒 keep-alive——
  MCP 驱动者无需轮询即可感知页面就绪/下载完成/审批挂起。
- DELETE /mcp 会话清理语义。
- 桥 `POST /downloads/start`：URL 直下（MCP/桥共用）。

### Fixed

- MCPService GET 分支此前仍指向 v1 的 405 占位（补丁静默未命中），
  事件推送实际上线不了——本轮 E2E 发现并修复。

## [v0.1.6] - 2026-09-18

### Added

- **Desire 作为 MCP Server**（`--mcp-server` 启动参数，`http://127.0.0.1:8798/mcp`，
  Streamable HTTP / JSON-RPC）——外部 AI 客户端（Claude Desktop、任何 MCP 客户端）
  可直连驱动浏览器。路线图 0.2 主题提前落地。
- **v1 工具集 9 个**：navigate / getPageText / getPageInfo / listTabs / newTab /
  closeTab / switchTab / findInPage / executeJs（描述为 LLM 编写，schema 完整）。
- 工具实现经由 `callEndpoint` 复用自动化桥管线——MCP 与桥双界面同源不漂移。
- 桥新增 `/mcp/add`、`/mcp/reconnect`（客户端配置自动化）。
- 每连接按 Content-Length 累积读取：URLSession 将 headers 与 body 分段发送，
  单次 receive 导致所有真实 MCP 客户端 400（curl 单包写入掩盖了该缺陷）。

### Verified

- **自举**：Desire 自家 MCPClient 反向连接自家 MCPServer——
  `self | ready · 9 tools`（握手/initialize/通知/tools/list 全链路）。
- curl 模拟客户端：initialize（含 Mcp-Session-Id 下发）→ notifications/initialized
  （202）→ tools/list → 4 类 tools/call（navigate/getPageInfo/getPageText/
  findInPage）+ 未知工具 -32602。

## [v0.1.5] - 2026-09-18

### Added

- **桥自描述 `GET /`**：机器可读端点目录（68 个端点的方法/参数/示例）+
  8 类 SSE 事件清单 + 鉴权说明——任何 AI 或脚本无需外部文档即可学会驱动。
- **可选 token 鉴权**：`--automation-token <token>` 启动后，所有请求
  （含 `/events`）必须携带 `Authorization: Bearer <token>`，否则 401。
  默认（无该参数）行为不变：localhost 裸奔。
- **docs/BRIDGE.md**：场景化 curl 速查（浏览/标签/下载/事件/Agent/
  表单保护/数据存储/UI 验证）。

## [v0.1.4] - 2026-09-18

### Added

- **桥事件流 `GET /events`（SSE）**：`text/event-stream` 长连接，外部驱动
  从轮询升级为事件响应。事件：`pageReady`（url/title）、
  `downloadStarted` / `downloadCompleted` / `downloadFailed`、
  `approvalPending`（工具/风险级）、`tabOpened` / `tabClosed`、
  `beforeunloadPending`。
- `BridgeEventBus`：主线程发布/订阅总线，多客户端扇出；无订阅者时
  publish 为 no-op（埋点零成本）。
- 客户端断开自动清理（receive 错误/连接状态双路径）。

### Verified

- 验收流程端到端：`navigate → pageReady → download → downloadStarted →
  downloadCompleted`（curl SSE 客户端实测，含完整 4MB 下载生命周期）。

## [v0.1.3] - 2026-09-18

### Added

- **CI 启动冒烟**：Release 产物以 `--automation` 启动，桥 `/state` 必须在
  30 秒内应答，否则该次构建失败——"能编译不能启动"从此挡在合并前。
- **CI x86_64 编译检查**：非阻塞 job 交叉编译 Intel 切片，跟踪健康度
  （发布仍为 arm64）。
- **冷启动打点**：`StartupMetric`（os_signpost interval + fault/info 日志）
  测量 app init → 首窗可交互，预算 400ms，超预算告警。本地实测 232ms。
- **诊断数据导出**：设置 → System → Diagnostics 新增「导出…」，
  将 MetricKit 落盘的 crash/hang/metrics 打包为 zip 到下载文件夹并在
  访达中显示。

### Fixed

- 启动打点初版报告 0ms：Swift 静态属性懒初始化导致 `launchedAt` 在首次
  读取时才创建；改为 app init 首行显式锚定。

## [v0.1.2] - 2026-09-18

### Added

- **存储页面（⌘S / File ▸ 存储页面…）**：当前页存为 webarchive 到下载文件夹，
  并在下载列表记录为完成行；快捷键设置里的 `savePage` 映射由此接线；
  桥新增 `savePage` 命令。
- **NoticeBar 提示条组件**：工具栏下方全宽非阻塞条（图标 + 标题 + 最多三个操作），
  取代抢焦点的 sheet——Agent 代操作时不再被打断。
- 密码保存提示的「**永不为此站点保存**」：按域持久化（UserDefaults）。
- 下载完成通知 **2 秒窗口聚合**：批量完成只弹一条（"已下载完成 N 个文件"）。
- **Dock 角标**实时显示活动下载数，空闲时清除。
- 操作 toast 通用化（图标 + 文案，1.8 秒自动消失），书签/存页共用。
- 桥：`savePage` 命令。

### Changed

- **密码保存提示**：sheet → NoticeBar（保存 / 暂不 / 永不为此站点）；
  桥 `/passwords/resolve` 代答链路不变。
- **beforeunload 离开确认**：sheet → 同一 NoticeBar 组件；
  桥 `/beforeunload` 流程不变。

### Fixed

- 本 SDK 的 `createWebArchiveData` 仅有 completion-handler 变体（无 async 形式），
  实现按此适配。

## [v0.1.1] - 2026-09-18

### Fixed

- **BUG-K 优雅退出挂起（挂账最久的已知问题）**：SIGTERM 默认处置是硬终止，
  WebKit 分线程拆除时竞态导致偶发卡在 exit。AppDelegate 安装 DispatchSource
  信号处理器，SIGTERM/SIGINT 转发 `NSApp.terminate(nil)`——与 Cmd+Q 同路径
  （applicationShouldTerminate → 会话 flush → 干净退出）。
  **100 轮 SIGTERM 压测：0 挂起**。

### Added

- **ShutdownDiagnostics**：终止时同步输出存活清单（URLSession 任务、活动/暂停
  下载、Agent 循环状态），fault 级日志；若复发可对照排查。
- 桥 `/agent/tasks`（list / create / remove / **fire**）：`fireNow` 立即投递
  定时任务提示词，无需等待调度周期。
- 桥 `/approvals/simulate`：在活会话上挂起一个**真 continuation** 的审批
  （不跑模型），外部驱动可确定性验证审批管线。

### Verified

- 审批全链路：simulate → pending → allow_once / deny → continuation 复归。
- 定时任务全链路：create → fire → 会话收到 `[定时任务]` 消息 → lastResult 更新 → remove。

## [v0.1.0] - 2026-09-18

首个 tag 发布（自 v0.1.0 起建立 CI 与发版流水线）。

### Added

- **中键操作**：中键关标签（TabMiddleClickMonitor：NSEvent 监视器 + 胶囊帧注册表，
  按 tab.id 实时解析关闭）；中键开链接（middle-click.js auxclick → 新标签）。
- **beforeunload 表单保护**：本版 WebKit 对无手势卸载不派发事件，故在
  decidePolicyFor 合成派发页面的监听器，拒绝离开时弹确认。
- **快捷键设置页接线**：共享 KeyboardShortcutStore + AppCommands 观察式菜单；
  补 newWindow/bookmarkPage/findNext/findPrevious/toggleAgentPanel 映射与
  forceReload/showDownloads 命令。改键持久化，重启生效（macOS 26 不支持
  实时重绑，已验证并记录）。
- 下载面板重设计：卡片行、文件类型色块、hover 渐显操作、修复头部裁切与
  类型筛选挤压；优先级移入右键菜单；新增复制链接。
- 桥端点大批量扩展：`/downloads/pause|resume`、`/execute`、`/panel`、
  `/panel/snapshot`（进程内渲染，捕获遮罩下可用）、`/beforeunload(/resolve)`、
  `/reader`、`/shortcuts(/update)`、`/site-settings(/darkmode,/zoom)`、
  `/quickdial(/add,/delete)`、`/elements(/add,/remove)`、`/command`（驱动全部
  BrowserCommand）、`/find`、`/tabs/pin`、`/reading-list*`、`/search-history*`、
  `/tabgroups*`、`/passwords*`、`/containers/remove`、`/bookmarks/add|remove`、
  `/suggest`；`/page/url` 增加 zoom、`/state` 增加 isActive/hasKeyWindow。

### Fixed

- **下载暂停→秒恢复竞态**：恢复请求先挂起，checkpoint 落地后触发；服务器
  不支持 Range 时删残件、复用原文件名重启。
- **无痕下载写入共享历史**：DownloadItem.isPrivate 隔离，面板带徽标。
- **暂停行跨重启变假活行**：HistoryItem.isPaused 持久化 + 暂停/恢复即时落盘。
- **URLSession 下载进度恒 0**：改 delegate 会话实时回传字节。
- **脚本消息 handler 重复注册崩溃**：observe/stopObserving 名单收敛 +
  先移除再注册（重复 add 在布局期抛 NSException）。
- **查找匹配计数恒 0**：TreeWalker.nextNode() 只返回布尔，文本在
  currentNode.nodeValue——旧代码必然抛异常被吞。
- **会话恢复断链**：macOS 不写 SwiftUI 窗口值，还原侧永不触发；首窗口
  现采纳退出索引中最近会话并重绑身份（尊重 startupBehavior 设置）。
- **阅读模式永远转圈**：先切视图再提取导致页面被挂起；改为提取完成后再切换。
- **密码保存阻塞式 runModal**：冻结主线程（含桥）；改 PendingPasswordSave
  非阻塞决策模型。
- **新书签永不进地址栏建议**：BookmarkStore.add 漏调 rebuildURLIndex。
- **地址栏 IP 字面量被强升 https**：IPv4 与 localhost 同样保持 http。
- **响应式模式 MQ bar 数组越界崩溃**（承接此前修复）。

### Security

- 沙盒移除后的 Keychain 域切换（容器 → login keychain，API key 需重存一次，
  预期行为）。
