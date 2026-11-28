# v0.8.84 规划稿（2026-11-28）—— 轻装上阵：WebView 提速 · 资源管家 · 可量的快

> **主题叙事**：0.8.83 把日常顺手度与可验证性收口之后，下一块硬骨头是**性能债**——
> 而且是量得出来的债：41 个恢复标签会把启动审计顶到 791ms（预算 700ms）；每次主框架
> 导航都为"离开确认"付一次 JS 往返，而它只对注册了 `beforeunload` 的页面有意义；
> 自家的性能探针在每个 iframe 里每 5 秒遍历一次全 DOM，还把大页面守护的数据覆盖掉；
> 挂起快照以解码位图常驻内存；插件后台宿主永不休眠；Agent 看不见也放不了内存。
> 本版不铺新的大面，而是把浏览器**在量得出的地方变轻**：启动与恢复减负、导航路径
> 去浪费、内存有进有出、后台会退避；再把这些能力交给用户（性能面板/设置）与 Agent
> （资源工具/Doctor 体检）；最后用一条确定性的性能探针把收益钉住。
>
> **规模**：20 件（Track A 四主题 15 + Track B 收口贯穿 5），五批实施。
>
> **规划前核实（HEAD `60143489`，v0.8.83 已发布）**——以下**已交付，不进本版**：
> 标签挂起体系（60s sweep + 闲置 30 分钟 + 大页面守护 + 内存压力水位，
> `TabManager.swift:434-513`）、两级深度挂起（快照 LRU 12 / 骨架重建 6，`:548-550`）、
> 恢复快照叠加层、手动"卸载标签"、标签资源中心（v0.8.1）、概览整组挂起（v0.8.19）、
> 挂起滚动恢复（v0.8.49）；**懒加载**——会话恢复只对选中标签发请求，其余 `loadsPage:
> false`（`TabManager.swift:225-233`，v0.4.3 R2-4）；启动埋点（`StartupMetric` 400ms /
> `LaunchAudit` 700ms / `RuntimeHealthMonitor` / 协作池水位 / `/diag/startup|health` /
> `/page/timing` / Memory Snapshot / CI 启动预算）；缓存上限（favicon NSCache 256、
> 缩略图 64/30s、TranslationCache LRU 20M 字符、ArchiveGC、StorageRetention）；
> 渲染侧（`WebViewContainer`、低频字段转发 R2-11、概览 LazyVGrid 只挂可见行）；
> DiskStore IO 移出协作池（v0.8.61）。
>
> **口径纪律**：性能数字 **Debug 与 Release 分开报**（Debug 只看趋势，阈值按 Release
> 定）；内存只报主进程 `phys_footprint` 与进程数，**不承诺 per-tab 字节数**（WebKit
> 无公开 API，ROADMAP 已记档）；每项优化先量后做，量不出收益的撤项记档。

## 存量收口（审计实锤，随批 1–5 修）

