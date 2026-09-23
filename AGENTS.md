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
- **App Sandbox is OFF** (`ENABLE_APP_SANDBOX = NO`, entitlements file is empty) — **deliberate**: the built-in AI Agent executes arbitrary shell commands / system operations, which a sandboxed app cannot. Do NOT "fix" this by re-enabling the sandbox. Consequence, not bug: the app process has full user-file access, so any file-scoping (e.g. downloads) is enforced in app logic, not by the platform.
- Hardened Runtime is enabled.
- `COMBINE_HIDPI_IMAGES = YES` — use `@2x` asset variants for Retina.
- Bundle ID: `me.siwi.Desire`, team: `F8JZTX6J52`.

## Browser-specific context

Building a web browser on macOS. Consider:
- `WKWebView` for page rendering
- No App Sandbox — network and file access need no entitlements; security boundaries are Hardened Runtime + app-level logic
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

- **查编译警告只有一种正确姿势：`xcodebuild … clean build 2>&1 | grep -E "warning:"`**
  （2026-09-23 踩，代价是 v0.3.12 带着 6 条警告发了出去，用户从 Xcode 里贴回来才发现）：
  ① xcodebuild 输出里**路径在 `warning:` 之前**（`<path>.swift:12:3: warning: …`），
  惯用的 `warning:.*\.swift` 一条都匹配不到，据此报"零警告"是假的；
  ② **增量构建只重编改动的文件**，没碰过的文件里的警告根本不会出现——要下结论
  必须 `clean build`。另：`appintentsmetadataprocessor` 那行不是代码警告，可忽略。
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

- **读应用/WebKit 日志要用 `/usr/bin/log`**：zsh 有同名 builtin，直接敲
  `log` 会报 "too many arguments"（曾据此误判"统一日志不可用"）。
  `/usr/bin/log show --last 2m --info --debug --predicate 'process == "Desire"' --style compact`
  能看到 WebKit 的 `com.apple.WebKit:Fullscreen`/`ImageAnalysis`、VisionKit
  的 DD element/VKC 等机制日志——全屏与浮层问题的第一现场。配合
  `GET /diag/geometry?index=N`（webview frame/bounds/父视图链/子视图树 +
  每个窗口的 frame/contentLayout/styleMask/全屏状态/所在屏幕）定位几何归属。

- **测试用假端点：登记 + 按模式全清，并且一定要放掉端口**（2026-09-23 真踩）：
  我用来验证脱敏的 `/tmp/fake_leak.py` 监听在 **127.0.0.1:8889 —— 那正是用户 `amd` 档案的
  端点**；收尾时我只按文件名清了 `fake_openai.py`（`pgrep -f fake_openai.py`），这个假端点
  活了下来，几小时后用户发任何消息都得到同一句回复（假端点对任何输入都固定回一个
  `readFile leak.txt`），看起来就是"聊天坏了"。规矩：
  ① 收尾用 **`pgrep -fl "fake_"` 这种模式扫**，别只按你记得的那个文件名；
  ② **占的端口要确认释放**（`lsof -nP -iTCP:<port>`），尤其别占用**用户真实服务**的端口——
  假端点优先另开端口（我用 8880 的 fixture 就没这个问题）+ 用**临时档案**指向它；
  ③ 配套的假凭据文件（如 `~/Documents/DesireAgent/leak.txt`）放在 agent 工作目录里，
  别留在项目根目录（会被顺手提交）。
  诊断这类"行为不对"的入口：`AI request — endpoint: …` 这行 info 日志（见 CHANGELOG）。

- **清理测试数据别按"含测试字样"搜出来就删**（2026-09-23 我删掉了用户一个会话）：
  `POST /conversations/delete` 的 ids 来自 `conversations/search?q=<测试词>`，但命中的那条
  会话**可能原本就是用户的**——测试消息只是被追加进去的（它同时含有用户自己的提问与工具轨迹）。
  规矩：只删**这次自己全新创建**的会话（内容自己清楚）；拿不准就留着，并在汇报里说明留了什么。
  另外 `POST /conversations/delete` 的响应里 `liveConversationDeleted: true` 表示那是**面板里
  正在显示**的会话——它的消息还在内存里、下一回合落盘会写回文件，光删文件不解决问题。

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

- **视频全屏 = WebKit 原生 element fullscreen + `WebViewContainer`**
  （2026-09-20 实测收敛；此前三轮返工的真根因）：
  - `isElementFullscreenEnabled = true` 必须保持。WebKit 会自建覆盖整屏的
    `WebCoreFullScreenWindow`，把页面视口放大到整屏，视频层随之铺满。
  - **任何覆盖 `Element.prototype.requestFullscreen` 的注入脚本都会废掉
    全屏**——历史 shim 正是这么把全屏降级成"CSS 把元素钉在 webview 视口"，
    于是视频只有网页区域大小、四周黑边。最小宿主对照实验：同页面不注入
    shim → `WebCoreFullScreenWindow` + 视口 2560x1440；注入同一份 shim →
    `fullscreenState` 停在 notInFullscreen、视口不变。**勿再注入全屏 shim**。
  - `WebView`（NSViewRepresentable）**必须返回 `WebViewContainer`，不要直接
    返回 webview**：SwiftUI 每轮布局都会重设"它返回的那个视图"的 frame——
    包括 webview 已被 WebKit 搬进全屏窗口之后。实测帧序列 1262 →
    1440（WebKit 设置正确）→ 1262 → 0×0（SwiftUI 用旧标签区尺寸盖回去），
    结果全屏视频锁死在过期视口（黑边）或页面渲染成 0×0（黑屏）。容器方案
    下 SwiftUI 只动容器、webview 靠 autoresizing mask 跟随，全屏期间没有
    应用侧代码再碰 WebKit 的几何。
  - **禁止**在全屏中手动改 webview frame：实测 WebKit 会把它重置成 0×0
    （黑屏）。
  - **窗口全屏与站点整屏必须分开判**（2026-09-21 现场指令）：原生窗口全屏
    （⌃⌘F）**保持标签栏/工具栏可见**——全屏浏览不能切标签等于没法用；只有
    **站点自己发起的整屏**（视频/元素全屏 = WebKit 自建的
    `WebCoreFullScreenWindow`）才收起 chrome。实现：ContentView 两个独立标志
    （`isWindowFullScreen` 只管标签栏给红绿灯留的边距，`isSiteFullScreen` 才收
    chrome），由 `NSWindow.didEnter/ExitFullScreenNotification` **按窗口身份**
    区分（`Self.isSiteFullscreenWindow(_:hosting:)`）。原先只用一个
    `isFullScreen` 一视同仁地收 chrome，用户实测"全屏时没有 tab 栏，很难用"。
  - VisionKit 图像分析（Live Text）已关（`config.setValue(false, forKey:
    "systemTextExtractionEnabled")`）：WebKit 对视频帧自动跑文本提取并在
    webview 里装 VKC 浮层，该浮层在布局过渡中以 0×0 bounds 算出 NaN
    contentsRect → `_NSViewValidateGeometry` 断言直接杀进程（2026-09-20
    崩溃报告）。Desire 没有 Live Text UI，勿再打开。
