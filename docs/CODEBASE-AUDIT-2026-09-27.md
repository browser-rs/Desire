# Desire 代码库全面体检报告（2026-09-27）

> 范围：Swift 应用（`Desire/`，约 6.6 万行）+ Rust 后端（`crates/`，快速扫描）。
> 方法：四路并行审查（架构合规 / 性能内存 / 代码健康 / 并发安全），全部结论经代码实证
> （文件:行），关键 P0 结论做了人工复核。
> 配套优化按批次推进，见文末「优化批次计划」，完成一项勾一项。

---

## 总体结论

架构地基健康：三层分离大体在执行、定时器/缓存纪律良好（有界缓存清单见附录 A）、
观察者配对完整、Rust 侧干净（请求路径零 unwrap）。主要问题集中在四处：

1. **4 个现行 bug**（两处是复制漂移导致的旧副本仍在生产路径）
2. **4 个随数据量线性恶化的主线程热点**（周期性掉帧与"莫名卡顿"的直接来源）
3. **5 个并发加固点**（两个是已知僵尸态事故的结构性根因）
4. **一批架构债**（722 行死代码、1473 行巨型函数、View 层违规聚集）

---

## 一、现行 Bug（P0，修了立竿见影）

### BUG-1 页内查找的匹配计数用的是没修的旧副本
- 证据：`Features/Browsing/BrowsingActions.swift:312` 用 `walk.nodeValue`
  （`WebView.swift:346-348` 的注释明确记录过这写法"计数恒为 0"并已修），
  修复版在 `WebView.swift:358`（`walk.currentNode.nodeValue`）。
- 根因：两份手抄 JS 各自 `evaluateJavaScript`，修复只落在了一份上。
- 影响：用户点查找时匹配计数错误。
- 修法：BrowsingActions 改调共享的 `findCountJS`，删除手抄副本。

### BUG-2 插件 document_idle 注入必然 SyntaxError
- 证据：`Features/UserScripts/PluginStore.swift:100-108`——插件 JS 做 `\'` 转义后
  塞进 `setTimeout(function() { … })` 的**函数体**；函数体里 `\'` 是非法 token，
  任何含单引号的插件代码直接 SyntaxError 失效。同文件 `document_end` 分支（:109）
  是裸注入，行为正确——两个 runAt 档位行为不一致。
- 修法：删掉 idle 分支的整套转义。

### BUG-3 挂起巡检不豁免正在播放音频的标签
- 证据：`Features/Tabs/TabManager.swift:224-233` 常规 30 分钟挂起分支漏判
  `isPlayingAudio`；内存压力分支（:240-241）反而记得豁免。
- 影响：听歌 30 分钟被静默切歌。
- 修法：常规挂起分支补同一豁免。

### BUG-4 工具失败约定一处违约
- 证据：`Features/Agent/BrowserToolProvider+Execution.swift:1558`
  `return "Missing code"` 裸返回；机械核验按 `Error: ` 前缀统计（:1565）认不出它。
- 影响：`executeJS` 缺参的失败在"全部失败"判据里漏计。
- 修法：改走 `Self.fail(...)`。

### BUG-5 下载完成后的 moveItem 用 try? 静默吞错
- 证据：`Features/Downloads/DownloadStore.swift:538、:682`——移动失败时 UI 显示
  完成、目标位置没有文件，且零日志。同型：`Features/Password/PasswordPanel.swift:99`
  CSV 导出失败后照样报成功。
- 修法：改 do/catch + `Log.downloads.error`，失败时状态回落。

---

## 二、性能优化（按收益排序）

### PERF-1（P0）每 15 秒在主线程全量编码会话 JSON
- 证据：`Storage/DiskStore.swift:41-43` 的 `JSONEncoder().encode(value)` 在
  **调用方线程**执行（头注释自认）；`Features/Tabs/TabManager.swift:840` 的 15s
  定时器 → `persistWindow`（:725-734）组装含每个标签 `interactionState` 二进制
  Data 的 SavedSession → 每 15s 多 MB 级编码。指纹缓存（:556-568）只免了
  NSKeyedArchiver 重归档，没免 JSON 重编码。
- 影响：30+ 标签的重会话 = 周期性掉帧（"莫名卡一下"）。
- 修法：`DiskStore.save` 把编码搬进 writer actor（一处改动，全仓热路径受益）。