| # | 缺口 | 证据 | 影响 |
|---|------|------|------|
| S1 | **恢复期每个标签仍建完整 WebView 骨架**：`loadsPage:false` 只省了 `load()`，`BrowserState`（配置+WKWebView+全部用户脚本+录制器）照建 | `TabManager.swift:208` 无条件构造；`:223` 装录制器。实测 0 标签审计 680ms，41 标签 **791ms 超预算**，多出的 `didFinishLaunching` 255ms | 启动变慢，标签越多越差 |
| S2 | **导航守卫每次主框架导航一次 JS 往返**（合成 `beforeunload` 探针） | `WebView.swift:2645-2668` 调用，`:2982-2997` 实现，探针 `:3020-3040` | 忙页面上导航起点被页面主线程拖延 |
| S3 | **`page-perf` 在所有帧运行，原生侧不辨帧**：注释写"主框架"，注册没设 `mainFrameOnly`；handler 直接覆盖 `lastDomNodeCount` | `page-perf.js:37`（5s 全 DOM 遍历+IPC）；`UserScriptLoader.swift:43`；`WebView.swift:1675-1679` | 每 iframe 的周期 CPU；小 iframe 把大页面守护的数据重置 |
| S4 | **挂起快照以解码位图常驻**（≤1200px 宽的 `NSImage`），只在标签被选中恢复时才清 | `TabManager.swift:71,95`；仅 `SelectedTabContent.swift:629` 置 nil | 每个挂起标签 ~MB 级内存 |
| S5 | **内存压力只清页面不清华**：`.warning/.critical` 只挂起后台标签，不释放快照/缩略图、不收紧深度挂起上限 | `TabManager.swift:404-420,497-512` | 压力下可回收的内存没回收 |
| S6 | **插件后台宿主永不休眠**：每个带 backgroundCode 的启用插件一个 headless WKWebView，只在禁用/卸载时拆；PageWatch 离屏 webview 从不释放 | `PluginBackgroundRuntime.swift:68-106`；`PageWatchStore.swift:31-32,47` | 空闲 WebContent 进程常驻 |
| S7 | **`didFinish` 多次 JS 往返**：13 处调用点（深色/字体/订阅发现/自动填充/元素屏蔽/混合内容/标注…），部分未按原生已知状态门控 | `WebView.swift:2270-2491` | 每次页面完成的固定开销 |
| S8 | **自家定时器后台不退避**：缩略图 15s 轮捕所有存活标签（`takeSnapshot` 跨进程 200ms+）、PageWatch 20s、`page-perf` 5s；应用不在前台照跑 | `TabThumbnailStore.swift:154-177`；`PageWatchStore.swift:47`；无 `isActive` 门控 | 后台能耗 |
| S9 | **无"性能"设置分区**；深度挂起上限是硬编码常量 | `SettingsView.swift:26` 分区枚举；`TabManager.swift:548-550` | 用户看不到也调不了 |
| S10 | **Agent 看不见也放不了内存**：没有任何 Agent 工具暴露标签资源/挂起能力，只有 UI 的标签资源中心 | `Features/Agent` 无相关 toolDef；`TabResourceCenterSheet.swift` 仅界面 | 智能体无法替用户收拾标签 |
| S11 | **Doctor 没有 WebView 性能检查项**（现有=主线程/协作池/Schema/TTFT/同步/技能…） | `AgentDoctor.swift` 检查清单 | 性能退化没有体检入口 |
| S12 | **`conversationUsage` 每次读取都全量重算**，而视图一次渲染读 4 次以上；流式期每 80ms 重绘 | `AgentUsage.swift:33-55`；`AgentHeaderView.swift:348-369`；`AgentPanel.swift:35,229`；Remote 指纹每帧 `formattedUSD`（`RemoteControlStore.swift:1806,1875`） | 长会话流式期的持续 O(n) |
| S13 | **MetricKit 挂起诊断只落盘不消费** | `MetricsManager.swift:157-171` | 用户感知的卡顿没有上屏 |
| S14 | **多窗恢复紧循环**：排定窗口一次性全开，没有错峰 | `SessionRestore.swift:209-211` | 多窗启动首窗被拖慢 |
| S15 | **强杀后后台首启无窗仍可复现**：`pkill -9` → `open -g` 启动 → 桥活、`firstWindowMs=nil`、tabs=0，须再 quit+open 才有窗（2026-11-28 本会话两次）；AGENTS 记"仍待修"、ROADMAP 记"缓解已交付" | `LaunchWindowHealer.swift` 自愈未生效 | 崩溃后首启体验；测试启动器被迫绕行 |
| S16 | **启动阶段同名不可归因**：`ContentView.init` 四段合计 503ms（实测 17 步 680ms 中） | `LaunchAudit` 标记重名 | 无法定位启动大头 |
| S17 | **DevTools 控制台每条消息 O(n) 拷贝**（PERF-10 仍在） | `DevToolsStore.swift:152-157`；审计 `CODEBASE-AUDIT-2026-09-27.md:131` | 高频日志页的持续拷贝 |

## Track A — 四主题（15 件）

### ① 浏览器基础（旗舰：轻装上路）