- **视频广告拦截规则是热插拔的（2026-09-20）**：CSS/JS 由
  `VideoAdRulesStore` 按 **本地覆盖 > 远程包 > 内置** 解析，注入时（新 webview /
  每次导航）才取值。改规则不用重新构建：改 `~/Library/Application
  Support/Desire/VideoAdRules/<site>.css|.js`（或远程包的 `remote/source.txt`
  指向的 rules.json）→ 设置里点“重新加载” → 刷新页面。注入是代数化的
  （CSS `data-gen`、JS `window.__desireRulesGen`）：导航时补投新代数，避免
  user script "创建 webview 时定格"导致新规则进不了已开的标签页。
  **信任边界**：远程包的 JS 默认不生效（会在页面上下文执行），必须显式打开
  “信任远程规则脚本”；没有配置源时缓存的包一律不参与解析。
  脚本清单里各站自己有 `window.__desire*` 一次性标志位，代数变化时由包装器
  清掉以重跑——新增站点脚本必须保留这个 guard 名对应关系（`VideoSite.guardFlag`）。
- **应用内强调色只能用 `.tint` 系样式，禁止 `Color.accentColor`**（2026-09-20）：
  `Color.accentColor` 既不跟随 macOS 系统强调色也不跟随 Desire 设置里的强调色
  （实测 `.tint(purple)` 环境下它仍返回 SwiftUI 默认蓝 #009DFF）——`.tint` 只对
  系统控件生效，自绘的胶囊/描边/图标会一直是默认蓝，于是"主题色在标签栏没应用"。
  需要 ShapeStyle 的地方写 `.tint` / `AnyShapeStyle(.tint.opacity(x))`；三目里混
  非强调色时用 `AnyShapeStyle(...)` 包两侧；确实要 `Color` 值（如
  `LinearGradient(colors:)`）就由调用方把 `settings.accentColor.color` 传进去。
  每个独立窗口/面板（设置窗、Agent 浮窗、截图层、引导页）都要在根视图自己挂
  `.tint(...)`——ContentView 的 tint 不跨 scene。
- **App Sandbox 有意关闭**（`ENABLE_APP_SANDBOX = NO`、entitlements 为
  空）：Agent 功能要执行系统命令，沙盒做不到。**禁止**以"安全修复"
  名义重开沙盒——重开 = Agent 全部系统级能力失效。见上文 Key
  Conventions。
- **分栏拖拽（0.3.10 终版，用户实测收敛）**：**HSplitView 原生分栏**——
  分屏右栏/MQ 检查器/Agent/DevTools 全部是其子视图，分隔条与拖拽由
  SwiftUI 提供，视图内**零拖拽代码**。宽度协商只走子视图
  `minWidth/idealWidth/maxWidth`，**禁止**面板内部固定 `.frame(width:)`
  （会顶住拖拽）。历史：2026-09-18 HSplitView+WKWebView 曾有
  HoverEventDispatcher 延迟崩溃记录（15d279c 回退），0.3.10 同组合
  实测未复现——旧禁令作废；反过来**系统 `.inspector` 在实机上分隔条
  不可拖**（75734fb 回退原因）。九轮自研机制（冻结/快照/盖布）全部
  因卡顿或宽度失控被否；webview resize 的过场闪是 WebKit 引擎行为，
  与分隔条组件无关，`drawsBackground` 保持默认**不透明**（KVC 关闭
  会破坏旧帧拉伸、加剧闪烁）。
- **扩展/插件存储的两个坑（2026-09-21 实测）**：
  - **插件列表 = `PluginStore`（UserDefaults `desire.plugins`），存储后端 =
    `WebExtensionStore`（UserDefaults 的 `desire.webext.storage.<uuid>` 桶）**。
    `WebExtensionRegistry`（`storage.json` 文件那套）**是没接线的旧子系统**——
    全仓只有它自己引用自己，别照它写新功能。
  - 插件世界的 `browser.storage` 走 `webext-api.js` 的 RPC，**必须带 `ext`
    （`window.__desireExtID`）**；不带的话宿主 `WebExtensionView ...handleExtensionMessage`
    取到 nil，所有插件的存储会混进共享桶 `desire.webext.storage`（已修，
    勿改回）。`/webext/eval` 没有插件身份，写的也是共享桶。
- **调试面板按标签页收敛（2026-09-21）**：`DevToolsStore` 是 **app 级单例**，
  Console / Network 的每条记录都带 `tabID`（`WebView.tabID` ← `Tab.id`，
  在 `ContentView+WebViewFactory` 扎进去），面板用 `TabScope`
  （current / all / tab(id)）过滤，计数、清除按钮、桥端点都跟着作用域走
  （`GET /devtools` 给作用域计数 + `totals`；`POST /devtools/config` 切 scope）。
  两个坑：① **后台/挂起标签页的 `navigationDelegate` 被置空**
  （`TabManager` 挂起路径），`didStart/didFinish` 不触发，所以"登记标签页"
  必须也从消息路径走（`Coordinator.noteTabInDevTools`）——顺带说明后台标签页
  的 console/network 消息本来就不上报（消息处理器随视图挂/卸），面板里的
  "全部标签页"= 本次会话里被前台化过的那些；② `noteTab` 内容没变时**不要
  发布**，它每条消息都会被调用，无条件写回会让面板跟着日志重绘。
  面板所在标签页由 `DevToolsPanel.onChange(of: tab?.id, initial: true)`
  写进 store（`activeTabID`），`.current` 靠它解析。
- **流式 UI 的性能红线（2026-09-21 实测，用户报"流式输出时卡死"）**：三个坑都在
  Markdown 渲染路径上——① 块解析曾放在 `.task(id: text)` 里 = 主线程，流式时每
  80ms 重解析越来越长的全文；② 内联渲染（每块 5 条正则 + AttributedString）在
  **每次重绘**对所有块重跑；③ 块渲染每次刷新重建上千个子视图（长回答含表格/代码块时
  实测偶发 0.5s 卡顿）。现状：解析在后台且可取消，内联结果按文本缓存（500 条上限），
  并且**块数 > 120 的流式中消息退化成纯文本**（`MarkdownRendererView.isLive`，由
  `AgentMessageBubble.isStreamingTail` 传入），流结束立刻恢复 Markdown。
  **复现/验证手法（可复用）**：假端点加一个 `BIGSTREAM` 模式流式吐 40KB Markdown，
  用聊天面板打开时 `/state` 的往返延迟当主线程探针，并数
  `/usr/bin/log show --predicate 'process == "Desire"'` 里的
  `pending main thread dispatch stuck` 行。**注意两次测量都要在同一实例的第二次运行上
  取**：冷启动首次流式仍有残余尖峰（字体/文本布局缓存未热）。
