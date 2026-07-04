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
│   ├── AddressBar/
│   └── AI/                     # 预留
├── Views/                      # 跨功能共享 UI 组件
│   ├── ContentView.swift       # 主视图（组合各 Feature）
│   └── SharedUI.swift          # 通用 UI 组件
└── Assets.xcassets
```

### 三层分离规则

每个 Feature 目录内严格按三层分离：

| 层 | 文件命名 | 职责 | import 规则 |
|----|---------|------|------------|
| **Model** | `Xxx.swift` | 纯数据结构（struct/enum），Codable/Identifiable，无任何逻辑 | 只 import Foundation |
| **Store** | `XxxStore.swift` | `@MainActor class: ObservableObject`，持有 `@Published` 状态，持久化（UserDefaults/JSON），业务逻辑 | Combine + Foundation（+ 按需 WebKit 等） |
| **View** | `XxxView.swift` 或 `XxxPanel.swift` | `struct: View`，纯渲染，通过 Store 方法驱动数据，零业务逻辑 | SwiftUI（+ 按需 AppKit 等） |

### UI 组件分类与组织

View 层再细分为**组件（Component）**和**页面/面板（Panel/Page）**，按层级管理：

| 类型 | 定义 | 命名后缀 | 示例 | 位置 |
|------|------|---------|------|------|
| **Primitive** | 单一用途的基础 UI 元素，无状态或纯本地状态 | `XxxButton` / `XxxField` / `XxxRow` / `XxxIndicator` | `CapsuleButton`、`EntryRow` | `Views/Components/` |
| **Composite** | 由多个 Primitive 组合而成，有特定功能，可跨标签页复用 | `XxxBar` / `XxxGroup` | `TabBar`、`AddressBar`、`FindBar`、`NavButtonGroup` | 所属 `Feature/` 内 |
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
│   └── EmptyState.swift           # 空状态占位

Features/
├── Browsing/                      # Browsing 特有的 Composite 组件
│   ├── TabBar.swift               # 标签栏
│   ├── Toolbar.swift              # 导航工具栏
│   ├── AddressBar.swift           # 地址栏（锁图标 + TextField）
│   ├── FindBar.swift              # 查找栏
│   ├── NewTabPage.swift           # 新标签页
│   ├── TabManager.swift           # Store
│   └── WebView.swift              # WKWebView 封装
├── Bookmarks/
│   ├── Bookmark.swift             # Model
│   ├── BookmarkStore.swift        # Store
│   └── BookmarkPanel.swift        # Panel
```

### 组件抽取规则

1. **被 2 个以上 Feature 使用** → 提取到 `Views/Components/`，去掉所有业务依赖。
2. **只被一个 Feature 使用但 >50 行** → 提取为独立文件放该 Feature 目录内。
3. **只被一个 Feature 使用且 <50 行** → 作为私有子视图（`private struct`）放在使用它的 View 文件底部。
4. **ContentView 是组合根**，只负责拼装 Composite，不放任何 UI 渲染逻辑。

### 组件设计原则

1. **Props in, Callbacks out**：组件通过构造参数接收数据，通过闭包回调事件，**不直接持有 Store**（Panel 例外，Panel 可以持有 `@ObservedObject Store`）。
2. **无副作用**：Primitive 和 Composite 不做持久化、不发网络请求。
3. **可预览**：每个 Component 加 `#Preview` 方便 Xcode 预览。
4. **Style 一致**：胶囊形状统一用 `Capsule()`，圆角统一用 `RoundedRectangle(cornerRadius: 6)`，不要各写各的。

### 文件颗粒度规则

1. **一个文件 = 一个类型**。Model 文件只含一个 struct/enum；Store 文件只含一个 class；View/Component 文件只含一个主类型。
2. **例外**：仅供同一 View 使用的私有子视图（`private struct`），可以放在同一文件内。
3. **禁止**在 Store 文件里定义 Model（拆开）。
4. **禁止**在 View 文件里定义业务逻辑（持久化、数据处理放 Store）。

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
```