**1. 恢复标签懒建 WebView（启动减负旗舰）**
- **现状依据**：S1；`CHANGELOG` v0.4.3 明确把"整只 webview 懒建"留给后续批，至今未落。
- **增量**：分两步，**先拆段计时再动手**。A）`Tab.init` 拆出可归因分段（BrowserState /
  用户脚本 / 录制器 / KVO），`/diag/startup` 增 `restoreTabs{count,ms}`，用 0/40/100 标签
  三档取数；B）`loadsPage:false` 的恢复标签不再构造 WKWebView——`BrowserState.webView`
  改为首访懒建（任何提前访问即兜底创建，并计数上报"意外建"），用户脚本/内容拦截/录制器
  推迟到首次唤醒时武装；档案/无痕/容器的 data store 仍在懒建时正确传入。
- **验收**：41 标签恢复 `didFinishLaunching` ≤ 80ms、审计不超 700ms、首窗 ≤ 400ms；
  E2E：40 标签恢复 → 选中第 40 个正确加载并恢复滚动/会话状态，无痕/容器/固定属性保留；
  "意外建"计数为 0。

**2. 多窗恢复错峰**
- **现状依据**：S14。
- **增量**：首窗可交互后再开其余排定窗口（间隔 300ms），`pendingRestore` 与 10s 自愈
  探针沿用；上限 5 / 7 天不变。
- **验收**：3 窗×10 标签：首窗 `firstWindowMs` 不劣于单窗基线；10s 内三窗齐；自愈路径仍有效。

**3. 导航守卫零 JS 化**
- **现状依据**：S2。
- **增量**：文档起始主框架脚本用 `Proxy` 包 `window.addEventListener`、用
  `defineProperty` 接管 `onbeforeunload` 赋值（两者 `toString` 仍是 native，避免被站点
  探测），页面注册监听器时发**一条**消息置原生标志 `hasUnloadListener`；无标志 → 导航决策
  直接放行，有标志 → 照旧跑合成探针（语义不变：注册过就仍探）；主框架提交时复位。
- **验收**：忙页面 fixture（主线程每 400ms 阻塞 300ms）点击链接的"决策延迟"从 ≥100ms
  降到 <5ms；有监听器的表单页仍弹离开确认（既有 `/beforeunload` E2E 不回归）；
  无监听器页面的 JS 往返数为 0。

**4. `page-perf` 只在主框架跑 + 大页面守护数据修正**
- **现状依据**：S3。
- **增量**：注册改 `mainFrameOnly: true`；原生 handler `guard message.frameInfo.isMainFrame`；
  页面隐藏时停报、可见时再报。
- **验收**：20 个 iframe 的 fixture 上报帧数 21→1；主框架 30k 节点 + 小 iframe 的页面
  `lastDomNodeCount` 保持 30000（此前被覆盖）；大页面守护 E2E 通过。

**5. 页面完成回调按需化**
- **现状依据**：S7。
- **增量**：逐项列出 `didFinish` 的 13 处调用，按原生已知状态加前置门（站点无字体/
  深色覆盖、无自动填充、无屏蔽规则、无 DPP 时直接跳过），可合并的合并为一次；
  `/page/timing` 增 `jsRoundTrips`。
- **验收**：简单页面往返数 ≤ 4；深色/站点字体/自动填充/元素屏蔽各一条回归不破。

**6. 挂起快照瘦身 + 内存压力清道**
- **现状依据**：S4、S5。
- **增量**：快照改存压缩数据（JPEG ~150KB 或落盘进缩略图库），只在恢复叠加层显示前
  解码；`.warning` 时释放全部常驻快照位图、清缩略图 NSCache、临时把 `deepRebuildCap`
  降为 0；`.critical` 立即深度挂起；新增桥 `POST /diag/memory-pressure {"level":…}`
  （仅自动化实例）模拟三档。
- **验收**：挂 30 个标签后常驻快照位图 ≈ 0；模拟 warning 后 `phys_footprint` 下降
  （Memory Snapshot 前后对比），选中/固定/播放标签不受影响；恢复叠加层无闪白。

**7. 后台降本：定时器退避 + DevTools 写入零拷贝**
- **现状依据**：S8、S17。
- **增量**：应用不在前台（`NSApp.isActive=false`）时暂停缩略图轮捕、PageWatch 轮询与
  挂起 sweep 的快照重拍，回前台立即补一轮；控制台缓冲改为原地追加、超限按块裁剪
  （每 200 条裁一次），不再每条 COW 全量拷贝。