- **思考过程（reasoning）三条约定**（2026-09-21）：① 字段名有三种——`reasoning_content`
  （DeepSeek / Qwen vLLM）、`reasoning`（OpenRouter 等）、`thinking`，解析时都要认；
  ② **绝不回传**：`encodeMessage` 只发 role/content/tool_calls，把 reasoning 塞回请求会被
  DeepSeek 这类服务直接拒（400）；③ 展示是**折叠块**，流式思考时自动展开、正文一开始自动
  收起，用户手动点过之后不再自动切换（`ReasoningBlock`，`isLive = isStreamingTail &&
  content.isEmpty`）。
- **输入历史记在 `sendMessage`，不是面板里**（2026-09-21 用户需求后又修正）：Agent 输入框
  ↑/↓ 翻的是**按对话**保存的 `inputHistory`（随会话文件落盘，上限 100、相邻去重）。
  最初我把 `rememberInput` 放在 `AgentPanel.submit()`，结果**桥/排队的发送路径绕过了它**
  ——记录点放进 `sendMessage` 并加 `recordHistory`（默认 true = 用户输入；桥/调度传
  false，免得自动化提示词混进用户历史）。↑/↓ 只在输入框为空或已在翻阅时接管，否则
  交还 TextEditor（多行编辑的光标移动不能被历史抢走）。
- **请求里 system 只能有一条、且必须在开头**（2026-09-21 实测）：OpenAI 兼容服务
  （amd 网关实测）拒绝夹在对话中间的 system 消息，报 `System message must be at the
  beginning.`。所以**带外备注（`appendExternalNote`，下载完成之类的 system 消息）不能
  留在 `messages` 里直接发出去**——`buildRequestMessages` 会把它们摘出来并进开头那条
  组合提示的 `## Session notes` 一节。新增"往会话里塞 system 消息"的功能时照此处理。
  回归：`POST /agent/note` 写一条备注，再发一条消息，用回显端点确认
  `sysCount=1 / sysAt=[0] / notesInSystem=true`。
- **Agent 回合永远不许"静默结束"**（2026-09-21，用户实测"几次工具失败后再发消息没有回复"）：
  模型返回空内容时此前直接 `return`——不写消息、不报错，用户看到的就是"石沉大海"。
  现在空回合会写一条可见警告并把该轮标记失败。配套两条：① **OpenAI 兼容服务会把错误塞在
  流里**（`data: {"error":{…}}`，HTTP 仍是 200），`OpenAICompatSSE` 必须解析并抛出，
  否则又是一个空回合；② **`executeJS` 的结果必须能字符串化**——DOM 节点/NodeList/循环引用
  走 `BrowserToolProvider.jsStringifyScript` 包装器，别再让模型看到"返回结果的类型不受支持"
  （实测模型因此改用 `runCommand` 并超时 120s，把整轮拖垮）。排查这类"没回复"时：
  看会话 JSON（`~/Library/Application Support/Desire/storage/conversation-*.json`）+
  `/usr/bin/log show --predicate 'process == "Desire"' --info --debug` 里的
  `[me.siwi.Desire:ai] AI request — …` 行，确认请求发没发、返回了什么。
- **WebKit content-blocker 的三条硬约束（2026-09-21，过滤列表"更新失败"的真因）**：
  ① `resource-type` 只认 `document / image / style-sheet / script / font / media /
  svg-document / raw / popup`——**`style`、`other`、`websocket` 写了就整份列表编译失败**
  （`Invalid string in the trigger flags array`）；② 一个 trigger 的四个域条件
  （if-domain / unless-domain / if-top-url / unless-top-url）**只能有一个**，`domain=a|~b`
  这种正负都有的规则必须整条丢掉（`A trigger cannot have more than one condition`）；
  ③ **url-filter 的正则里不能有组内 `$`**——`(?:[/?#]|$)` 会让所有 `||host^` 规则失效
  （`Invalid or unsupported regular expression`），`^` 只能译成 `[/?#]`；裸的尾部 `$`
  是允许的。
  排查手法（本次三处根因就是这么找到的）：`POST /filters/probe {"abp": "…"}` 或
  `{"regexes": [...]}` 把规则真交给 WebKit 编译并读逐条错误；`GET /filters` 看各列表
  状态与失败原因；**注意独立小程序里的 `WKContentRuleListStore` 编译比应用内宽松**
  （同样内容小程序通过、应用报错），别拿它当判据。过滤器编译失败会走**二分自愈**
  （`FilterListStore.sanitize`）只丢坏规则，日志里能看到丢了哪些。
- **首次点击劫持要"只拦第一次 + 只拦体外链接/浮层"**（2026-09-21，用户反馈视频站
  播放键首击跳广告）：`UserScripts/first-click-guard.js`，随"拦截视频广告"开关注入，
  **主框架 + atDocumentStart**（晚于页面自己的处理器就拦不住）。三条边界必须守住：
  ① 只在存在 `<video>` 的页面生效；② 只处理**第一次**点击（否则会把站点正常交互全毁掉）；
  ③ 只拦**站外链接**与**覆盖视口 ≥25% 的定位浮层**，站内链接与播放器控件放行。
  首击期间临时禁 `window.open` 并 1.2s 后恢复（别永久改写）。验证用本地 fixture 三变体：
  站外锚点覆盖播放器 / 脚本 `window.open` / 站内链接（分别断言 不开新标签页、被拦、正常跳转）。
  提示条走既有 `videoAdBlocked` 通道（`action: "click-hijack"`）。
- **长任务不能阻塞 agent 轮次**（2026-09-21，用户实测"下载一直在等待"）：
  `downloadMedia` 曾 await 整个导出（HLS 几分钟）。现在的模式：工具**立刻返回任务 id**，
  工作在 `MediaExportStore` 的后台 Task 里跑，完成时 ① 往会话追加 system 备注
  （`AgentSessionStore.appendExternalNote`，面板不渲染 system 但模型能看到）
  ② 发系统通知（懒请求授权）。**新增长任务工具照这个模式做**，不要再 await 到底；
  进度用 `listMediaExports` / 桥 `GET /media/exports` 查。