### PERF-2（P0）启动时主线程同步读盘+解码全部 Agent 会话
- 证据：`Features/Agent/ConversationStore.swift:16` init 里 `loadAll()` → :23-48
  同步遍历目录逐个解码；启动必经（AppState → AgentState → ConversationStore），
  会话数无上限。
- 影响：启动时间随会话历史线性增长，重度用户数百 ms～秒级。
- 修法：启动只读轻元数据（id/title/时间），消息体首次打开时懒加载。
- 连带：`Remote/RemoteControlStore.swift:867` statsFrame 每次 new 一个
  ConversationStore 触发全量读盘。

### PERF-3（P0）下载进度 @Published 零节流
- 证据：`Features/Browsing/WebView.swift:1488-1496`（WKDownload KVO）与 :673
  （URLSession 路径）每个回调 hop 主线程 → `DownloadStore.swift:177-188`
  `updateProgress` 直接写 `@Published`，无节流。
- 影响：高速下载每秒数百次 objectWillChange；WebView representable 自己就观察
  downloadStore（WebView.swift:296），每个 webview 每 tick 重走 updateNSView。
  与 Agent 流式输出叠加正是"流式卡死"复合场景。
- 修法：非 published 草稿 + 100-200ms 节拍器统一发布（照 AgentSessionStore
  flushTail 已验证的 80ms 模式）。

### PERF-4（P0）设置页 body 内同步读 Keychain
- 证据：`Features/Agent/AgentSettingsSection.swift:586` `serviceRow` 内
  `store.loadAPIKey(profileID:)`（body 求值路径；Xcode Performance Diagnostics
  点名过）。同文件其余 6 处在按钮路径，属 P2。
- 修法：`AgentPreferenceStore` 预读并发布每档案 `hasKey` 字典，视图读发布值。

### PERF-5（P1）远程控制每秒快照全量编码+加密
- 证据：`Features/Remote/RemoteControlStore.swift:184`（1s Timer）→ :687-732
  `pushSnapshot` 每秒把 `messages.suffix(100)` 全量 JSON 编码（每条截 2000 字符）
  算指纹，busy 时 elapsed 每秒必变 → 每秒 AES-GCM 加密 + base64 + 上传；
  :963-982 空闲也每秒一发 REST poll；:48-59 每帧同步开关 /tmp 文件句柄。
- 修法：轻量指纹（消息数/尾长/busy/elapsed）先判断再全量；debug 文件改常驻
  句柄或降采样；poll 空闲退避。

### PERF-6（P1）WebView 里 7 处 runModal 冻结全 app
- 证据：`Features/Browsing/WebView.swift:820-829`（证书）、:1375（摄像头/麦克风）、
  :1395（定位）、:1415（文件上传 NSOpenPanel）、:1424/1433/1445（JS
  alert/confirm/prompt）。同文件 :674-676、:979-980 注释自认"runModal 冻结整个
  app / 阻塞导航代理"。
- 影响：网页一个 JS alert 就把主线程（含 Agent 循环、远程控制、同步）整体冻结。
- 修法：换非阻塞 sheet/通知条（项目里有现成范式）。

### PERF-7（P1）Agent 流式 flush 每次 2 次全量发布
- 证据：`Features/Agent/AgentSessionStore.swift:914-928` `flushTail` 写
  `messages[idx]`（整个数组写回）+ `streamingVersion += 1`，80ms 一拍。
- 现状：已有意识优化过（:880-884 注释），单独可接受；重点是别再叠加 PERF-3/5。

### PERF-8（P1）零散无界增长
- `DevTools/DevToolsStore.swift:250` `jsRequestIDs` 字典无淘汰（每条 fetch/XHR
  写入，仅手动清除时清）。
- `Downloads/MediaExportStore.swift:33,74` `jobs` 只增不裁（对照 DownloadStore
  有 100 条上限）。
- `PageWatch/PageWatchStore.swift:20,160` 离屏 webview 一旦用过永不释放。

### PERF-9（P1）挂起标签不释放 WKWebView
- 证据：`Features/Tabs/TabManager.swift:219-251` 挂起 = `loadHTMLString("")`，
  WKWebView 实例、userContentController（12+ handler + 全套 userScript）、
  会话快照 Data 全部常驻；只有 close 走 tearDown（:429）。
- 影响：内存下限 = 每标签 webview 骨架；挂起省页面内存，不省进程数。
- 修法（中期）：超阈值（如 >12 个挂起标签）二级挂起 = 真正 teardown，恢复时
  按快照重建（`suspendedInteractionState` 已有）。

