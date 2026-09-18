# Desire — macOS Browser (SwiftUI)

## Project structure

- **macOS app** (`SDKROOT = macosx`) — not iOS. Target: macOS 26.5.
- Entrypoint: `Desire/App/DesireApp.swift:11` (`@main struct DesireApp`)
- Xcode 26.6, Swift 5.0, file-system-synchronized group (all `.swift` files under `Desire/` are auto-included).
- No package dependencies, no SPM, no test targets.

## Build & run

Open `Desire.xcodeproj` in Xcode and build (⌘B) or run (⌘R).
CLI build: `xcodebuild -project Desire.xcodeproj -scheme Desire build`

**Always build before reporting completion.** Unverified claims are unacceptable.

## Key conventions

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — prefer `@MainActor` on observable types.
- Strict concurrency checking is on (`SWIFT_APPROACHABLE_CONCURRENCY = YES`).
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` — each file must `import` every framework it uses directly (e.g. `import WebKit` for `WKWebView`, `import Combine` for `ObservableObject`). Cross-module re-exports are not visible.
- App Sandbox is enabled with `ENABLE_USER_SELECTED_FILES = readonly` — file access must use `NSOpenPanel`/`NSOpenPanel` URLs and scoped bookmarks.
- Hardened Runtime is enabled.
- `COMBINE_HIDPI_IMAGES = YES` — use `@2x` asset variants for Retina.
- Bundle ID: `me.siwi.Desire`, team: `F8JZTX6J52`.

## Browser-specific context

Building a web browser on macOS. Consider:
- `WKWebView` for page rendering
- App Sandbox with `com.apple.security.network.client` entitlement for web access
- `ENABLE_USER_SELECTED_FILES = readonly` limits file access — downloads need `NSDownloadsDirectory` or user-selected save locations
- String catalogs (`LOCALIZATION_PREFERS_STRING_CATALOGS = YES`) for localization

---

## 代码组织规范

### 目录结构（Feature 模块化）

```
Desire/
├── App/                        # 入口 + 窗口管理
│   ├── DesireApp.swift
│   ├── Desire.entitlements
│   └── WindowChromeGuard.swift
├── Features/
│   ├── Browsing/               # 浏览核心
│   ├── Bookmarks/
│   ├── History/
│   ├── Downloads/
│   ├── ContentBlocking/
│   ├── UserScripts/
│   ├── Settings/
│   ├── AddressBar/             # 地址建议/自动补全（不是地址栏 UI）
│   └── AI/                     # 预留
├── Views/                      # 跨功能共享 UI 组件
│   ├── ContentView.swift       # 主视图（组合各 Feature）
│   └── Components/             # 通用基础组件（Primitive）
└── Assets.xcassets
```

### 三层分离规则

每个 Feature 目录内严格按三层分离：

| 层 | 文件命名 | 职责 | import 规则 |
|----|---------|------|------------|
| **Model** | `Xxx.swift` | 纯数据结构（struct/enum），Codable/Identifiable，无任何逻辑 | 只 import Foundation |
| **Store** | `XxxStore.swift` | `@MainActor class: ObservableObject`，持有 `@Published` 状态，持久化（UserDefaults/JSON），业务逻辑 | Combine + Foundation（+ 按需 WebKit 等） |
| **View** | `XxxView.swift` 或 `XxxPanel.swift` | `struct: View`，纯渲染，通过 Store 方法驱动数据，零业务逻辑 | SwiftUI（+ 按需 AppKit 等） |

### 三层分离的例外

| 场景 | 允许模式 | 示例 |
|------|---------|------|
| **Domain Object** | 需要 KVO 的"活动实体"可以用 `class: ObservableObject` 放 Store 层，但命名不含 `Store` | `Tab`（Browsing）|
| **NSViewRepresentable** | WKWebView 封装允许在同一个 View 文件内放：辅助类型 + Coordinator + State holder | `WebView.swift` 含 `BrowserWKWebView`、`BrowserState`、`WebView`、`Coordinator` |
| **Store 依赖 Store** | Store 可以用 `let` 持有其他 Store 引用（强引用），用于协调业务逻辑 | `AddressSuggestionsModel.build()` 接收 `BookmarkStore`、`HistoryStore` |

Domain Object 认定标准：是一个**运行时实体**（运行中的页面/标签/请求），需要被 SwiftUI 观察其属性变化，并且其生命周期由 Store 管理。这种类型放在 Store 层，但 Model 层仍有对应的纯 struct 定义（用于持久化/编码）。

### UI 组件分类与组织

View 层再细分为**组件（Component）**和**页面/面板（Panel/Page）**，按层级管理：

| 类型 | 定义 | 命名后缀 | 示例 | 位置 |
|------|------|---------|------|------|
| **Primitive** | 单一用途的基础 UI 元素，无状态或纯本地状态 | `XxxButton` / `XxxField` / `XxxRow` / `XxxIndicator` | `CapsuleButton`、`EntryRow` | `Views/Components/` |
| **Composite** | 由多个 Primitive 组合而成，有特定功能，可跨标签页复用 | `XxxBar` / `XxxGroup` | `TabBar`、`FindBar`、`NavButtonGroup` | 所属 `Feature/` 内 |
| **Panel** | 独立弹出的面板/Sheet，通常展示一个 Store 的数据 | `XxxPanel` | `BookmarkPanel`、`HistoryPanel` | 所属 `Feature/` 内 |
| **Page** | 占据整个内容区域的页面 | `XxxPage` | `NewTabPage` | 所属 `Feature/` 内 |

### 组件存放规则

```
Views/
├── ContentView.swift              # 组合根（Composition Root）：拼装所有 Composite
├── Components/                    # 通用基础组件（Primitive）
│   ├── EntryRow.swift             # 通用列表行
│   ├── CapsuleButton.swift        # 胶囊按钮（统一圆角/背景/点击样式）
│   ├── LoadingDots.swift          # 加载指示器
│   ├── EmptyState.swift           # 空状态占位
│   └── FaviconView.swift          # 网站图标