- **广告识别与屏蔽是"候选 + 理由 → 用户确认 → 规则"三步**（2026-09-21）：
  `ad-candidates.js` 只读打分（class/id、跨域 iframe、广告联盟域名、覆盖层 z-index、
  广告位尺寸、Sponsored 文案），`blockElements` 写 ElementBlockStore 并**立刻注入**隐藏
  CSS（下次导航由 WebView 的 didFinish 自动注入）。**注意**：class 里带 `ad-` 这类元素
  **内置过滤列表已经会隐藏**（实测 0×0），验证时要用规则拦不住的形态，否则会误判成
  "AI 起效了"。规则可回滚：`GET /ads/rules`、`POST /ads/rules/clear`。
- **流式列表的四条滚动规则（2026-09-21 三轮收敛，2026-09-23 补第 ④ 条）**：① **锚点固定
  `.top`**——内容增长绝不移动视口；`.bottom`（最初）会在流式时把视口拽回底部（用户没法上滑），
  而"按跟随状态在 `.bottom`/`.top` 间切"（中间版本）会**反复切换、每次切换都跳**，
  用户看到的就是"上下抖动得厉害"。② 跟随只靠**显式 `scrollTo`**，且只在贴底时触发；
  ③ "贴底"判定必须带**迟滞**（进 60pt / 出 160pt），单一阈值在流式（内容每 80ms 长
  一截）时会来回翻转。④ **迟滞只能在"用户自己滚动"时判定**——用
  `onScrollPhaseChange` 的 `phase != .idle` 判断，**内容增长同样会触发
  `onScrollGeometryChange`**：单次增长超过 160pt（一次 flush 吐一大段、工具卡片/代码块/
  表格一次渲染出来、输入框长高把视口挤矮）会被误判成"用户上滑"→ 跟随**永久停住**，
  用户看到的就是"消息输出到一半被输入框挡住"（2026-09-23 用户报"经常"）。
  程序化滚动（发消息后的强制跟随、"回到最新"按钮）要自己把状态认领回贴底。
  另外**流式中增长的块要固定高度 + 内部滚动**（思考块 `ReasoningBlock` 就是），否则每段
  文字都会让整条会话重新排版，叠上跟随就是抖动。
- **消息气泡上的操作行（👍/👎/复制）要占位、且必须在气泡下方**（2026-09-23 用户实拍反馈）：
  曾经用 `.overlay(alignment: .topTrailing)` 叠在气泡上，短消息时压住正文第一行。规矩：
  ① **不要 overlay 在内容上**——放进"气泡 + 操作行"的 VStack 里，行在气泡下方；
  ② 显隐用 **`opacity` + `allowsHitTesting`**（不是 `if`），并且**宽度也一直占着**——否则
  hover 时下面的消息会跳、同排的复制按钮会左右横移；③ **贴着气泡的左缘**：行里**不要**放
  `Spacer` 把它撑满——撑满会把按钮推到面板右缘，看起来与消息"分两侧"（用户第二轮反馈）；
  ④ 只在有正文且非报错时出现。
  同一位置还有一条相关约定：判断 hover 是否生效时记得**应用必须在前台**（tracking area 在
  非 key window 不激活），而且**别去抢用户的鼠标**——warp 光标测 hover 会被真人的手一动就
  失效，静态布局照完剩下的交给用户看。

- **聊天内容是一列同宽（2026-09-21）**：消息、快捷按钮行、重新生成、提问卡、审批条、
  排队条、输入框**统一 `AgentPanel.contentMaxWidth = 960`**（居中）；头部与状态条通栏。
  改宽度只改这一个常量。此前消息列单独 760、输入框通栏，面板拖宽后是"上面窄一列、
  下面铺满"的错位感（用户实测反馈）。
- **弹性尺寸要挂在 VStack 的直接子视图上**（2026-09-21 实测）：Agent 面板里
  `messageScrollView` 的 `.frame(maxHeight: .infinity)` 原本挂在其内部 ScrollView 上，
  而 VStack 的直接子视图是 `ScrollViewReader`——剩余空间于是漏给了下面那条**横向**
  ScrollView（快捷按钮行），把它撑成一大块空白，按钮看起来"悬在面板中间"。改法：
  弹性挂在 reader 上 + 按钮行固定高度。**注意**：给横向 ScrollView 加
  `fixedSize(vertical:)` 会让内容塌成 0 高（整排按钮消失），要用 `.frame(height:)`。
- **Agent 聊天面板的两条铁律（2026-09-21 用户实测反馈后修）**：① **滚动锚点不能
  无条件钉在底部**——`ScrollView` 上的 `.defaultScrollAnchor(.bottom)` 会在**内容长高时
  把视口拽回底部**，流式期间用户根本没法上滑看历史；要按"是否贴底"在 `.bottom` 与
  `.top` 之间切（`isPinnedToBottom` 由 `onScrollGeometryChange` 维护）。②
  **`isProcessing` 必须在"答案流完"时就放掉**：`processLoop` 之后还跑生成标题与记忆
  整理（额外模型调用），此前它们占着 `isProcessing`，用户看到"消息都渲染完了还在流式
  输出"（输入区也一直忙碌）。现在先置 false 再做收尾。排查这类"忙不完"的问题时，
  用桥轮询 `GET /agent/messages` 的 `busy` 与正文长度、看两者是否同时收尾。
- **SwiftUI 里"隔着另一个 store 读嵌套 ObservableObject"不会重绘**（2026-09-21 实测）：
  `AgentModelMenu` 曾只 `@ObservedObject var store: AgentSessionStore`，却读
  `store.preference.model` / `.profiles`——点选后数据变了、界面纹丝不动（用户报
  "切换模型不起作用"）。嵌套的 ObservableObject **不会**自动转发
  `objectWillChange`：要么把那个 store 也 `@ObservedObject`（本次做法），要么在持有
  方 init 里显式 `nested.objectWillChange.sink { self.objectWillChange.send() }`。
  改完顺手用桥验证"数据链路"（`POST /ai/model` → 假端点回显模型名），UI 重绘由用户
  过目——两者是不同的问题。
  **同一条又踩过一次（2026-09-23，成本 chip）**：`AgentHeaderView` 只观察
  `store: AgentSessionStore`，成本却是从 `store.preference.modelPrices` 算的——
  单价改完 chip 一直不出现（截图才看出来）。修法同上：给头部加
  `@ObservedObject var preference: AgentPreferenceStore` 并由面板传入。**判断口径**：
  view 里凡是"读到另一个 store 的字段"，那个 store 就必须是它自己的 `@ObservedObject`
  （或由持有方转发 `objectWillChange`）——`store.a.b` 这种链式读取一律不算依赖。
