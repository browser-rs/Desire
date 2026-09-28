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
- [x] PERF-1 DiskStore 编码搬进 writer actor
- [x] PERF-2 ConversationStore 启动懒加载——**以实测数据暂缓**：本机 19 个会话共 224KB，启动解码仅数毫秒；全套懒加载要动会话恢复链路，收益/风险比不成立。触发条件写死：会话目录 >5MB 或 >100 文件时再做（元数据索引方案）
- [x] PERF-3 DownloadStore.updateProgress 节流
- [x] PERF-4 设置页 Keychain 预读发布
- [x] PERF-8 jsRequestIDs / jobs 加上限

### 第三批：Agent 会话与远程控制加固（1-2 天）
- [x] CONC-2 clear/loadConversation 取消在跑回合 + 审批超时
- [x] CONC-5 RemoteControlStore connect 句柄 + 严格匹配 + delegate 加锁
- [x] PERF-5 远程快照轻量指纹 + debug 句柄常驻（**poll 退避不做**——1s 收令延迟是产品规格〈无 Redis 时降级轮询 ≤1s 可接受〉，退避会劣化手机端体验）
- [x] PERF-6 WebView runModal → 非阻塞（7 处）

### 第四批：架构重构（随功能开发持续）
- [ ] ARCH-2 executeBody / route 按域拆分
- [ ] ARCH-3 View 层持久化/网络收进 Store（ReaderSettings / testConnection / savePage 优先）
- [ ] ARCH-4 观察链补全（ContentView settings / ResponsiveDesignBar / AddressSuggestionsView）
- [ ] ARCH-5 KeychainService 统一 ×4
- [ ] ARCH-6 Store 里的 Codable Model 搬 Model 文件
- [ ] ARCH-7 jsStringLiteral / 防撞文件名 / ISO8601 formatter / 端口常量统一
- [ ] PERF-9 挂起标签二级 teardown（>N 个时真释放，恢复按快照重建）
- [ ] ARCH-8 ContentView 组合根纯化 + AGENTS 目录树校正

---

# 第二轮深挖（2026-09-28 追加）

> 三个此前未覆盖的角度：**Agent 每回合运行时成本**、**导航路径与标签 UI**、
> **启动序列与服务层（含 Rust）**。方法同前：三路并行审查、代码实证、关键 P0
> 人工复核。**已确认健康、勿过度修复的清单见文末附录 C。**

## ROUND2-P0（新发现的现行 bug / 立竿见影）

### R2-1 WindowRecorder GCD 自死锁——录屏功能整个不可用（已修✅）
- 证据：`Features/Agent/WindowRecorder.swift:77` 把 `output.queue` 同时传给
  `addStreamOutput(sampleHandlerQueue:)`，回调 `didOutputSampleBuffer`（:130）
  又对同一队列 `queue.sync`——对自身串行队列 dispatch_sync = 教科书式死锁：
  **首帧即卡死交付队列**，录屏产出 0 帧坏文件，`stop()` 等 finish 永不返回。
  附带：`finish()` 在 enqueue 完 `markAsFinished` 后立即 resume，主线程的
  finishWriting 与队列残留 append 竞态；macOS 27 SDK 起 `finishWriting()`
  已标 async。
- 修法（已落地）：回调裸执行（已在队列上即正确束缚）；finish 的
  markAsFinished + finishWriting(完成回调) 都进队列，continuation 等真正写完。
- **待用户实测**：Agent 里跑一次 recordStart/stopRecording 验证产物可播。

### R2-2 L2 会话摘要：≥12 条消息后每个回合结束都白打一次模型调用
- 证据：`AgentSessionStore.swift:1686-1693`——extractFacts 有增量门控
  （新增 ≥4 条才跑），但 `MemoryExtractor.summarize` 只有 `messages.count >= 12`
  无任何增量门控，每次把 suffix(40) 转成 ~8000 字符 transcript 发全量请求。
- 影响：memoryLearning 默认开——纯问答闲聊也**每问一答多付一次 8k 字符的
  模型调用**；本地 Ollama 用户每回合结束多等数秒。
- 修法：记 `summarizedCount`，新增 ≥6 条才重新摘要。