Features/
├── Browsing/                      # Browsing 特有的 Composite 组件
│   ├── TabBar.swift               # 标签栏
│   ├── Toolbar.swift              # 导航工具栏 + 地址栏（锁图标 + TextField）
│   ├── FindBar.swift              # 查找栏
│   ├── NewTabPage.swift           # 新标签页
│   ├── TabManager.swift           # Store（含 Tab Domain Object）
│   └── WebView.swift              # WKWebView 封装
├── Bookmarks/
│   ├── Bookmark.swift             # Model
│   ├── BookmarkStore.swift        # Store
│   └── BookmarkPanel.swift        # Panel
├── AddressBar/
│   ├── AddressSuggestion.swift     # Model
│   ├── AddressSuggestionsModel.swift # Store（搜索建议/自动补全逻辑）
│   ├── AddressSuggestionsView.swift  # View（建议下拉列表）
│   ├── FaviconStore.swift          # Store（图标缓存）
│   └── SearchSuggestionService.swift # 纯工具类（无状态）
├── Settings/
│   ├── Settings.swift              # Store（命名保留，非 Store 后缀）
│   └── SettingsView.swift          # View
```

### 组件抽取规则

1. **被 2 个以上 Feature 使用** → 提取到 `Views/Components/`，去掉所有业务依赖。
2. **只被一个 Feature 使用但 >50 行** → 提取为独立文件放该 Feature 目录内。
3. **只被一个 Feature 使用且 <50 行** → 作为私有子视图（`private struct`）放在使用它的 View 文件底部。
4. **ContentView 是组合根**，只负责拼装 Composite，不放任何 UI 渲染逻辑。

### 组件设计原则

1. **Props in, Callbacks out**：组件通过构造参数接收数据，通过闭包回调事件，**不直接持有 Store**（Panel 例外，Panel 可以持有 `@ObservedObject Store`）。

2. **Callback 分组规则**：当 Composite 组件的构造参数（不含 `@Binding`）超过 8 个时，必须将回调聚合为结构体：

```swift
// ❌ 不OK — 参数过多
struct Toolbar: View {
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let onReload: () -> Void
    let onLoadHome: () -> Void
    let onNavigate: (String) -> Void
    let onBookmarkCurrentPage: () -> Void
    let onToggleFullScreen: () -> Void
    let onSuggestionSelect: (AddressSuggestion) -> Void
    ...
}