- **模型配置的单一真相 = `AIProviderProfile`**（2026-09-21 重做）：每个服务自带
  端点、模型、模型清单、额外请求头与**自己的 Keychain 账号**；
  `AgentPreferenceStore.endpoint` / `.model` 只是**当前档案的视图**（providers
  照旧读这两个名字，不用改）。**不要再往 `cloudProviderID` 式的全局字段里加东西**
  ——自定义网关正是被"Key 按 provider id 存"卡住的（4 个预设之外的端点只能共用
  预设的 Key）。老字段（`aiCloudProviderID`/`aiEndpoint`/`aiSavedEndpoints`/
  `ai-api-key`）只在首次迁移时读。改这块时注意：`profiles` 在 init 里赋值不触发
  `didSet`，迁移后要显式 `DiskStore.save`。
- **互相递归的 SwiftUI 视图要类型擦除**（2026-09-21 实测）：Console 的对象 chip
  （`objectChip` ↔ `refDetail`）互相调用，两个都返回 `some View` 时报
  "function opaque return type was inferred as … which defines the opaque type in
  terms of itself"。在递归的那一侧返回 `AnyView` 即可（另一侧保持 `some View`）。
- **Element 的 DOM 树用 nth-child 链当路径（2026-09-21）**：
  `UserScripts/dom-tree.js` 的 `path` 形如 `0/2/1`（"" = `<html>`），**一次只取
  一层**（面板懒展开），每个节点带一个可直接交给 `element-inspect.js` 的
  nth-child 选择器。**不要**改成"整棵树一次取回"：深层页面会撑爆 JSON 与面板。
  树的加载挂在 `.task(id: tab?.id)` 上，所以 `/panel/snapshot`（离屏宿主）里
  树是空的——别据此判"功能坏了"（同 [[desire-testing-env]] 的 .task 坑）。
- **`callAsyncJavaScript` 的字典键 = 包装函数的形参名（2026-09-21 实测）**：
  `arguments:` 的键会成为形参，脚本里再 `const url = arguments[0]` 直接
  `SyntaxError: Cannot declare a const variable twice: 'url'`——这条异常文本
  经 `WKJavaScriptExceptionMessage` 能拿到（`evaluateJavaScript` 拿不到，见下）。
  正解：按名直接用形参（`BrowserToolProvider.callAsync` 就是这个约定：`args`
  的键必须等于页面函数的参数名），或让脚本内声明与键错开。**DevTools 的
  Replay 与图片预览都踩过**：Replay 自 0.3.x 起一直抛语法错（面板里点了没反应），
  2026-09-21 修好并加了 `POST /devtools/replay` 做回归。**没传的键在脚本里根本
  不存在**——直接引用会 `ReferenceError`（`page-storage.js` 的 `scope` 踩过），
  可选参数一律 `typeof x === 'undefined'` 兜底。
- **Cookie 的 SameSite 用公开 API `HTTPCookie.sameSitePolicy?.rawValue`**
  （macOS 10.15+）：**禁止**用 KVC 猜 `_sameSitePolicy` 之类的私有键——
  `value(forKey:)` 遇到不存在的键抛 `NSUnknownKeyException` 直接 abort
  （2026-09-20 崩溃报告）。没显式声明 SameSite 的 Cookie 也会得到 `.none`，
  要区分得看 `properties` 里有没有该键。
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
  **每轮测试开始前必须 curl http://127.0.0.1:8877/ 确认服务器活着**——
  服务器静默死亡会造成"导航失败/无事件/页面空白"的假象（已两次误判为
  app bug）
- **executeJS 错误详情**：evaluateJavaScript 的错误对象不含真实异常
  文本；正确 key 是 `WKJavaScriptExceptionMessage`，经
  callAsyncJavaScript 重跑捕获（见 BrowserToolProvider+Execution）。
- **历史标题**：WebKit 的 title KVO 晚于 didFinish — 历史入库 800ms
  后有延迟校正（HistoryStore.updateEntryTitle），勿删。
- **桌面 UA 是反爬基线**：`BrowserState._desktopSafariUA` 刻意不带
  Desire 产品 token（Cloudflare 按 UA 判非 Genuine Safari 会拦站）。
  修改 UA 逻辑前先读 WebView.swift 内注释。
- **绝不用"原文的 range"去改已经变过的 `AttributedString`**（2026-09-23 崩溃报告）：
  `Range(_:in:)` 只按偏移映射，**不认字符串已被改短**——`MarkdownRendererView`
  曾按 `link → bareURL → code → bold → italic` 顺序在同一个 `AttributedString`
  上做五次 `replaceSubrange`，后一趟拿原文本的 `String.Index` 打上去，碰上多字节
  字符就落在 scalars 中间，`CollectionsInternal/BigString+Chunk+UnicodeScalar.swift`
  断言 + SIGTRAP。**正确姿势：先按原文本收集片段（span），排序后一次性拼接**，
  全程只对原文切片、不产生失效索引。最小复现（同一函数、`-Onone`）：
  `[a](b)**粗***斜体*`（纯 ASCII 的 `[](u)**a***b*` 不复现——需要多字节参与）。
  注意这类崩溃常发生在**流式的中间状态**，已落盘的消息文本往往复现不出来：
  按崩溃栈定位，别因为"历史消息跑不出崩溃"就否定修复。
- **循环必须"结构性推进"，入口条件和循环条件要用同一个字符串**（2026-09-23，和上面
  那条崩溃一起查出来的第二个 bug）：`MarkdownParser` 的有序列表分支入口看原始行
  （`line.contains(". ")`）、内层循环看 trim 后的行，于是 `"1. "` 能进循环但一个分支
  都不匹配 → `break` 出去而 `i` 没动 → 外层 `continue` 回到同一行 → **死循环**。修法：
  ① 两处条件统一（用 trim 后的行）；② 循环顶部 `defer { if i == iterationStart { i += 1 } }`
  兜底，任何分支忘了推进都会被补上。**这类输入的触发面几乎总在流式中间态**（模型写
  有序列表时就是 `"1. "`），350 条历史消息全跑也不复现。
- **`.task(id:)` 的取消不会传给 `Task.detached`**：Markdown 解析放在 detached 任务里，
  文本一变化只取消外层 task，旧解析会继续空转到底（死循环时就是**永久泄漏一个满核
  任务**）。要显式转发：持有 `Task.detached` 的句柄，用 `withTaskCancellationHandler`
  在 `onCancel` 里 `work.cancel()`，解析循环里再查 `isCancelled`。
- **`ForEach(x.indices, id: \.self)` + `x[i]` 是越界形态**：流式渲染里数量会**减少**
  （围栏一开吞掉后面几块、列表合并、附件被删），下标当 id 时 SwiftUI 可能在缩容那次
  更新里拿旧下标取新数组 → `Index out of range`。一律用
  `ForEach(Array(x.enumerated()), id: \.offset)` 只碰快照值。同理**流式尾部写回要按
  message id 找回**（`firstIndex(where: { $0.id == msg.id })`），别用 append 时记下的
  下标——会话中途被清空/切换时它会指向别的消息。