### R2-3 `UserScriptLoader.load` 零缓存——每次导航/每个新标签同步读盘
- 证据：`Features/UserScripts/UserScriptLoader.swift:57-68` 每次
  `String(contentsOf:)`。热点：didFinish 的 dark-mode/sponsorblock 注入
  （WebView.swift:893/:903，每次导航读盘）；`BrowserState.init` 的
  `builtinScripts()`（10 个脚本约 90KB，每个新标签全量读盘）。
- 修法：加 `[String: String]` 缓存（打包资源运行期不变），一处改动三路受益。

### R2-4 会话恢复：主线程串行急切物化 N 个 WKWebView
- 证据：`TabManager.swift:590-626` `apply(session:)` 同步 for 循环——每标签
  建 webview（含 90KB 脚本注入）+ NSKeyedUnarchiver 解码 + 立即 `load()` 哄抢。
- 影响：50 标签会话 = 启动瞬间 50 个 WebContent 进程请求，转圈时间随标签数
  线性恶化。
- 修法：只急切恢复选中标签，其余存元数据、首次 activate 时物化
  （复用 `restoreSuspendedState` 快照机制）。

## ROUND2-P1（重复劳动 / 竞态）

### Agent 侧
- **R2-5 回合收尾 3-4 个旁路模型调用串行跑，且与下一回合并发抢同一端点**：
  `AgentSessionStore.swift:853-876`——isProcessing 交还后串行 await
  generateTitle → extractFacts → summarize → critique；此间用户发消息立即开新
  回合，两路同时打同一 provider（本地 Ollama 首 token 延迟暴涨、限流端点 429）。
  且 `memoryProcessedCount = messages.count`（:1694）在 await 之后执行，会把新
  回合已追加的消息标成已处理——那部分内容永远不被抽取。修法：收尾整体挪
  `Task.detached(.utility)` + 快照入参；memoryProcessedCount 按快照条件写。
- **R2-6 `criticPreferences()` 每次自评 new 一个完整 AgentPreferenceStore**：
  `AgentPreferenceStore.swift:294-309`——init 含逐档案 Keychain IPC
  （refreshKeyState）+ 两次磁盘解码；调用点 = 每个多工具回合收尾 + 每次
  reflect。修法：轻量视图复用现有 profiles 或缓存实例。
- **R2-7 桥端点每请求 `ConversationStore()` 全量解码所有会话（主 actor）**：
  AutomationServer.swift:3067（trace）、:2832、:2812、:2788、:3116——修法照
  :2812 已有正确写法（复用 AppState.live 的内存 store），仅找已删除会话才落盘。
- **R2-8 `updateContextFraction` 每帧（12fps）全量 O(总字符) 重扫**：
  `AgentSessionStore.swift:142-152`——memo 键含末条长度，流式期间每拍失配；
  长对话逼近 160k 预算时主线程每秒多 12 次全量字素计数。修法：增量长度表或
  占用显示降到 1Hz。
- **R2-9 P2**：compactWithDigest 每模型调用全量重算（:752）；系统提示词静态段
  每次迭代重建（:781）；inlineCache 500 上限/FIFO 驱逐对长对话不够
  （MarkdownRendererView.swift:181）；历史消息切会话整体重解析（:54，建议
  NSCache 按 text 指纹缓存）；captureEvidence 未缩放截图 ×12 ≈ 峰值 300MB
  （缩到 ≤1200px + 面板不可见跳过）；saveCurrentConversation 重复全量编码
  （按消息数/末条 id 去重）；**saveCurrentConversation 每次重置 createdAt**
  （:673，正确性——历史列表创建时间漂移）。

### 浏览器侧
- **R2-10 didCommit 每次重建 8 站 CSS 注入脚本**：`VideoAdRulesStore.swift:195-217`
  约 44KB 拼接 + 3 次全串扫描，每个标签每次导航都跑。修法：按 generation 缓存
  成品字符串。同批：didFinish 的 pageJSScript/universalJS/fillScript 同款缓存
  （WebView.swift:906-936）；elementBlock 的 xpath 规则逐条 evaluate 合并成单脚本。