- **验收**：后台 60s 内 `takeSnapshot` 次数为 0（桥计数 `/diag/perf/counters`），回前台
  1s 内恢复，hover 预览仍命中缓存；1000 条上限下每条日志不再触发数组拷贝（harness 计数）。

**8. 插件后台宿主闲置休眠 + PageWatch 离屏释放**
- **现状依据**：S6。
- **增量**：后台宿主零监听器/零端口持续 10 分钟即拆除（记录 `lastActivity`），
  右键菜单点击或消息派发前按需重建；PageWatch 无监视项时释放离屏 webview。
- **验收**：3 个无监听器 fixture 插件（测试用 `--idle-seconds` 缩短）后宿主数为 0，
  有监听器的保留；拆除后右键菜单事件仍送达；WebContent 子进程计数下降。

**9. 性能面板 + 设置分区 + 卡顿上屏**
- **现状依据**：S9、S13。
- **增量**：`desire://performance` 内置页：标签（活跃/挂起/加载中/未建）、DOM 节点
  总量与 Top、long task、启动审计分段条、缓存体量、后台宿主数、每次加载 JS 往返、
  MetricKit 挂起（时长/顶部帧）；按钮 = 释放内存、清快照、重测启动。设置新增"性能"
  分区：内存管家预算、后台节能开关、资源退避开关、诊断入口（通用页既有的"闲置挂起/
  大页面守护"保留，搜索同时命中）。菜单加"性能面板…"与"释放内存"。
- **验收**：宽/窄快照；设置搜索命中；`desire://performance` 深链 E2E；面板数字与桥同源。

### ② Agent 基础

**10. 用量增量缓存**
- **现状依据**：S12。
- **增量**：token/旁路/模型字段的写入点收口到一个 revision，`AgentUsage` 随写入增量
  维护，`conversationUsage` 变 O(1)；成本/预算/Remote 指纹全部走同一份缓存。
- **验收**：harness 基准（2000 条消息 × 10000 次读取 < 50ms，与重算结果逐字段相等）；
  流式期主线程探针无回归。

**11. 评估扩面 E41–E44**
- **增量**：E41 资源工具契约、E42 `page-perf` 主框架口径、E43 导航守卫零 JS（无监听器
  零往返 + 有监听器仍拦）、E44 内存压力模拟后的挂起/释放；全部固定假端点/桥级确定性，
  `--only` 可单跑。
- **验收**：全过；CI 只跑纯逻辑与桥契约。

### ③ 融合（浏览器 × Agent）

**12. Agent 资源工具**
- **现状依据**：S10。
- **增量**：`getTabResources`（标签 × DOM 节点/long task/挂起/加载/音频，按重量排序）
  与 `releaseMemory`（挂起后台标签 + 清快照/缩略图，返回前后计数）。`releaseMemory` 有
  副作用：走审批；**遵守既有豁免**——绝不挂起选中/分栏/固定/播放/租约中的标签。
- **验收**：E2E + E41；工具定义自动进提示词索引（不手写）。

**13. Doctor 性能体检**
- **现状依据**：S11。
- **增量**：新增稳定 id 的检查项——启动预算超支、常驻快照积压、后台宿主数、`page-perf`
  帧范围配置、缓存体量、超长会话；安全修复动作 = 释放内存/清快照/打开性能面板。
- **验收**：注入式构造超支状态 → 检查失败 → 修复后通过；Doctor 快照。

### ④ 替人干活

**14. 内存管家（按重量提前挂起）**
- **现状依据**：挂起策略是均一的时间阈值（30 分钟）+ 单标签 >25k 节点，没有"总量预算"；
  多个中等页面加起来再重也不会提前挂起（`TabManager.swift:450-490`）。
- **增量**：纯逻辑 `SuspendPolicy`（Foundation-only）：后台标签 DOM 总量超过预算
  （默认 60k 节点，可设）时，按"重量 × 最久未看"依次挂起最重的后台标签直到回到预算内；
  豁免规则与现有 sweep 完全一致；设置页可调预算/关闭。
- **验收**：harness（预算/豁免/LRU 平局）；E2E：6 个重页面 fixture → 一轮 sweep 后
  总量回到预算内、选中与固定标签不动、恢复正确（测试用 `suspendAfterMinutes=0.01`
  把阈值缩到 36s，测完删除）。