### PERF-10（P2）DevTools console 每条消息 O(n) 拷贝
- `DevTools/DevToolsStore.swift:143-153`——`var newMessages = consoleMessages`
  后 append 触发 COW 全量拷贝（1000 条含字符串）。

---

## 三、并发加固

### CONC-1（P0）两座桥的 listener 挂在主队列
- 证据：`App/AutomationServer.swift:106、:165`；`App/MCPService.swift:68、:75`。
- 风险：主 actor 僵尸态（历史上两次）时 automation 桥、MCP、SSE 全部超时——
  这正是"窗口照常渲染但桥全灭"现象的结构性根因。
- 修法：listener/connection 挪专用串行队列，回调 `Task { @MainActor }` 跳回。

### CONC-2（P0）`AgentSessionStore.clear()/loadConversation()` 不取消在跑回合
- 证据：`Features/Agent/AgentSessionStore.swift:555-591`（clear 置 isProcessing=false
  但不 cancel loopTask、不 resume 挂起的审批）、:603-625（loadConversation 同样
  无防护），且 loadConversation 被远程指令直达（RemoteControlStore.swift:1151）。
- 风险：回合进行中新建对话/手机切会话 → 旧循环挂在审批续体上泄漏，两条循环
  交错写同一 messages，工具调用/结果配对破坏。
- 修法：clear/loadConversation 补 `loopTask?.cancel()` + 挂起审批 resume +
  `pendingApproval` UI 状态清理；审批补超时（对照 UserPromptCenter 的 10 分钟）。

### CONC-3（P1）`HeadlessMediaResolver` 续体泄漏（本周新代码）
- 证据：`Features/Downloads/HeadlessMediaResolver.swift:48`（续体存属性）、
  :137-142（teardown 摘 delegate，挂起的 load 续体永不 resume）、:84-87
  （二次 load 覆盖未 resume 的旧续体）。
- 修法：load 入口先 resume 旧续体再置新；teardown 先 resume(throwing) 再摘。

### CONC-4（P1）KVC 私有键残留
- 证据：`Features/Browsing/BrowserWKWebView.swift:164`
  `value(forKey: "_inspector")`——与 2026-09-20 崩溃（NSUnknownKeyException →
  主 actor 僵尸）同型的最后一次残留。
- 修法：改 `webView.inspectable` 或包 NSException 捕获。

### CONC-5（P1）RemoteControlStore 连接竞态
- `RemoteControlStore.swift:235-270` connect 的内层 Task 不存句柄，await 期间可被
  teardownLink 拆掉 → 快速开关时双活连接、旧 URLSession 泄漏。
- :302-308、:351-359 迟到的 ping 失败/收帧退出可拆掉当前健康连接（误重连抖动）。
- :10-25 `RemoteWSDelegate` 标 @unchecked Sendable 但闭包属性无锁（真数据竞争）。
- 修法：connect Task 存属性、teardown 时 cancel；回调按 `webSocketTask === dead`
  严格匹配；delegate 闭包加锁或改 MainActor 队列转发。

### CONC-6（P2）零散
- 桥请求期间切换活动窗口管理器无并发防护（AutomationServer.swift:211-223，
  defer 恢复过期值）。
- 桥 continuation 依赖 WKWebView 存活到回调（:1508 等 7 处），请求中关标签即悬挂。
- `AutomationServer.swift:617` /spawn-test detached 无超时；FaviconStore inFlight
  从不 cancel；PreviewServer.swift:17-19 nonisolated(unsafe) 形态脆弱。

---

## 四、架构债

### ARCH-1 死代码：Features/Extensions/ 集群（722 行 / 3 文件）
- `WebExtensionRegistry.swift`（581 行）+ `WebExtension.swift`（93）+
  `WebExtensionMatcher.swift`（48）——全仓仅自引用（AGENTS 已认定未接线），
  且 Registry 里还留着会注入 WKUserContentController 的活代码路径，误接线风险
  大于归档价值。活着的插件系统是 `Features/UserScripts/` 另一套。
- **修法：整体删除**（git 历史可找回）。注意 `SafariExtension*` 4 个文件是接线的，勿动。