- **视频下载：装了 ffmpeg 就用它直连 HLS → MP4**（2026-09-23，用户提议后落地）：
  `MediaExporter.download` 的判定顺序 = **VOD HLS + 有 ffmpeg → `FFmpegExporter`
  直连**；否则回退内置下载器（原行为），内置出 `.ts` 且机器有 ffmpeg 时再转封装。
  实测定下的几条（改这块之前先读，都是踩过的）：
  - **必须把 master 播放列表交给 ffmpeg**，不能只给 variant URL：音轨分离
    （`EXT-X-MEDIA`）的站点媒体播放列表里只有视频，给 variant 会**丢音轨**
    （内置下载器一直有这个缺陷）。`-map 0:p:N` 的 N 是 variant 的**文件顺序**
    下标（= program 号），不是按码率排序后的下标——`listVariants` 的 `index` 字段
    就是干这个的。
  - **`-map` 是输出选项**，要排在 `-i` 之后；放前面 ffmpeg 直接拒收（退出码 234）。
  - **`-extension_picky`（ffmpeg ≥7.1 默认开）会拒收异形分片**：没有 `.m3u8` 后缀
    的播放列表、`.bin` 分片、无扩展名分片全都被挡。要
    `-f hls -allowed_segment_extensions ALL -extension_picky 0`；老版本不认这些
    选项（报 "Unrecognized option"）→ 退回只给 `-f hls` 重试一次。
  - **live 播放列表（无 `EXT-X-ENDLIST`）绝不能交给 ffmpeg**：它会一直等新分片，
    `-t` 拦不住（实测 40s 不退出）。live 走内置下载器（有"导出当前可用分片"的
    既有语义），再由 ffmpeg 转封装成 mp4。
  - 防盗链用 **`-referer` / `-user_agent`**（`-headers` 里写字面 `\r\n` 会被当成
    表头值的一部分传上去）；取消用 SIGTERM（实测立即退出、不留残件）；进度读
    `-progress pipe:1` 的 `out_time_us`（注意 `out_time_ms` 也是微秒，是 ffmpeg
    的笔误），百分比靠播放列表 `EXTINF` 之和换算。
  - **不内置 ffmpeg**（GPL/LGPL 的独立项目 + 体积），只探测
    `/opt/homebrew/bin`、`/usr/local/bin`、`/opt/local/bin`、`/usr/bin`——GUI 进程
    PATH 里没有 Homebrew（同 `SystemCommandStore.searchPaths`）。
  - E2E 全在应用内跑：桥 `POST /media/download {"url":…,"filename":…,"maxBandwidth":…}`
    （注意字段名是 `filename`），产物用 `ffprobe` 核对容器/流/分辨率；本地 HLS
    fixture 用 ffmpeg 自己切（`-hls_time 2 -hls_playlist_type vod`，要 `-g 50` 才有
    2 秒切片），音轨分离用 `#EXT-X-MEDIA:TYPE=AUDIO` + `AUDIO="grp"` 手写 master。

- **NSViewRepresentable 里"自己引发的回调"同样在更新事务内**（2026-09-23，地址栏聚焦时
  实测一次三条警告）：`updateNSView` 里同步 `stringValue` 会**同步**回调
  `controlTextDidChange`，`becomeFirstResponder()` 会**同步**回调 `controlTextDidBeginEditing`
  ——两者都在 SwiftUI 的更新事务里，于是 `@State` 写入与 `@Published` 发布分别报
  "Modifying state during view update" / "Publishing changes from within view updates"。
  两把对症工具：① **自己引发的变化用标志挡掉**（同步前后置位 `isSyncingFromSwiftUI`，
  回调里提前 return——它本来也不该重建候选）；② **系统发的通知跳一帧**
  （`Task { @MainActor in … }`）。别把①用在②上（会吞掉状态更新），也别用②去掩盖①。
- **视图回调里不许直接改 store：`.onKeyPress` 尤其**（2026-09-23，用户贴出的
  "Publishing changes from within view updates" 警告）：SwiftUI 的 `.onKeyPress`
  处理器在**更新事务内**执行，同步调 `store.sendMessage()` / `cancel()` 会让每一条
  `@Published` 写入都报这个警告（用户实测：**一次回车刷出 59 条**，全在同一线程、
  同一 activity、36ms 的突发里）。凡是从这类回调触发的 store 写都要跳一帧：
  `Task { @MainActor in … }`。已修：`AgentInputBar` 的回车提交、`AgentPanel` 的
  ⌘↩/Esc、语音结束后的自动发送。**注意别再"顺手"去改这些**：实测
  `.onReceive(CommandBus.shared.publisher)`（菜单/桥命令）与
  `.onChange(…, initial: true)`（DevTools 面板写 store）都**不**触发这个警告，
  没有证据就别动。
- **排查 SwiftUI 运行时警告看统一日志**（这些警告也确实会进日志，不必开着 Xcode）：
  `/usr/bin/log show --last 10m --info --debug --predicate 'subsystem == "com.apple.runtime-issues"' --style json`。
  记录里带 `threadID` / `activityIdentifier` / `backtrace`（frames 只有 imageUUID +
  imageOffset）——**按突发聚类**（本次 59 条挤在 36ms 内 = 一个动作里连环发布，不是
  用户点了 59 次），再和同一时刻 app 的其他日志对照：本次紧跟在
  `com.apple.inputAnalytics.client … LegacyTextInputActions signal:DidAction`（键盘输入）
  之后、`SecItemCopyMatching` + MCP 连接（回合启动）之前 → 一目了然是"回车发送"。
  注意：**附带的 backtrace 全是系统框架帧**（发布点在 SwiftUI 内部），别指望靠它定位。
- **视图 body 里不许读 Keychain**：`SecItemCopyMatching` 是阻塞的系统调用，Xcode 的
  Performance Diagnostics 会报 "This method should not be called on the main thread
  as it may lead to UI unresponsiveness"。设置页的服务档案行曾在**每次重绘读两次**
  （同一个 `StatusPill` 的两个分支各一次），已改为一次；新增需要"有没有 Key"的地方
  优先用 store 里发布好的 `hasAPIKey`，别在 body 里现读。