- **R2-11 Tab 把 BrowserState 全部 @Published 转发给 UI**：
  `TabManager.swift:118-122` `browser.objectWillChange.sink`——`hoveredLinkURL`
  （每掠过一个链接 2 发）、`selectionAI`（划选连发）、`detectedMedia`（嗅探器
  每资源一发）连坐 SelectedTabContent 全量重算。修法：转发只留低频字段
  （title/isLoading/isPlayingAudio），高频字段走独立通道喂唯一消费者。
  **收益最大也最需要小心（要梳理消费面）。**
- **R2-12 地址栏每击键无防抖全量扫描 + 每击键读剪贴板**：
  `AddressSuggestionsModel.swift:50-169`——历史 500 条每键约 1000 次
  lowercased+contains；`clipboardURL()` 每键一次 pasteboard 跨进程 IPC。
  修法：本地扫描 80-120ms 防抖；大小写预存（照 BookmarkStore 的做法）；剪贴板
  只在聚焦时读一次。**顺带修**：:125-136 剪贴板候选被值拷贝挡在发布之外
  （COW 顺序 bug，功能性）。
- **R2-13 扩展/批注的每导航 IO**：SafariExtensionStore 每次导航重读扩展包
  （:69-81，按 extensionID 缓存）；AnnotationStore 首见 URL 同步读盘在
  didFinish 热路径（AnnotationStore.swift:34，挪后台 + 字典 LRU）。
- **R2-14 缩略图每次切标签即 takeSnapshot + 30s 过期**：
  `ContentView+TabBar.swift:31`、`TabThumbnailStore.swift:84/:46`——连续切标签
  = 连续主线程渲染快照。修法：切标签不拍（悬停才需要）+ 脏标记懒重拍。
- **R2-15 遗留 runModal 2 处**（第一轮 7 处之外）：ContentView.swift:494（⌘O）、
  ContentView+TabBar.swift:114（新建分组）。
- **R2-16（正确性）`ContentBlockerStore.reapplyAll` 的 `removeAllContentRuleLists()`
  会把 FilterListStore 的 EasyList 一并抹掉且不补回**（ContentBlockerStore.swift:98-104）。
- **R2-17（P2）**：TabPillView 帧注册每布局帧 O(N) 写注册表（拖窗口时，
  TabBar.swift:460——register 内加 rect 相等短路即可）；TabOverviewView 悬停
  状态用整本字典 @State（:98，抽每瓦片本地 @State）。

### 启动 / 服务层 / Rust
- **R2-18 SyncStore collect 脏域全量重加密在主 actor，启动后 3s 必来一轮**：
  `SyncStore.swift:830/:1196/:1019` 每次整棵书签树/500 条历史/全部 facts 映射，
  每条 `domainKey` 重新 HKDF 派生（SyncCrypto.swift:170）——2000 条书签 ≈ 每周期
  20-60ms 主线程。修法：domainKey 按 (master, domain) 缓存；collect 主线程快照
  → detached 加密；书签/历史学 settings 的 stamp-diff 只推变化项。
- **R2-19 DownloadStore failed 行永不清场**：`trimCompletedRows`（:164）只统计
  completed——一次离线批量下载留数百条 failed 行永久驻留。修法：trim 统计
  terminal（completed+failed），loadHistory 后同样跑。
- **R2-20 FilterListStore 的 ABP→JSON 转换整表在主 actor**：
  `ABPRuleConverter.swift:29` 最多 60k 行逐行处理 + 数 MB 序列化，编译失败的
  sanitize 二分还会重跑十几遍；EasyList China 默认开。修法：convert 是纯函数，
  detached 转换只回传字符串。
- **R2-21 Rust rate_limit IP 表只进不出**（服务端慢泄漏）：
  `crates/api/src/utils/rate_limit.rs:7-24`——公网扫过无鉴权端点的每个 IP
  永久占一条 map 项。修法：清空 Vec 后 remove 或定期清扫。
- **R2-22 Rust sync pull 复合游标 OR 条件废掉索引序**（每页 filesort 全尾段）：
  `sync_service.rs:45`。修法：改 `updated_at >= ?` 单 range（InnoDB 索引隐含
  PK 后缀天然有序）+ 客户端按 id 去重。
