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

### 文件颗粒度规则

1. **一个文件 = 一个类型**。Model 文件只含一个 struct/enum；Store 文件只含一个 class；View 文件只含一个主 View。
2. **例外**：仅供同一 View 使用的私有子视图（如 `EntryRow`），可以放在同一文件内。
3. **跨 Feature 复用的 UI 组件** 放 `Views/SharedUI.swift`。
4. **禁止**在 Store 文件里定义 Model（拆开）。
5. **禁止**在 View 文件里定义业务逻辑（持久化、数据处理放 Store）。

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
3. 在 `Views/ContentView.swift` 中组合
4. Build 验证
```