- **系统提示词是分层拼的，别在身份段里手写工具清单**（2026-09-23）：
  `AgentPromptBuilder.compose` 依次拼 `<identity>`（用户在设置里可编辑的提示词，默认值
  `AgentPreferenceStore.defaultPrompt`）→ `<user_memory>` → `<skills>` → **`<tools>`（生成）**
  → `<environment>` → `<page_context>`，合成**一条** system 消息插在请求第 0 位
  （调用点 `AgentSessionStore.buildRequestMessages`；子代理走另一处，用它自己的工具子集）。
  实测教训：默认提示词里手写的"可用工具速查"只有 30 个而实际有 **106** 个（缺
  `executeJS`/`switchTab`/`goBack`/`readTab`/`getNetworkLog`/`crewDispatch`…）——工具索引必须
  **从 `BrowserToolProvider.toolDefs` 生成**（`promptInventory(for:)`），手写的一定会漂移；
  新增工具只要写进 `toolDefs`，提示词自动跟上。
- **验证组装后的系统提示词：假 OpenAI 端点抓请求体**（可复用）：起一个 python SSE 服务，
  `POST /ai/profiles {"id":…,"endpoint":"http://127.0.0.1:8899/v1/chat/completions","model":"x"}`
  把某个 profile 临时指过去（**先记下原值，验完立刻还原并核对**）→ 开面板 +
  `POST /agent/send` 发一句话 → 服务端把请求体落盘。可断言：`tools` 参数条数 == `<tools>`
  索引行数（零差异）、对话里 system 只有 1 条且在第 0 位、六个分层段落齐全、`<environment>`
  带出工作目录/下载目录/ffmpeg 状态。注意一次发送会来 **3 个请求**（正文、标题生成、收尾），
  按体积挑最大的那个。
- **CHANGELOG 的 `[Unreleased]` 会被发版改名**：`0.x.y: release —` 那一步把 `[Unreleased]`
  直接改成 `## [vX.Y.Z] - 日期`。发版**之后**的改动必须**另起**一段 `[Unreleased]`，不要
  接着往已发布的段里加（2026-09-23 踩：流式跟随的修复条目落进了已发布的 v0.3.12 段，而
  GitHub 上那版 release 正文是发版当时生成的、并不包含它 → 两边不一致）。

- **SwiftUI 的 `.onKeyPress` 在 macOS `TextField` 上能收到方向键**（2026-09-23 最小宿主
  实测；当时要确认"新标签页搜索框接 ↑/↓ 到底能不能收到"）。宿主 = 一个 TextField +
  `.onKeyPress(.upArrow/.downArrow)`，用 `CGEvent.postToPid` 注入按键，宿主里打出
  "UP fired"/"DOWN fired" —— 所以方向键**不会**被字段编辑器先吃掉，可以放心用它做
  列表选择。两个配套要点：
  ① **`@FocusState` 在 `onAppear` 里直接置真往往不生效**，要 `Task` 里延迟 ~400ms 再置
  （宿主与 Agent 面板都踩过；不聚焦的话注入的按键会被窗口丢弃，看起来像"注入失败"）；
  ② 键盘事件用 `postToPid` 注入是可靠的（鼠标事件才需要处理坐标/翻转），
  `CGEventSource(stateID: .combinedSessionState)` + 按下/抬起各一发即可。
- **地址栏没有候选下拉，别在那里处理 ↑/↓**：`Toolbar` 的 URL 输入框只把 `suggestionModel`
  用于"回车打开第 0 行"，列表视图只挂在新标签页的搜索框上（`AddressSuggestionsView`）。
  在那里接方向键会移动一个看不见的高亮 → 回车打开看不见的条目（2026-09-23 修掉）。
  要给地址栏也加下拉，得先把列表视图挂到工具栏上。

- **可观测性：轨迹是"派生"的，不是另存的一份**（2026-09-23）：`AgentTrace` 把会话编译成
  一行一个回合的 JSONL（`GET /agent/trace` ✓），字段含 goal / steps（动作、参数、观察、
  耗时、`denied`/`threwError`）/ answer / critique / verificationNote / **用户 👍👎**。
  **唯一无法派生的字段是工具耗时**——所以它记在**工具消息**上（`toolDurationMs` ✓）随会话
  落盘，这样历史回合导出也带耗时 ✓。失败标记只认应用自己写的两种（拒绝执行、JS 异常
  `Error:`），与机械核验同一口径——**普通工具失败没有统一约定，别用关键词猜**（会误报，
  实测 `executeJS` 参数写错时返回的是 `Missing code` ✗ 不是 `Error:`）。
  新加"以后要分析"的字段时照这个模式：能从消息派生就别新增状态；实在派生不出来（如耗时）
  就挂在消息上随会话落盘。**轨迹读的是盘上的会话**（`ConversationStore()`），所以它同时是
  "落盘完整性"的探针：`answer` 空 = 那条回答没落盘（见下面两条）。

- **成本 = "用户填的单价 × 消息上的 token"，没有内置价格表**（2026-09-23）：单价存
  `AgentPreferenceStore.modelPrices`（`模型 id → {input, output}`，美元/百万 token；桥
  `GET|POST /ai/prices`），**精确匹配、绝不做前缀**（`gpt-4o` 会顺手套到 `gpt-4o-mini`
  头上，差 10 倍）。三条诚实性规矩：① 没填单价 → 只显示 token，**不显示 `$0`**（会被读成
  "免费"）；② 一段对话里只要有一笔没定价，总额就不给（改标 `≥`）；③ 比 4 位小数还小的非零
  值写 `< $0.0001`。算法只有一处：`AgentUsage.of(messages, price: preference.usagePrice(for:))`
  ——**面板状态行、轨迹页、桥端点都走它**，否则同一个数会出现两个版本。
  token 与模型记在**消息**上（`promptTokens` / `completionTokens` / `model`；`model` 优先取
  响应里的，网关会路由/改写，成本得按真跑的那个算）——这是第二处"派生不出来就挂消息上"的
  字段（第一处是 `toolDurationMs`），所以历史会话也能重新定价重算。**子代理的用量由主循环
  认领到 `spawnSubagent` 的工具消息上**（它跑在自己的消息数组里，不认领就少报）；已知缺口：
  **多标签 crew / 自评 critic / 标题 / 记忆整理这些旁路调用不计入对话成本**。改这块时注意
  视图侧的观察依赖（见"隔着 store 读嵌套 ObservableObject"那条，2026-09-23 又踩一次）。

- **使用统计页与 `GET /agent/stats` 同源**（2026-09-23，用户："token 统计面板也要加"）：
  `UsageStats.derive(from: conversationStore.conversations, price:)` 从**已存盘的会话**派生出
  累计/峰值/最长对话/连续天数、逐日（含分模型）与分模型累计；页面（`AgentStatsView`）与桥端点
  都调它，禁止在视图里另算一套，否则同一屏会出现两个数。两条前提**必须留在页脚**：只有服务端
  上报过用量的调用才计入；**该功能上线前的历史对话一律为 0**（用户既有对话实测就是 0，
  不说清会被当成 bug）。没有模型归属的用量进 `UsageStats.subagentModelKey`（界面上写"子代理"）。
  金额沿用下面"成本"那条规矩：有一笔没定价就不给总额。
  页面用 Swift Charts（折线/环形）+ 手搓格子热力图；**配色必须显式给**
  `.chartForegroundStyleScale(domain:range:)`，否则 Charts 的自动配色会和列表里自己画的
  圆点对不上。热力图格子**固定宽度、按可用宽度决定显示多少周**（面板可拖拽，格子跟着变会一直抖）。

