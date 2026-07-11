# Desire — 技术架构蓝图与演进路线

> 状态：v1.0 · 已通过 `xcodebuild build` 验证
> 日期：2026-07-11
> 范围：对当前代码库的结构化分析 + 目标架构 + 分阶段演进路线

---

## 一、项目现状速览（已验证）

| 维度 | 数据 |
|---|---|
| 类型 | 原生 macOS 浏览器（非 iOS），基于 SwiftUI + WebKit |
| 规模 | **135 个 Swift 文件 / ~21,868 行** |
| 最低系统 | macOS 26.5（Tahoe），Xcode 26.6，Swift 5.0 |
| 并发模型 | `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `SWIFT_APPROACHABLE_CONCURRENCY = YES`（严格并发检查） |
| 模块依赖 | **零第三方依赖**（无 SPM、无 test target、无 package） |
| 安全 | App Sandbox（network.client/server）+ Hardened Runtime + `files.downloads/pictures/user-selected.read-write` |
| 构建 | ✅ `xcodebuild build` 通过（仅有少量 deprecation/风格警告） |
| Bundle ID | `me.siwi.Desire`（Team `F8JZTX6J52`，自动签名） |

---

## 二、分层架构现状

代码已严格执行 `AGENTS.md` 约定的 **Model → Store → View** 三层分离，加上 **Composition Root**。

```
┌─────────────────────────────────────────────────────────────┐
│  DesireApp (App/DesireApp.swift)                            │  入口 + Scene + 菜单命令
│    └─ AppState (App/AppState.swift)                         │  全局 Store 容器（懒加载）
└──────────────────────────────┬──────────────────────────────┘
                               │ environmentObject
┌──────────────────────────────▼──────────────────────────────┐
│  ContentView (Views/ContentView.swift, 1135 行 ★组合根)      │  拼装所有 Composite + 路由
│    ├─ TabBar / Toolbar / FindBar / Sidebar / WebView        │
│    ├─ 各种 Panel（History/Bookmark/Download/Plugins/...）    │
│    └─ AIPanel / DevToolsPanel / ResponsiveDesignBar         │
└──────────────────────────────┬──────────────────────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        ▼                      ▼                      ▼
   Features (30+)        Views/Components         Assets
   每个 Feature 内三层：     Primitive 共享组件
   Model/Store/View