// ✅ OK — 聚合为 Actions
struct Toolbar: View {
    struct Actions {
        let goBack: () -> Void
        let goForward: () -> Void
        let reload: () -> Void
        let loadHome: () -> Void
        let navigate: (String) -> Void
        let bookmarkCurrentPage: () -> Void
        let toggleFullScreen: () -> Void
        let suggestionSelect: (AddressSuggestion) -> Void
    }
    let actions: Actions
    ...
}
```

也可以考虑用 enum + 闭包分发（适合回调间有明显种类区分时）。

3. **无副作用**：Primitive 和 Composite 不做持久化、不发网络请求。
4. **推荐加 `#Preview`**：方便 Xcode 预览开发，但上层组件（依赖多个 Store 的）可跳过。
5. **Style 一致**：胶囊形状统一用 `Capsule()`，圆角统一用 `RoundedRectangle(cornerRadius: 6)`，不要各写各的。

### 文件颗粒度规则

1. **一个文件 = 一个类型**。Model 文件只含一个 struct/enum；Store 文件只含一个 class；View/Component 文件只含一个主类型。
2. **例外 1**：仅供同一 View 使用的私有子视图（`private struct`），可以放在同一文件内。
3. **例外 2**：NSViewRepresentable 封装（WebView 等）可在同一文件放：NSView 子类 + State holder + View + Coordinator。这些类型紧耦合，拆开反而难维护。
4. **例外 3**：Domain Object（如 `Tab`）可以和管理它的 Store 放在同一文件，因为它本质是 Store 的内部状态载体。
5. **禁止**在 Store 文件里定义纯 Model（Codable struct）。
6. **禁止**在 View 文件里定义业务逻辑（持久化、数据处理放 Store）。

### 文件命名惯例

| 类型 | 命名 | 示例 |
|------|------|------|
| Model struct/enum | `Xxx.swift` | `Bookmark.swift` |
| Store class | `XxxStore.swift` | `BookmarkStore.swift` |
| 领域对象 (ObservableObject) | `Xxx.swift` 或随 Store 文件 | `Tab.swift` 或在 `TabManager.swift` 内 |
| View | `XxxView.swift` / `XxxPanel.swift` | `SettingsView.swift` |
| Composite | `XxxBar.swift` / `XxxGroup.swift` / `XxxSection.swift` | `TabBar.swift`, `AISettingsSection.swift` |
| Page | `XxxPage.swift` | `NewTabPage.swift` |
| Primitive | `XxxButton.swift` / `XxxRow.swift` 等 | `EntryRow.swift` |

### 示例：Bookmarks Feature

```
Features/Bookmarks/
├── Bookmark.swift           # struct Bookmark: Identifiable, Codable
├── BookmarkStore.swift      # class BookmarkStore: ObservableObject
└── BookmarkPanel.swift      # struct BookmarkPanel: View
```

### 加新 Feature 的步骤

1. 在 `Features/` 下建目录
2. 按三层创建文件（Model → Store → View）
3. 如有复用 UI，提取到 `Views/Components/`
4. 在 `Views/ContentView.swift` 中组合
5. Build 验证


---

# Agent 协作规范（AI 助手沉淀 · 必读）

## 测试与自动化：只用 CLI 桥，禁用 UI 自动化

- 应用以 `--automation` 启动后，`127.0.0.1:8799` 提供完整 JSON 接口
  （见 `Desire/App/AutomationServer.swift` 头注释）。
- **禁止** System Events 键盘注入 / 坐标点击：多全屏 Space 环境下会
  切空间、误注入前台其他应用，且 SwiftUI 窗口内 Menu 无法按名点击。
- **禁止**把"打开某页面"做成 UI 操作 — 一律
  `curl -X POST .../navigate -d '{"url":"…"}'`。
- 截图两条路：`/screenshot` 只拍 **webview 内容**（SwiftUI 覆盖层如
  错误页/手柄/标尺不在其中）；要拍整窗用
  `screencapture -o -x -l <winid>`（winid 用 CGWindowList 取）。