### ARCH-2 超长函数/文件
| 位置 | 行数 | 内容 |
|---|---|---|
| BrowserToolProvider+Execution.swift:125 `executeBody` | **1473** | 121 个 case 的工具分发 |
| App/AutomationServer.swift:522 `route` | 845 | 端点路由 |
| AgentSessionStore.swift:855 `runTurn` | 322 | 回合循环+压缩+标题+记忆 |
| CommandDispatcher.swift:77 `handle` | 276 | 命令分发 |
| AutomationServer.swift（文件） | 3964 | 168 个 static func |
| DevToolsPanel.swift（文件） | 2722 | 5 个面板塞一个文件 |
- 修法：executeBody/route 按域机械切 extension 文件（case 名即边界）。

### ARCH-3 View 层违规聚集（规范：持久化/网络归 Store）
- `Features/Reader/ReaderView.swift:5-30` ReaderSettings 整层 UserDefaults 持久化。
- `Features/Agent/AgentSettingsSection.swift:1016-1084` 两份 testConnection 手写
  URLRequest（与 OllamaProvider/AgentService/ModelListFetcher 重复）。
- `Views/ContentView.swift:599-640` savePage 在组合根里做文件名清洗+写盘+落库。
- `Features/Screenshot/ScreenshotOverlayView.swift:741-771`、
  `Features/Agent/AgentPanel.swift:632-662`、`Features/DevTools/DevToolsPanel.swift:578-591`、
  `Features/UserScripts/PluginPanel.swift:198-201`——View 里文件 IO。
- `Views/OnboardingView.swift:73`、`Features/Settings/GeneralSettingsSection.swift:16-20`
  View 里直接写 UserDefaults。

### ARCH-4 观察链缺口（已知翻车模式的潜伏面）
- `Views/ContentView.swift:83` `var settings: Settings { appState.settings }` 是普通
  计算属性，body 读 `appearanceTheme`/`accentColor`；AppState 无任何 objectWillChange
  转发（全仓 sink 搜索 0 处）。改主题/强调色的刷新目前靠"恰好有别的重绘"。
- 同型：`Features/ResponsiveDesign/ResponsiveDesignBar.swift:8`（未观察 store 的
  @Published）、`Features/AddressBar/AddressSuggestionsView.swift:11`。
- 修法：视图里读到的每个 store 都是该视图的 @ObservedObject。

### ARCH-5 Keychain 三件套重复实现 ×4
- `Password/PasswordStore.swift:205`、`Agent/AgentPreferenceStore.swift:440`、
  `Sync/SyncStore.swift:1315`、`Remote/RemoteControlStore.swift:1248`——各自实现
  read/write/delete + query，non-interactive LAContext 处理四份各不相同，
  RemoteControlStore 的 service 名还是硬编码 `"me.siwi.Desire"`。
- 修法：抽共享 `KeychainService`（interactive 参数化）。

### ARCH-6 Store 里的纯 Codable Model（规范明禁）
- 顶层：ProfileStore.swift:9（DesireProfile）、InterceptStore.swift:13、
  ApprovalPolicyStore.swift:7/21、AgentPreferenceStore.swift:595。
- 嵌套：AnnotationStore.swift:18、DownloadStore.swift:702（HistoryItem 40 行）、
  BatchMediaExportStore.swift:354/366、RemoteControlStore.swift:589-685（约 100 行）、
  FilterListStore.swift:29、VideoAdRulesStore.swift:31/38、DevToolsStore.swift:419-476。

### ARCH-7 复制粘贴漂移面（BUG-1/2 的土壤）
- 防撞文件名三份拷贝（DownloadStore.swift:132、:759、ScreenshotOverlayView.swift:759）。
- JS 转义五处各写各的（WebView.swift:350、BrowsingActions.swift:304/368、
  PluginStore.swift:82/101），均不处理 `\r`/`\u2028`——应统一 `jsStringLiteral()`。
- Cookie 映射双实现（CookieStore.swift:40、DevToolsStore.swift:634）。
- ISO8601DateFormatter 现场 new 10 次（AutomationServer 内）；日期模式 4 处重复。
- 两套 NWConnection 手写 HTTP 响应（AutomationServer.swift:198/219/233、
  MCPService.swift:148-151）。
- 魔法数：自动化端口 8799 硬编码 4 处；超时 10/15/20/30/60/120s 六种散布 13 处。

### ARCH-8 结构错位（P2）
- ContentView 仍混有 ~100 行会话恢复编排（:273-369）、撕标签 Timer、跨窗口标签
  转移、find 驱动——非纯组合根。