**15. 资源紧张时后台作业退避**
- **现状依据**：热状态全仓从未读取（`thermalState` 零引用）；低电量只管下载
  （`DownloadStore.swift:101-128`）；缩略图/PageWatch/批量导出并发都不感知资源。
- **增量**：纯逻辑 `ResourceGovernor`——输入内存压力/热状态/低电量，输出后台作业档位
  （normal/reduced/paused）；消费者 = 批量下载并发（减半/暂停入队）、缩略图与 PageWatch
  轮询、批量导出并发。**定时 Agent 任务不受影响**（那是用户交代的事）。Jobs 面板显示
  "资源紧张：后台作业已降速"。
- **验收**：harness 状态机；桥 `/diag/resource-governor` 模拟；E2E：模拟 serious 热状态
  → 并发减半且提示出现，清除后恢复。

## Track B — 收口与贯穿（5 件）

**16. 性能回归探针 `tests/perf-probe.py`**
- **增量**：封闭实例上的确定性测量——冷启动（0/40 标签）首窗与审计、忙页面导航决策
  延迟、iframe fixture 上报帧数、压力模拟后的释放、后台定时器暂停；阈值存
  `tests/perf-baseline.json`（Release 口径），发版前本地跑；CI 不跑（应用无法激活）。
- **验收**：一条命令出表；阈值可复现；发版 checklist 增这一项。

**17. 强杀后后台首启无窗根治**
- **现状依据**：S15。
- **增量**：5× 复现 → 定位 `open -g` 后台启动下自愈为何不补窗 → 修；启动器不再需要
  "失败先 quit 再 open"的绕行说明。
- **验收**：5 次 `SIGKILL` → `open -g` 启动 → 10s 内 tabs≥1，无需人工重开。

**18. 启动分段归因 + 首窗前工作后移**
- **现状依据**：S16。
- **增量**：把四个同名 `ContentView.init` 拆成可归因的阶段名；首窗不需要的构造后移到
  首窗之后（只动无界面依赖的初始化）。
- **验收**：Release 构建空会话审计合计 ≤ 450ms（Debug 基线 545–680ms）；无重名阶段。

**19. 发布与文档纪律**
- **增量**：AGENTS 补四条（`page-perf` 帧范围、导航守卫标志语义、新增设置分区必须走
  `SettingsContainer`、性能"先量后做"口径）；CHANGELOG/What's New/产品页版本同步；
  Release clean 零警告；发版前 perf-probe。
- **验收**：`changelog.py verify` + Release 0 警告。

**20. 版本收口**
- **增量**：v0.8.83 发版结果与发版后补丁（存储页容器）回填；本规划稿与索引同步。
- **验收**：索引状态与 CHANGELOG 一致。

## 批次

1. **启动与恢复**：1 懒建 → 2 多窗错峰 → 18 启动归因 → 17 强杀无窗。
   **实施记录（2026-11-28，6093ab99/ecec997a/5d5fe17f/8279b553）**：1A 归因
   （`restoreTabs` 度量 + `ContentView.init#N` 窗口序号）→ 1B 懒建（41 标签
   apply 251→72ms、审计 800→651ms 回预算内、意外建 0——顺带修掉标签胶囊
   渲染读 `webView.url` 的击穿点，收口为 `displayURLString`）→ 2 错峰 300ms →
   17 无窗根治（空索引+`open -g` 下 SwiftUI 整段不建主窗 3/3 复现，自愈
   reopen 前置到 2.5s，首窗 21s→3s）。第 18 件的"首窗前工作后移"待
   Release 基线（第 16 件 perf-probe）后再评估。
2. **导航与页面**：3 守卫零 JS → 4 page-perf → 5 didFinish 按需 → 7 后台降本。
   **实施记录（2026-11-28，d248cb4a/10096e53/47460ce4）**：3 零 JS 守卫（眼线脚本
   documentStart 装自有 accessor 影子 + addEventListener Proxy；**WebKit 实测坑**：
   原生 onbeforeunload accessor 是 window 自有属性而非 Window.prototype；`<body
   onbeforeunload>` 的解析转赋值不经过 JS setter——靠 documentEnd 二次注入读原生值
   兜底；创建期弱代理接收避免 controller→handler→state 释放环；四注册形态 fixture
   全验）→ 4 page-perf 主框架（iframe 覆盖实测修复）→ 7 DevTools 零拷贝（PERF-10）
   + 缩略图后台暂停。第 5 件（didFinish 按需）留下一轮——13 处调用点需逐项审计。
