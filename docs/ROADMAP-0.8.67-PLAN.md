# v0.8.67 规划稿（2026-11-20）—— 一接到底：Apple Handoff 接力旗舰 + 反馈修复版

> **主题叙事**：规划前核实**第九连"清单≠核实"**（差点误立项三件）：
> ① 站点地理位置委托**已实现**（WebView.swift requestGeolocationPermissionFor
> + PermissionStore 记忆 + PERF-6 无窗口兜底）；② 站点摄像头/麦克风委托
> **已实现**（requestMediaCapturePermissionFor 同款三态）；③ Apple Handoff
> 只用于 Spotlight 接收（CSSearchableItemActionType）——**浏览上下文系统级
> 接力（Safari 同款）真空白**。另两项候选当场否决：站点 Web Notification
> （WKUIDelegate 公开 API 零命中——WebKit 无公开宿主侧入口，与 Web Push
> 同源否决）；浏览器内代理设置（WKWebView 无 per-view 代理 API）。
>
> **旗舰 = Apple Handoff 接力**：Mac 上 Desire 停在某个页面 → iPhone 锁屏/
> 多任务出现系统级"继续浏览"卡片 → 点开直达 DesireRemote（显示 URL/标题，
> 可"在 Mac 上打开/复制链接/问 Agent"）。与既有手递（sendToPhone 主动推，
> 0.8.38）互补：手递是"我推给你"，Handoff 是"系统自动接力"。其余全部让位
> 真实使用反馈修复。

## 四主题

### ① 浏览器基础 = 真实使用反馈修复
- 0.8.62-66 的浏览器面继续使用期：翻译 2.0/术语表/双语成书/快拨收敛/
  同步完整性卡——反馈到达即修，不预规划。

### ② Agent 基础 = 使用期反馈修复
- 术语表注入/双语成书/校准卡/产物登记/E28 同上预留。
- Doctor 检查项扩充候选（核实后按需）：把"协作池水位/最近 stall"两 pill
  并入 Doctor 体检（RuntimeHealthMonitor 数据已在，只加显示行）。

### ③ 融合 = 旗舰「Apple Handoff 接力」+ 可选小组件
- **Mac → iOS**：macOS 侧 `NSUserActivity`（`activityType =
  "BrowsingWebPage"`，Safari 同款；requiredUserInfoKeys = URL/title，
  `isEligibleForHandoff` + becomeCurrent，导航即更新）——iOS DesireRemote
  `scenePhase.active` 接收 `continueUserActivity` → 弹"继续浏览"卡
  （URL/标题 + 三动作：**在 Mac 上打开**（既有 openBook 式深链通道）/
  **复制链接** / **问 Agent**（0.8.66 AskAgent 通道））。
  - 时序注意：activity 在导航 didFinish 更新（防半加载页接力）；
    iOS 端只在配对态显示卡（未配对静默忽略）。
- **iOS → Mac**：DesireRemote 里打开的链接（远端书/工具箱页等）可选
  `userActivity` 回传——批内评估（价值低则不做，手递已覆盖反方向）。
- **可选项（批 3 按剩余精力）**：WidgetKit 小组件 v1（iOS 锁屏/桌面：
  Mac 在线状态 + 最新产物一条；macOS 桌面同款）——两端均无 WidgetKit，
  数据源 = /state 快照缓存；做不做以批 1-2 进度定，不硬凑。

### ④ 替人干活 = 运营收账
- 产品页 0.8.65-67 三轮扩充 + 部署（持续欠账，固定提醒）。
- 服务端 desire-admin remote 子命令已随 0.8.65 交付——**生产部署**手工步
  固定提醒。

### 工程（贯穿）
- 下个"每 3 版全量"节点 = 0.8.68（190 项）。
- i18n 三语 / WhatsNew / smoke / Release 零警告 / CI 双架构例行。

## 批次（建议实况更新）

批 1 macOS NSUserActivity 发射端 → 批 2 iOS 接收卡 + 三动作 →
批 3 WidgetKit 小组件（可选）+ 文档/记忆清账 → 批 4 反馈修复预留 + 收口 →
**真机联调（Handoff 必须两台真机验收，用户参与）**。

**批 1+2 完成（2026-11-20，59a12baf + 批 2 本提交）**：发射端系统级验证
（com.apple.useractivity 全链到 Handoff.BecameCurrent——activity 创建/注册/
成为 currentItem 全通）；iOS 接收卡（配对态才收、防重复弹同 URL）+ 三动作
复用既有通道（openOnMac/openURL 帧、剪贴板、AskAgent prompt）。工程细节：
NSUserActivityTypes 不在 INFOPLIST_KEY 集——部分 plist + INFOPLIST_FILE
合并，同步组 membershipExceptions 排除资源拷贝（warning 消除）。
**待真机**：接力卡路由归属（BrowsingWebPage 会不会被系统强路由给 Safari）
+ 卡片动作端到端。批 3 WidgetKit 按剩余精力定；批 4 反馈预留+收口。

**批 3 砍除决定 + 批 4 收口（2026-11-20，同日）**：WidgetKit 小组件砍除——
工程量（新 widget extension target + App Group 数据管线）对价值比不划算，
且价值验证依赖真机联调之后的反馈；规划稿"超预算即砍"条款兑现。批 4 =
WhatsNew 刷三条亮点（三语）+ 反馈修复预留（发版时机由用户按反馈定）。
v0.8.67 内容收官。

## 不做

站点 Web Notification（WebKit 公开 API 缺口——与 Web Push 同口径）；
浏览器内代理（WebKit 无 per-view API）；--section / passkey / 隐私统计 /
节流 / 第三方翻译 / 书签同址去重 / 新 Agent 大件 / Android Remote /
服务端大改——全部维持既有否决。

## 风险

- Handoff 的 activityType 必须两端一致（"BrowsingWebPage" 为 Safari 同款
  —— Desire 点开系统接力卡可能被系统路由给 Safari 而不是 DesireRemote：
  批 1 先实测路由归属；若系统强路由 Safari，改用自定义 activityType
  `me.siwi.Desire.browsing` 并在两端显式声明——结论写进 AGENTS）。
- iOS 接收卡的"在 Mac 上打开"依赖桌面在线 + 既有深链通道；离线时降级为
  "复制链接"。
- WidgetKit 是可选批——数据管线（/state → widget 共享容器）若超预算即砍，
  不硬凑版本。