- **面板里的仪表盘要"按宽度换档"，而不是自适应拉伸**（2026-09-23 统计页第二轮）：
  面板宽度从 380 到 2000pt 以上都可能（用户会拖），三种做法配套用：
  ① **内容限宽居中**（`AgentStatsView.contentMaxWidth = 1100`）——限宽后再 `.frame(maxWidth:
  .infinity, alignment: .center)`；不限宽的话"最多 53 周"的热力图在 2000pt 下右边会空一大半；
  ② **离散内容换档**：`ViewThatFits(in: .horizontal)` 列几档固定尺寸的内容（头条指标条 =
  列数 6/4/3/2），**每档要 `.fixedSize()`** 让理想宽度等于真实宽度，它才能按宽度挑；
  ③ **连续内容要"量宽度现算"**：档位表对"能拉伸的元素"是错的——档与档之间必然留空
  （热力图 700pt 面板挑中 34 周 @13pt=508pt，右边空 136pt，用户一眼就看出来了）。
  做法：`GeometryReader { Color.clear.preference(键, value: geo.size.width) }` 挂在
  `.background` 上 + `.onPreferenceChange` 回写 `@State`，**下一次布局**再按这个宽度
  现算格子边长（`(宽 - 间隙)/列数` → 正好铺满）；高度自然由内容决定，所以**不要**用
  `GeometryReader` 直接包内容（拿不到内容高度）。注意这条链路要**两次布局**：
  **桥的离屏快照必须在 `cacheDisplay` 前转一小段 runloop**，否则拍到的是"量之前"那版
  （已在 `agentStatsSnapshot` 里处理）。
  圆形/圆角这类随尺寸变的装饰也跟着算：热力图圆角 = `min(5, max(2, 边长 × 0.24))`。
  另外两条与图表有关：`chartForegroundStyleScale(domain:range:)` 的 domain **只放画出来的
  序列**（放全量会让图例多出没画线的模型）；列表类内容在宽面板下**要铺满**（名字靠左、
  百分比靠右），限个 420pt 宽再留白会长出一块空洞。

- **离屏渲染（`/panel/snapshot`）要拍得出来，数据就得在 `init` 里备好**（2026-09-23）：
  离屏 `NSHostingView` **不触发 `onAppear`/`.task`**（无窗口即无 appear），所以"在 onAppear 里
  加载"的页面快照出来是空的——看着像功能坏了。把初始状态放进 init
  （`_stats = State(initialValue: UsageStats.derive(...))`）既让快照可拍，也顺带去掉了真实
  使用中的首帧空闪。新增快照支持：`GET /panel/snapshot?name=agentstats&w=&h=`（尺寸可指定——
  **窄面板是最容易挤坏的情况**，380/420/900 各拍一张再交付）。快照三坑（浅色外观、透明背景、
  缺 `.appAccent`）照旧见 [[desire-devtools-panel]] 那条。

- **回合收尾必须落盘（`runTurn` 的每个 `return` 都要有人保存）**（2026-09-23）：`runTurn`
  有 4 条退出路径（最终回答 / 报错 / 迭代上限 / 取消），"最终回答"那条是
  `guard … else { return }` **裸返回**——保存只挂在别的分支上，于是**回答只活在内存里**，
  直到用户再发一条消息才被顺带写下。症状：会话文件缺最后一条回答、轨迹 `answer` 永远为空、
  强杀即丢。现在由 `processLoop` 在回合序列结束后**无条件保存一次**兜底 ✓。
  两条配套规矩：① 新增任何"回合收尾"步骤（写字段、生成标题、记忆整理）都要确认之后有人
  落盘；② **改写正文的收尾（脱敏）必须排在保存之前**——标题生成/记忆整理是额外模型调用
  （几秒），先保存的话带原文的回答会在这段时间里躺在会话文件里。

- **ObjC 异常穿进 Swift async 帧会把主 actor 变成"僵尸"——必须避免陈旧 NSRange**
  （2026-09-23，本日**第二例**同类 bug）：`NSRegularExpression` 的 `firstMatch(in:range:)`
  拿到**越界**的 range 会抛 `NSRangeException`；这个 ObjC 异常沿 Swift async 帧上行时被
  HIServices 吞掉，**主 actor 的执行器就此损坏**：此后所有 `@MainActor` 任务只是排队、
  永不执行。表现极具迷惑性——**窗口照常渲染、事件循环照常、`osascript quit` 还能优雅退出，
  但桥端点全部无响应、数据文件停摆、没有任何崩溃报告**。踩法与规矩：
  - 踩法（`SecretRedactor`）：range 在循环**外**算一次，循环里却改写文本
    （`[redacted]` 比任何命中都短 → 串必然变短），下一轮就带着旧长度越界。
  - 规矩：**任何 NSRange 都现算现用，绝不跨"可能改写字符串"的调用缓存**；
    同理适用于 `AttributedString` 的失效索引（同日第一例，`MarkdownRendererView`）。
    复现很快：独立脚本喂两段命中文本，旧写法报
    `NSRangeException: … Range or index out of bounds`。
  - **诊断手法（可复用）**：① `/usr/bin/log show --last 30m --debug --predicate 'process == "Desire"'`
    里搜 `NSRangeException`——抛出点带着 Swift 堆栈（本次直接指到 `SecretRedactor.redact`
    被 `AgentSessionStore.runTurn` 调用）；② `sample <pid> 3` 看主线程——**空闲在 run loop**
    而不是卡在业务代码里；③ lldb 投一个主 actor 探针
    （`expr -l swift -- Task { @MainActor in NSLog("DSP-PING") }`）——返回里
    `flags:suspended|enqueued` 而日志里始终没有 PING = 执行器已死；④ 别被"界面正常"骗了：
    僵尸态与"卡死"的区别就在这里，**它还能优雅退出**。

## 端点扩展模式

新自动化能力 = AutomationServer.route 加 case + 一个 static 实现，
数据源用 `TabSessionCoordinator.shared.activeTabManager`（活动窗口）
或 `AgentScheduler.shared.deliveryTarget`（活 Agent 会话）/ 各 Store
的 `.live` 弱注册（如 DownloadStore.live）。读写分离：查询用新实例
读盘即可，写操作必须走 UI 持有的同一实例。