3. **内存与后台**：6 快照瘦身/压力 → 8 插件宿主 → 14 内存管家 → 15 资源退避。
   **实施记录（2026-11-28）**：6 落地——快照改 JPEG（叠加层解码显示）、warning
   清道（快照+缩略图+收紧 rebuildCap）、`POST /diag/memory-pressure` 模拟、
   缩略图 store 加进程级 purge（每窗实例弱登记）；14 落地——`SuspendPolicy`
   纯逻辑 + sweep 内总量预算分支（豁免集同既有）+ 设置页预算行（默认 60k），
   harness 4096/0，E2E：20k 后台标签在预算 5000 下一个 sweep 内挂起、选中不动。
   8 与 15 已落地（76687e96/f1e10a67）：8 = 零监听器/零端口 10 分钟拆除 +
  contextMenus/storage/事件路径按需重建（Chrome service worker 同语义，rebuild
  不重放 onInstalled）；15 = `ResourceGovernor` 纯逻辑（harness 4 项）+ 下载并发
  闸接入 + `/diag/resource-governor`（模拟链验证 critical → paused）。批 3 全部完成。
4. **可见与融合**：9 性能面板/设置 → 10 用量缓存 → 12 Agent 资源工具 → 13 Doctor → 11 评估。
5. **收口**：16 perf-probe → 19 文档/发版 → 20 版本收口。

## 不做 / 暂缓（已核实，别再当缺口）

- **URLCache 调优**：WKWebView 的页面资源不经过 `NSURLCache`（走 WebKit 网络进程自有
  缓存），配 URLCache 只影响 App 自己的请求，对页面加载无效。
- **自定义 `WKProcessPool` / 进程数控制**：全仓用隐式共享默认池；拆池只增加进程数与内存，
  没有性能收益（按档案拆池是隔离需求，另议）。
- **预连接 / DNS 预取 / 预热**：WebKit 无公开 preconnect API，只能靠 hover 注入
  `<link rel=preconnect>`；收益依赖真实握手，本机 localhost 测不出——没有确定性验收
  环境（本地 TLS + 延迟代理）前不做，列为 spike。
- **每标签内存指示器**：WebKit 无公开 per-tab 内存 API（已记档）；本版只做主进程与进程数。
- **DevTools 后台录制门控**：v0.7.5 刻意让后台标签持续记录（修过"转后台断流"），不回退；
  只修写入拷贝（第 7 件）。
- **缩略图前台轮捕退避（PERF-5）**：产品取舍是 hover 秒开，保留；只做后台暂停。
- **PERF-2 ConversationStore 懒加载**（未达 5MB/100 文件阈值）、火焰图、FPS 采样器
  （采样器自身开销）、网络节流 / pixelRatio（既有决策）。
- **标签切换路径与 message handler 拆装**：2026-10-09 实测 live↔live 切换全链 <7ms
  （handler 拆装 / `.id` 重建 / reparent 嫌疑全排除），勿再动刀——handler 重注册出过
  在途消息丢失事故。**切回挂起标签的 250–350ms 是 WebKit 页面树重建，不可优化**，
  只保留快照垫图的感知层方案。

## 风险

- **懒建 WebView**：任何提前访问都会触发兜底创建，收益可能被意外访问吃掉——用"意外建"
  计数兜底；无痕/容器的 data store 必须在懒建时正确传入。
- **导航守卫标志**：追踪包装要不可探测（Proxy/native toString）；探针只对 `window` 有效，
  标志口径与之一致；主框架提交必须复位。
- **`page-perf` 改主框架**：守护口径本就写的是主框架；重 iframe 页面不再计入（按设计），
  发布说明写清。
- **内存管家**：只动后台且遵守既有豁免；预算默认保守，设置可关。
- **Agent `releaseMemory`**：有副作用走审批；无人值守回合里误调用不得挂起用户正在用的标签。
- **性能数字**：Debug/Release 分开报；探针阈值按 Release 定，Debug 仅看趋势。