- Toolbar.swift:74 Composite 直接 @ObservedObject 持有 PluginStore（双标：同文件
  :43 注释引用规范说明别处为什么不观察）。
- AGENTS.md 目录树与实际漂移（TabManager/Toolbar 在独立目录、BrowserWKWebView 已拆出）。
- `App/` 里堆了 MCPService/MetricsManager/UpdateChecker 等基础设施。
- Rust 侧（健康）：仅 remote_controller.rs 三处 query 参数提取可提 helper。

---

## 附录 A：体检中确认健康的部分（勿过度修复）

- 定时器全景无泄漏（weak self / invalidate 配对齐全）；SSE 心跳断开即清。
- 有界缓存规范：Favicon NSCache 256+TTL、缩略图 64、证据截图 LRU 12、
  History 500、Memory facts 200、DevTools 1000/500/200、Markdown inlineCache 500。
- WebView message handler 的 add/remove 配对完整（remove-before-add 幂等 +
  dismantle 兜底）；ForEach 全部 Identifiable/显式 id。
- SecItem 调用全部在 Store 层；工具参数传值正确走 callAsyncJavaScript。
- Rust：请求路径零 unwrap，错误映射统一 AppError。
- 启动路径（除 PERF-2 外）干净：重 Keychain store 均 lazy、同步读非交互。

## 附录 B：量化指标（2026-09-27）

- 最大文件 Top5：AutomationServer 3964 / DevToolsPanel 2722 / AgentSessionStore 1910 /
  BrowserToolProvider+Execution 1633 / WebView 1559。
- 目录行数 Top5：Features/Agent 16854 / Views 4845 / Features/DevTools 5148 /
  App 7050 / Features/Settings 3110。
- `try?` 369 处 vs `Log.` 83 处（吞错/记日志比例失衡，关键路径见 BUG-5）。
- 全仓 `objectWillChange.sink` 转发 0 处。

---

## 优化批次计划

> 原则：每批独立可发布、先 bug 后性能再重构、每批结束跑 build+单测。
> 完成一项在 `[x]` 勾掉。

### 第一批：现行 bug + 死代码 + 桥加固（半天，全是小改动大收益）
- [x] BUG-1 查找计数：BrowsingActions 改调共享 findCountJS
- [x] BUG-2 插件 document_idle 转义删除
- [x] BUG-3 挂起豁免音频标签
- [x] BUG-4 executeJS "Missing code" → Self.fail
- [x] BUG-5 moveItem/CSV 导出 do/catch + 日志
- [x] ARCH-1 删除 Features/Extensions/ 死集群 3 文件
- [x] CONC-1 两座桥摘主队列
- [x] CONC-3 HeadlessMediaResolver 续体防护
- [x] CONC-4 KVC "_inspector" 残留移除

### 第二批：主线程热点（1 天）
- [ ] PERF-1 DiskStore 编码搬进 writer actor
- [ ] PERF-2 ConversationStore 启动懒加载（元数据先行）
- [ ] PERF-3 DownloadStore.updateProgress 节流
- [ ] PERF-4 设置页 Keychain 预读发布
- [ ] PERF-8 jsRequestIDs / jobs 加上限

### 第三批：Agent 会话与远程控制加固（1-2 天）
- [ ] CONC-2 clear/loadConversation 取消在跑回合 + 审批超时
- [ ] CONC-5 RemoteControlStore connect 句柄 + 严格匹配 + delegate 加锁
- [ ] PERF-5 远程快照轻量指纹 + debug 句柄常驻 + poll 退避
- [ ] PERF-6 WebView runModal → 非阻塞（7 处）

### 第四批：架构重构（随功能开发持续）
- [ ] ARCH-2 executeBody / route 按域拆分
- [ ] ARCH-3 View 层持久化/网络收进 Store（ReaderSettings / testConnection / savePage 优先）
- [ ] ARCH-4 观察链补全（ContentView settings / ResponsiveDesignBar / AddressSuggestionsView）
- [ ] ARCH-5 KeychainService 统一 ×4
- [ ] ARCH-6 Store 里的 Codable Model 搬 Model 文件
- [ ] ARCH-7 jsStringLiteral / 防撞文件名 / ISO8601 formatter / 端口常量统一
- [ ] PERF-9 挂起标签二级 teardown（>N 个时真释放，恢复按快照重建）
- [ ] ARCH-8 ContentView 组合根纯化 + AGENTS 目录树校正