- **R2-23 Rust sync push 逐条 FOR UPDATE**（400 条块 = 800 次语句往返）：
  `sync_service.rs:120-208`。修法：批量 IN 查询 + 批量写。
- **R2-24（P2）**：UpdateChecker 启动即发请求（延 3-5s）；SyncStore 未登录也起
  Timer/NWPathMonitor（挪登录路径）；MCP 解析/鉴权逐 chunk 跳主 actor（照
  AutomationServer 下沉 bridgeQueue）；MCP tools/call 四趟编解码（route 加结构化
  入口）；MCP SSE 每条双趟 JSON（BridgeEventBus 暴露原始对）；WindowRecorder
  分辨率无上限（5K@2x ≈ 59MB/帧，clamp ≤2560）；`AgentPreferenceStore.swift:365`
  ollamaModel 连读两次 UserDefaults。

## 附录 C：第二轮确认健康（勿过度修复）
- `BrowserToolProvider.toolDefs` 已是 static let 缓存；SecretRedactor 有缓存且
  规则预编译；flushTail 不触发会话落盘（无重复写盘风暴）。
- `applyDesktopSafariUA` 只是属性赋值（static let 常量）；TabBar 胶囊渲染粒度
  隔离到位；NewTabPage 全走内存；ContentBlockerStore 的 WKContentRuleList 跨
  webview 复用；分屏 geometry 链全部有等值守卫；MediaExporter cookie 池只在
  导出进行中 30s 拉一次。
- 启动 init 链同步 IO 合计仅 10-50ms——启动大头在 WebKit/SwiftUI 首窗与会话
  恢复（R2-4），不在 store 构造。
- ContentBlockerStore 每次启动重编译是防陈化的**刻意设计**，勿"优化"掉。
- 网络建议（SearchSuggestionService）已有防抖+取消+过期丢弃，乱序覆盖不存在。

---

# 优化批次计划（第二轮追加）

> 第一~四批见上文；以下为第二轮发现排出的新批次。

### 第五批：Agent 回合成本 + 每导航缓存（预计 1 天，P0/P1 密集）
- [ ] R2-2 L2 摘要增量门控（每回合白打一次模型调用）
- [ ] R2-3 UserScriptLoader 缓存（每次导航/建标签读盘）
- [ ] R2-10 视频广告 CSS/JS 按 generation 缓存 + xpath 合并单次注入
- [ ] R2-8 updateContextFraction 降到 1Hz 或增量表
- [ ] R2-5 回合收尾挪 detached + memoryProcessedCount 快照写
- [ ] R2-7 桥端点复用内存 ConversationStore
- [ ] R2-19 DownloadStore failed 行纳入 trim
- [ ] R2-15 遗留 runModal ×2
- [ ] R2-12 地址栏防抖 + 剪贴板 COW bug（功能性，顺带）

### 第六批：启动与服务层（预计 1 天）
- [ ] R2-4 会话恢复懒物化（只急切选中标签）
- [ ] R2-18 SyncStore domainKey 缓存 + collect 挪后台
- [ ] R2-20 ABP 转换挪 detached
- [ ] R2-6 criticPreferences 轻量化
- [ ] R2-13 扩展脚本/批注读盘缓存化
- [ ] R2-24 UpdateChecker 延迟 + SyncStore 未登录不起监视

### 第七批：细水长流（随功能顺带）
- [ ] R2-11 Tab 转发粒度收敛（收益最大、需小心梳理消费面）
- [ ] R2-14 缩略图切标签不拍 + 懒重拍
- [ ] R2-9 Markdown 解析结果跨会话缓存 / inlineCache LRU 化 / evidence 缩放
- [ ] R2-16 reapplyAll 不再误删 FilterListStore 规则（正确性）
- [ ] R2-17 帧注册幂等短路 / 悬停本地 @State
- [ ] R2-21/22/23 Rust 三项（rate_limit 清扫 / pull 单 range / push 批量）
- [ ] R2-24 MCP 结构化入口 / SSE 单趟编码 / WindowRecorder 分辨率 clamp
- [ ] saveCurrentConversation createdAt 漂移（正确性）