- 启动流程（顺序敏感）：
  `pkill -9 -x Desire; sleep 2; open <app> --args --automation; sleep 6`
  然后必须 `curl /state` 验证桥活着再继续。
- **网络抖动会造成假阳性**（example.com 白屏、baidu 间歇失败均发生过）。
  任何"加载失败"结论必须复测两次以上才能定性。
- **中键/鼠标事件的合成测试**（2026-09 摸索）：webview 内事件用
  `/execute` 注入 `new MouseEvent("auxclick",{button:1})` 即可；
  标签栏等 SwiftUI 层事件用 CGEvent.postToPid（只投递给目标进程，
  不碰其他应用、不切空间）。注意：postToPid 事件坐标不可信（会被
  替换成系统光标位置，且 y 轴按窗口底部原点翻转），须先
  CGWarpMouseCursorPosition 到目标点、投递 y 取 `屏高-y`、再还原光标；
  胶囊实际矩形可从 `log stream --predicate
  'subsystem == "me.siwi.Desire" AND category == "tabs"' --level info`
  的 middle-click 日志里读到。`/downloads/pause|resume` 端点可直接
  驱动下载暂停/恢复复现竞态。SwiftUI 面板（下载 popover 等）用
  `POST /panel {"name":"downloads","show":true}` 打开后
  `GET /panel/snapshot?name=downloads` 在进程内渲染成 PNG——
  不需要屏幕录制权限，锁定屏幕/捕获遮罩下也能用（screencapture -l
  在这些情况下只会报 could not create image）。

## 已知半成品 / 未支持完整的功能

修功能前先查此清单，避免重复踩坑或误判"这是新 bug"：

- **响应式模式**：核心可用（UA 切换+重载、拖把手、触摸模拟）。
  遗留：pixelRatio 模拟、真网络节流（WebKit 无 API，需
  Network Interception，勿再做假 UI）。
- **快捷键设置页**已接线（2026-09）：单一共享实例挂在
  SystemState.keyboardShortcutStore；菜单命令（App/AppCommands.swift）
  与 ContentView 隐藏快捷键按钮全部从 Store 构造 .keyboardShortcut，
  设置页改键持久化、**下次启动生效**。勿尝试实时重绑：macOS 26 的
  SwiftUI Commands body 会随 Store 变化重算（已用日志实证），但
  keyEquivalent 变化和 .id() 结构重建都不会推给已安装的 NSMenu 条目。
  映射里 savePage 尚无对应命令（未接线）；⌘1-9 切标签和 Esc 保持硬编码。
- **BUG-K 优雅退出挂起**：已缓解（2026-09，0.1.1）：SIGTERM/SIGINT 现在
  由 AppDelegate 安装的 DispatchSource 接管并转 NSApp.terminate(nil)——
  走 applicationShouldTerminate → 会话 flush → 干净退出，与 Cmd+Q 同
  路径（旧默认处置是硬终止，WebKit 分线程拆除时竞态卡 exit）。
  applicationShouldTerminate 里加了 ShutdownDiagnostics（存活 URLSession
  任务/下载/Agent 循环状态的 fault 日志）；SIGTERM 压测 100 轮通过
  （结果见 0.1.1 提交）。若复发，对照 fault 日志排查。
- **会话恢复**已修复（2026-09）：SwiftUI 在 macOS 上不写 Saved
  Application State，带 UUID 的窗口永远不会被还原，"按窗口 UUID 恢复"
  的设计在还原侧断链（保存侧正常，退出时写 session-index + 各
  session-<uuid>.json）。现首窗口 UUID 全新时采纳 index 中最近的会话
  （ContentView 采用路径，Window 重新绑到该 identity）。
  已知边界：强杀进程（-9）后 index 是上次干净退出的，可能还原较旧的
  会话；正常 Cmd+Q 路径已实测还原。
- **下载**：暂停→秒恢复竞态已修复（2026-09：resume 先挂起意图，
  checkpoint 数据落地后由 storeResumeData 触发；数据为空
  （服务器不支持 Range）则删残件、复用原文件名重启，见
  DownloadStore.pendingResumeIDs）。无痕下载已隔离：DownloadItem.isPrivate
  行内可见但不写入共享历史（BrowserState.isIncognito 来源）。
  暂停行已能跨重启存活：HistoryItem.isPaused 持久化（2026-09 之前
  暂停行重启会变成假活行）；恢复无活动传输的行会自动从源 URL 重启。