```

### Feature 清单（按成熟度分级）

| 层级 | Feature | 核心文件 |
|---|---|---|
| **🟢 核心（成熟）** | Browsing | `WebView.swift`(981)、`BrowserWKWebView.swift`、`TabManager.swift` |
|  | Tabs | `TabBar.swift`(522)、`TabManager`、`TabThumbnailStore`、`TabPreviewPanel` |
|  | Toolbar / AddressBar | `Toolbar.swift`(424)、`AddressSuggestionsModel`、`FaviconStore` |
|  | Bookmarks | `Bookmark` / `BookmarkStore` / `BookmarkPanel` + 导入导出 |
|  | History | `HistoryEntry` / `HistoryStore` / `HistoryPanel` |
|  | Downloads | `DownloadStore`(516) / `DownloadPanel`（WKDownload KVO） |
|  | Settings | `SettingsStore` + 8 个子设置（外观/隐私/Cookie/权限/站点/快捷键…） |
| **🟡 增强（可用）** | AI Assistant | `AIService`(OpenAI 兼容流式)、`BrowserToolProvider`(48 工具)、`AISessionStore`、`ConversationStore` |
|  | ContentBlocking | `ContentBlocker`（80+ 规则 WKContentRuleList） |
|  | VideoAdBlocking | `VideoAdBlocker`(959 行，YouTube/Bilibili/Tencent) |
|  | ElementBlocking | `ElementBlockStore` + CSS/XPath 注入 |
|  | PrivacyMode | `PrivacyModeStore`（Cookie/WebRTC/追踪） |
|  | Password | Keychain + JS 自动填充检测 |
|  | FormAutofill | Profile-based JS 注入 |
|  | Reader / ReadingList | 阅读模式 + 稍后读 |
|  | DevTools | Console / Network / Element Inspector |
|  | ResponsiveDesign | 10 文件（设备框/标尺/触屏模拟/MediaQuery） |
|  | Screenshot | 5 文件（截屏 + 标注 + 区域选择） |
|  | Translation | `TranslationService` + `TranslateBar` |
|  | NewTab | `NewTabPage` + `QuickDialStore` |
|  | Sidebar / TabGroups / SearchHistory / HTTPSUpgrade / FindInPage |  |
| **🔵 扩展（雏形）** | Extensions | Safari 扩展导入 + 内容脚本注入（chrome.* API 是 stub） |
|  | UserScripts | 用户脚本插件系统 |
|  | Performance | 内存压力监控 + 缓存清理 |
|  | AI/Components | 9 个子组件（InputBar/Bubble/History/QuickActionBar…） |

---

## 三、关键技术决策与现状评估

### ✅ 做得好的地方

1. **严格的 Feature 模块化 + 三层分离** — 30 个 Feature 目录边界清晰，`AGENTS.md` 有强制规范。
2. **MainActor 默认隔离 + 严格并发** — 对浏览器这种 UI 密集 + 异步多的应用是正确选择，规避了大量 data race。
3. **零依赖** — 启动快、供应链简单、Hardened Runtime 友好。
4. **真实的 Safari UA 策略**（`WebView.swift:277-303`）— 诚实标注 `Desire/0.1`，规避 Cloudflare 误判，工程判断成熟。
5. **WKWebView 封装遵循 NSViewRepresentable 例外规则** — `BrowserWKWebView` + `BrowserState` + `WebView` + `Coordinator` 同文件，紧耦合合理。
6. **AI 工具系统已成型** — `BrowserToolProvider` 暴露 48 个工具（页面读取/导航/标签/书签/历史/DOM 操作/PDF/截屏/JS 执行），这是 AI 浏览器的**核心护城河**。

### ⚠️ 架构债与风险（按优先级）

| # | 问题 | 证据 | 影响 |
|---|---|---|---|
| **A1** | **ContentView 组合根臃肿**（1135 行） | `Views/ContentView.swift` 含 ~40 个 `@State`、大量业务闭包内联 | 可维护性下降，违反"零业务逻辑"约定 |
| **A2** | **JS 注入与 Swift 强耦合** | `WebView.swift` 内联 12 段 JS（password/reader/audio/console/hover/picker），`BrowserToolProvider` 内联 ~30 段 | 难测试、难复用、易注入 |
| **A3** | **无 Test Target** | `xcodebuild` 无 test，AGENTS.md 明确"no test targets" | 回归风险随 Feature 增长指数上升 |
| **A4** | **持久化全用 UserDefaults + JSON** | `BookmarkStore`/`HistoryStore`/`TabManager.persistSession` 等 | 数据量大后性能/可靠性问题（标签 session、历史、书签都挤 UserDefaults） |
| **A5** | **AI Agent 循环硬编码 20 轮上限** | `AISessionStore.processLoop() for _ in 0..<20` | 复杂任务被截断；无中断恢复；无工具调用审批 |
| **A6** | **Safari 扩展 chrome.* API 是 stub** | `SafariExtensionManager.generateWebExtensionsAPI` | 真实扩展不可用 |
| **A7** | **多窗口支持缺失** | `DesireApp` 只有一个 `WindowGroup`，`BrowserCommand.newWindow` 路由未落地 | 与"浏览器"核心预期不符 |
| **A8** | **Assistant Model 写死 Settings class 名** | `Features/Settings/Settings.swift:命名保留非 Store 后缀` | 命名混乱，新人难辨 |
| **A9** | **JS 字符串拼接存在 XSS/注入面** | `BrowserToolProvider.click/fill` 用 `sel.jsEscaped` 单引号转义 | 处理边缘 case 有逃逸风险，应改模板/参数化 |
| **A10** | **无崩溃/遥测/日志系统** | 全靠 `print(#if DEBUG)` | 生产可观测性为零 |

---

## 四、目标架构蓝图（To-Be）

```
┌──────────────────────────────────────────────────────────────────────┐
│                        Application Layer                             │
│  DesireApp ─ WindowSceneCoordinator (多窗口) ─ CommandBus            │
└───────────────────────────────┬──────────────────────────────────────┘
                                │
┌───────────────────────────────▼──────────────────────────────────────┐
│                     Composition / Shell Layer                        │
│   BrowserWindow  (≈ 当前 ContentView 瘦身后)                          │
│   ├─ TabStripRegion  ├─ ToolbarRegion  ├─ SidebarRegion              │
│   └─ ContentRegion (WebViewHost | NewTabPage | PanelsRouter)         │
└───────────────────────────────┬──────────────────────────────────────┘
                                │ 依赖注入
┌───────────────────────────────▼──────────────────────────────────────┐
│                        Feature Modules                               │
│  每个模块：  Model (Codable)  │  Store (ObservableObject)  │  View    │
│ ┌──────────┬───────────┬───────────┬───────────┬───────────────────┐ │
│ │ Browsing │  Tabs     │  Privacy  │   AI      │   ...             │ │
│ │ Engine   │  Engine   │  Engine   │  Agent    │                   │ │
│ └──────────┴───────────┴───────────┴───────────┴───────────────────┘ │
└───────────────────────────────┬──────────────────────────────────────┘
                                │
┌───────────────────────────────▼──────────────────────────────────────┐
│                       Platform / Core Services                       │
│ ┌─────────────┬──────────────┬──────────────┬────────────────────┐  │
│ │ WebEngine   │ Storage      │ AgentRuntime │ Telemetry/Logger   │  │
│ │ (WKWebView  │ (CoreData +  │ (Tool Bus +  │ (OSLog + crash     │  │
│ │  封装 + JS  │  Keychain +  │  审批 + 沙盒) │  reporter)         │  │
│ │  Bridge)    │  文件)       │              │                    │  │
│ └─────────────┴──────────────┴──────────────┴────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

### 核心抽象（新增）

1. **`WebEngine`** — 把 `BrowserWKWebView + BrowserState + Coordinator + JS Bridge` 收敛为统一接口：`load/navigate/eval/extract/screenshot/onEvent`。所有 JS 资源移到 `UserScripts/` 的 `.js` bundle 资源，运行时加载。
2. **`AgentRuntime`** — 把 `AIService + BrowserToolProvider + AISessionStore` 的 agent 循环抽象成可插拔 runtime：支持工具白名单、人在回路审批（human-in-the-loop）、断点续跑、多模型路由。
3. **`Storage` 层** — Core Data（历史/会话/书签索引）+ Keychain（凭证/AI Key）+ App Support JSON（设置）。UserDefaults 只留少量偏好。
4. **`CommandBus`** — 用类型安全的 `enum` + `AsyncStream` 替代当前 `NotificationCenter.post(.browserCommand)`，消除字符串路由。
5. **`WindowSceneCoordinator`** — 真正的多窗口，每窗口一个独立 `TabManager`。

---

## 五、演进路线（Roadmap）

> **决策已定**：三线并行 · 允许引入必要依赖 · AI 全模型策略（云端兼容 + Foundation Models + 多路由 + Ollama 自托管）

### 并行三条线的切分与依赖关系

```
        阶段 0 (W1-3)          阶段 1 (W4-8)          阶段 2 (W7-14)
        ────────────           ────────────           ──────────────
L1 工程 │ Test+CI/OSLog        │ Storage 迁移          │ 插件 SDK
  化    │ ContentView 拆分     │ WebEngine 抽象        │
        │ CommandBus          │                       │
        │ JS 资源化 ──────────┼───────────────────────┼──▶ 解锁 AI 工具沙盒
                            │                       │
L2 核心 │                      │ 多窗口落地            │ 容器标签/代理
  引擎  │                      │ JS Bridge 参数化      │ WebExtensions MV3
        │                      │ 下载可靠性            │
                                                    │
L3 AI   │ AgentRuntime 抽象    │ 人在回路 + 工具分级   │ MCP 客户端 + 长任务
  差异  │ ModelRouter 接口     │ Foundation Models     │ 页面 RAG + 任务回放
  化    │ (云端兼容现状)       │ Ollama 接入           │
```

**关键交叉点**（必须按顺序）：
- **JS 资源化（L1-W2）→ JS Bridge 参数化（L2-W5）→ AI 工具沙盒（L3-W7）**：这条链是 AI agent 安全调用页面能力的地基，三线在此汇合。
- **WebEngine 抽象（L1-W6）→ 多窗口（L2-W6）**：每窗口独立 TabManager 依赖引擎抽象。

---

### 阶段 0：工程基建（W1–3）— *先止血*

| 任务 | 产出 | 解决债 |
|---|---|---|
| 添加 **Test Target + CI**（GitHub Actions） | 单元测试覆盖 Store 层（Bookmark/History/Tab/AI 工具） | A3 |
| 引入 **swift-log** 统一日志 + 崩溃捕获 | `Logger` 子系统 `me.siwi.Desire.*`，替换所有 `print` | A10 |
| **ContentView 拆分** | 抽出 `BrowserWindow`、`PanelsRouter`、命令分发；ContentView ≤ 300 行 | A1 |
| **CommandBus** 替换 `NotificationCenter` 命令路由 | `enum AppCommand` + actor | A1 |
| 把内联 JS 全部移到 **`UserScripts/` 资源** | `password.js/reader.js/audio.js/console.js/picker.js/tools.js`；Swift 侧只做加载 + message handler | A2 |

**退出标准**：测试 target green，ContentView 行数减半，无 `print`。

### 阶段 1：核心引擎 + AI 差异化并行（W4–8）

**L1 工程化线**
| 任务 | 关键点 |
|---|---|
| **Storage 层迁移** | 历史/会话/书签 → Core Data（App Support）；Tab session 用 `interactionState` + 磁盘文件，不再挤 UserDefaults |
| **WebEngine 抽象** | 收敛 `WKWebView` 封装为 `protocol WebEngine`，为未来多引擎留口 |

**L2 核心引擎线**
| 任务 | 关键点 |
|---|---|
| **多窗口支持** | `WindowSceneCoordinator` + 每窗口 `TabManager`；落地 `BrowserCommand.newWindow` | A7 |
| **JS Bridge 参数化** | 用 `WKScriptMessageHandlerWithReply` + JSON-RPC 协议替换字符串拼接，消除注入面 | A9 |
| **下载/网络可靠性** | 断点续传、错误分类、沙盒下载目录管理 |

**L3 AI 差异化线**
| 任务 | 设计 |
|---|---|
| **ModelProvider 抽象 + ModelRouter** | 把现有 `AIService` 包成 `CloudOpenAIProvider`（零行为变更）；新增 `protocol ModelProvider` |
| **AgentRuntime v2** | 移除 `0..<20` 硬上限 → 基于 token/时间预算；支持暂停/恢复；agent 状态持久化 |
| **FoundationModelsProvider** | 接入 macOS 26 Foundation Models framework，摘要/翻译/隐私敏感任务本地跑 |
| **OllamaProvider** | 原生支持 localhost:11434（OpenAI 兼容），零隐私外泄 |

**退出标准**：可开多窗口；崩溃后标签可恢复；JS 注入零字符串拼接；本地模型可用。

### 阶段 2：AI 护城河 + 扩展生态（W7–14）

**L1 工程化线**
| 任务 |
|---|
| 插件 SDK（让第三方用 Swift/JS 扩展 Agent 工具集） |

**L2 核心引擎线**
| 任务 | 设计 |
|---|---|
| **WebExtensions API 完整实现** | 替换 `chrome.*` stub，实现 `storage/tabs/runtime/cookies` 真实后端 | A6 |
| **MV3 Service Worker 支持** | 让真实 Chrome/Safari 扩展可直接安装 |
| **容器标签 + 代理** | 身份隔离的标签（类 Firefox Multi-Account Containers）；每标签/容器独立代理 |

**L3 AI 差异化线**
| 任务 | 设计 |
|---|---|
| **人在回路工具审批** | `executeJS`/`navigate`/`fill` 等高风险工具触发审批 UI；带"始终允许此站点"白名单 |
| **工具能力分级** | 只读（getPageText/screenshot/extract）自动执行；副作用类需审批；危险类（executeJS）每次确认 |
| **页面上下文 RAG** | Agent 自动把当前页 text + DOM 摘要 + 选区纳入 system prompt |
| **MCP 客户端** | 对接外部 MCP server，让 agent 工具集可扩展（数据库/笔记/本地文件） |
| **任务化 Agent** | "帮我比价并下单"这类长任务：可视化执行轨迹、可回放、可中断 |
| **RoutingProvider** | 规则路由：摘要/翻译→本地；复杂工具链→云端；隐私敏感→本地 |

### 阶段 4：平台化与发布（持续）

| 任务 |
|---|
| **TestFlight 公测** + 公证（notarization）+ 自动更新（Sparkle） |
| **设置同步**（iCloud Key-Value / 自建） |
| **可观测性**：性能 trace（Instruments 集成）、用户可选遥测 |
| **iOS / iPadOS 移植评估**（共享 Feature 模块，替换 NSViewRepresentable → UIViewRepresentable） |

---

## 六、依赖白名单（允许"引入必要依赖"后）

| 依赖 | 用途 | 风险 | 建议 |
|---|---|---|---|
| `apple/swift-log` | 统一日志 | 低，Apple 官方 | ✅ 阶段 0 引入 |
| **Foundation Models**（系统框架） | 本地 LLM | 无（系统内置） | ✅ 阶段 1 接入 |
| MCP Swift SDK（若可用） | 外部工具扩展 | 中，协议演进中 | ⏳ 阶段 2 评估，否则自研轻量客户端 |
| Core Data（系统框架） | 持久化 | 无 | ✅ 阶段 1 替换 UserDefaults |
| Sparkle | 自动更新 | 中，需公证 | ⏳ 阶段 4 |
| **不引入**：网络/UI/JS 引擎库 | — | — | 保持自研，符合浏览器定位 |

---

## 七、AI 模型策略落地（全模型策略）

设计一个 **`ModelRouter`** 抽象，四种 provider 并存，用户在设置里选 + 路由规则：

```
protocol ModelProvider {
    func stream(messages: [AIMessage], tools: [AIToolDef]) -> AsyncThrowingStream<AIStreamEvent, Error>
}

┌─ CloudOpenAIProvider       (现状 AIService, 兼容 OpenAI/Anthropic-via-proxy/Gemini-via-proxy)
├─ FoundationModelsProvider  (macOS 26 本地, 用 @Generable / LanguageModelSession)
├─ OllamaProvider            (localhost:11434, OpenAI 兼容)
└─ RoutingProvider           (规则: 摘要/翻译→本地; 复杂工具链→云端; 隐私敏感→本地)
```

**路由策略示例**：
- 「翻译此页」→ FoundationModels 本地（隐私 + 离线）
- 「帮我比价下单」→ 云端（强推理 + 多工具）
- 「总结这条选中的内容」→ Ollama（若用户已配，否则本地）
- 设置里给每类任务暴露「模型偏好」下拉。

现有 `AIService` 直接保留为 `CloudOpenAIProvider` 的实现——零迁移成本。

---

## 八、近期第一批可并行 PR

阶段 0 + 阶段 1 起步的 4 个 PR，互相独立可并行 review：

| # | 线 | 任务 | 解决 |
|---|---|---|---|
| **L1-1** | 工程化 | 抽 `PanelsRouter` + `CommandBus`，`ContentView` 从 1135 → ~400 行 | A1 |
| **L1-2** | 工程化 | 建 `Desire/UserScripts/` 目录，迁 `WebView.swift` 12 段内联 JS 到 `.js` 资源 | A2 |
| **L3-1** | AI 差异化 | 抽 `protocol ModelProvider`，现有 `AIService` 包成 `CloudOpenAIProvider`（纯重构） | 为 L3 阶段 1 解锁 |
| **L1-3** | 工程化 | 加 Test Target + `BookmarkStore`/`HistoryStore` 第一批单测 | A3 |