- **中键**（关标签/开链接）已实现（2026-09）：关标签走
  TabMiddleClickMonitor（本地 NSEvent 监视器 + 胶囊帧注册表，闭包只捕获
  tab.id、关闭时实时查 index——勿改回捕获 index 快照，会在增删标签后
  失效）；开链接走注入的 middle-click.js（auxclick button==1）→
  middleClickLink 消息 → onOpenLinkInNewTab。
- **beforeunload 表单保护**已实现（2026-09）：本版 WebKit 对无用户手势
  的卸载**完全不派发** beforeunload（实测 sendBeacon 在 handler 内都不
  触发，原生 `runJavaScriptBeforeUnloadConfirmPanelWithMessage` 永远
  不会被调用），因此保护做在 decidePolicyFor 主框架导航决策点：
  合成派发页面的 beforeunload 监听器（WebView.beforeUnloadProbeJS），
  页面拒绝离开时弹 sheet（PendingBeforeUnload，可经桥
  `GET /beforeunload` / `POST /beforeunload/resolve` 程序化决策）。
  back/forward/reload 沿用"不拦截"既定策略不在此保护内。
- **多窗口 Agent 联动**：未实现。
- **passkey**：需要 Apple 签发 private-key-credential entitlement，
  已申请流程见 docs/。
- **Keychain 域**：沙盒移除后 API key 需在设置里重新保存一次
  （容器 keychain → login keychain 的域切换，预期行为）。

## 架构决策（勿回退、勿重复踩坑）

- **分栏拖拽**：用 `HStack + ResizableDivider`（基线宽度 + 1:1 跟随 +
  11pt 命中区）。**禁用 HSplitView** 包含 WKWebView 平台视图的组合 —
  SwiftUI HoverEventDispatcher 会在主线程断言处崩溃（启动即崩，实测
  两次复现）。面板宽度所有权归容器，**禁止**面板内部固定
  `.frame(width:)`（会顶住拖拽）。
- **TCC/隐私授权必须懒请求**：只在用户点击对应功能时发起
  （见 VoiceInputManager）。面板 init 时发起会在非标准启动方式下
  （nohup 直跑二进制，bundle 上下文残缺）被 TCC 直接杀进程。
- **启动方式**：测试一律 `open <app> --args --automation`；
  nohup 直跑二进制会破坏 bundle 上下文（TCC 崩溃的诱因之一）。
- **DiskStore 是 500ms 防抖异步写**：测试里改完数据要 `sleep 1` 再断言
  落盘；结束进程必须优雅退出（`osascript -e 'quit app "Desire"'`），
  `pkill -9` 会丢防抖窗口内的所有写入（已两次误判为"bug"）。
  改 UserDefaults 也必须非沙箱执行（沙箱 shell 的 defaults write
  写不进真实偏好域）。
- **本地测试服务端口用 8877**（8000 常被用户自己的开发服务占用）。
- **executeJS 错误详情**：evaluateJavaScript 的错误对象不含真实异常
  文本；正确 key 是 `WKJavaScriptExceptionMessage`，经
  callAsyncJavaScript 重跑捕获（见 BrowserToolProvider+Execution）。
- **历史标题**：WebKit 的 title KVO 晚于 didFinish — 历史入库 800ms
  后有延迟校正（HistoryStore.updateEntryTitle），勿删。
- **桌面 UA 是反爬基线**：`BrowserState._desktopSafariUA` 刻意不带
  Desire 产品 token（Cloudflare 按 UA 判非 Genuine Safari 会拦站）。
  修改 UA 逻辑前先读 WebView.swift 内注释。

## 端点扩展模式

新自动化能力 = AutomationServer.route 加 case + 一个 static 实现，
数据源用 `TabSessionCoordinator.shared.activeTabManager`（活动窗口）
或 `AgentScheduler.shared.deliveryTarget`（活 Agent 会话）/ 各 Store
的 `.live` 弱注册（如 DownloadStore.live）。读写分离：查询用新实例
读盘即可，写操作必须走 UI 持有的同一实例。
