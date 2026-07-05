# AI Agent 集成设计

## 概述

将 AI 深度集成到 Desire 浏览器中，核心能力：AI 可以通过 Tool-Use 协议操控浏览器、提取数据、执行脚本。用户通过自然语言与浏览器交互。

## 架构

```
┌────────────────────────────────────────────────────────┐
│  AIPanel (Sidebar)    │  AIFloatingWindow (Floating)   │
│  ───────────────────  │  ───────────────────────────   │
│  [对话历史]            │  [最近消息 + 输入框]            │
│  [消息输入]            │  [展开 → 侧栏]                 │
│  [tool 调用可视化]     │                                │
│  [元素选取按钮]        │                                │
├────────────────────────────────────────────────────────┤
│  AISessionStore (per-Tab)                               │
│  ── 消息历史管理                                         │
│  ── Tool call ←→ LLM 循环                               │
├────────────────────────────────────────────────────────┤
│  AIService (LLM API Client)                             │
│  ── URLSession → OpenAI / Anthropic REST API            │
│  ── Streaming SSE 解析                                  │
├────────────────────────────────────────────────────────┤
│  BrowserToolProvider                                    │
│  ── 定义 Tool JSON Schema                               │
│  ── 执行 Tool: evaluateJavaScript / ScreenshotCapture   │
├────────────────────────────────────────────────────────┤
│  AIElementPicker                                        │
│  ── 复用现有元素选取 JS                                 │
│  ── 选中元素 → 自动添加到对话上下文                       │
└────────────────────────────────────────────────────────┘
```

## 文件结构

```
Features/AI/
├── AIMessage.swift              # Model
├── AIPreferenceStore.swift      # API Key + 模型配置
├── AISessionStore.swift         # 对话 + tool 编排
├── AIService.swift              # LLM API 调用
├── BrowserToolProvider.swift    # Tool 定义 + 执行
├── AIPanel.swift                # 侧栏视图
├── AIFloatingPanelController.swift  # 浮动窗口控制器
├── AIFloatingPanelView.swift        # 浮动窗口内容
└── AIElementPicker.swift            # 元素选取逻辑
```

## 1. 数据模型 (AIMessage.swift)

```swift
enum AIMessageRole: String, Codable {
    case system, user, assistant, tool
}

struct AIMessage: Identifiable, Codable {
    let id: UUID
    let role: AIMessageRole
    var content: String?           // 文本内容（tool 消息为 tool 结果）
    var toolCalls: [AIToolCall]?   // assistant 消息附带
    var toolCallId: String?        // tool 消息附带
    var createdAt: Date
}

struct AIToolCall: Identifiable, Codable {
    let id: String                 // LLM 分配的 ID
    let type: String               // 固定 "function"
    let function: AIToolFunction
}

struct AIToolFunction: Codable {
    let name: String
    let arguments: String          // JSON string
}

struct AIToolResult: Codable {
    let toolCallId: String
    let content: String
}
```

## 2. Preference Store (AIPreferenceStore.swift)

```swift
@MainActor
class AIPreferenceStore: ObservableObject {
    @Published var apiKey: String          // Keychain 存储
    @Published var model: String           // "gpt-4o" / "claude-sonnet-4-20250514"
    @Published var endpoint: String        // API 地址
    @Published var systemPrompt: String    // 系统指令
    @Published var maxTokens: Int
    @Published var temperature: Double

    // Keychain 读写
    func loadAPIKey() -> String?
    func saveAPIKey(_ key: String)
    func deleteAPIKey()
}
```

系统指令默认模板包含：AI 的角色定位、可用工具列表、操作规则说明。

## 3. Session Store (AISessionStore.swift)

每个 Tab 持有独立的 `AISessionStore`。

```swift
@MainActor
class AISessionStore: ObservableObject {
    @Published var messages: [AIMessage] = []
    @Published var isProcessing = false
    @Published var currentToolCall: String?  // UI 显示的当前 tool

    let preference: AIPreferenceStore
    let toolProvider: BrowserToolProvider

    /// 发送新消息 → 驱动 tool 循环
    func sendMessage(_ text: String) async
    func cancel()
    func clear()
}
```

**Tool 循环：**
1. 追加用户 `AIMessage(role: .user, content: text)`
2. 构建请求（system + 历史消息 + tool 定义）
3. 调 `AIService.stream()` → 处理 streaming 事件：
   - `.text(String)` → 实时更新最后一条 assistant 消息的 content
   - `.toolCall(AIToolCall)` → 缓存
4. 当流结束且有 tool calls：
   - 对每个 tool call：`BrowserToolProvider.execute()`
   - 结果追加为 `AIMessage(role: .tool)` 
   - 再次调 `AIService.stream()`（不带 tool 定义，仅带结果）
   - 循环至 no tool calls
5. `isProcessing = false`

## 4. AI Service (AIService.swift)

```swift
enum AIStreamEvent {
    case text(String)              // 文本增量
    case toolCall(AIToolCall)     // 完整 tool call
}

struct AIService {
    /// 流式调用 LLM
    static func stream(
        messages: [AIMessage],
        tools: [AIToolDef],
        apiKey: String,
        endpoint: String,
        model: String,
        maxTokens: Int,
        temperature: Double
    ) -> AsyncThrowingStream<AIStreamEvent, Error>

    /// 非流式调用（tool 循环中的后续请求）
    static func complete(
        messages: [AIMessage],
        apiKey: String,
        endpoint: String,
        model: String
    ) async throws -> [AIToolCall]  // 可能返回空的 tool calls
}
```

**OpenAI API 格式**（默认）：
- POST `{endpoint}/chat/completions`
- 标准 SSE streaming 解析

**工具定义格式：**
```json
{
  "type": "function",
  "function": {
    "name": "navigate",
    "description": "Navigate to a URL",
    "parameters": { ... }
  }
}
```

## 5. Browser Tool Provider (BrowserToolProvider.swift)

```swift
@MainActor
class BrowserToolProvider {
    weak var webView: WKWebView?

    /// 所有工具的 JSON schema 定义（发给 LLM）
    static var toolDefs: [AIToolDef] { ... }

    /// 执行单个 tool call
    func execute(_ call: AIToolCall) async -> String
}
```

### 工具清单

| 名称 | 参数 | 实现方式 |
|------|------|----------|
| `getPageText` | 无 | `document.body.innerText` |
| `getPageHTML` | 无 | `document.documentElement.outerHTML` |
| `getPageTitle` | 无 | `document.title` |
| `screenshot` | 无 | 复用 `ScreenshotCapture` → base64 |
| `navigate` | `url: string` | `webView.load(URLRequest)` |
| `goBack` | 无 | `webView.goBack()` |
| `goForward` | 无 | `webView.goForward()` |
| `click` | `selector: string` | `document.querySelector(sel).click()` |
| `fill` | `selector, value: string` | `el.value = value; el.dispatchEvent(new Event('input'))` |
| `select` | `selector, value: string` | `el.value = value; el.dispatchEvent(new Event('change'))` |
| `scroll` | `x, y: number` | `window.scrollTo(x, y)` |
| `hover` | `selector: string` | `el.dispatchEvent(new MouseEvent('mouseover'))` |
| `focus` | `selector: string` | `el.focus()` |
| `extract` | `selector: string` | `el.textContent` |
| `find` | `selector: string` | `document.querySelectorAll(sel)` → 返回数量 + 首个文本 |
| `wait` | `ms: number` | `Task.sleep` |
| `waitForElement` | `selector, timeout: number` | 轮询 `querySelector` |
| `executeJS` | `code: string` | `webView.evaluateJavaScript(code)` |
| `getSelectedText` | 无 | `window.getSelection().toString()` |

## 6. View 层

### 6.1 AIPanel（侧栏）

- 从右侧滑入，宽度 360pt
- 背景 `.background(.thinMaterial)` 
- 标题栏：状态圆点（绿/灰）+ "AI" + 停止按钮（`isProcessing` 时显示）+ 菜单（清空对话 / 切换浮动窗口）
- 消息列表：用户消息（右对齐，蓝色气泡）、AI 消息（左对齐）、Tool 调用（折叠卡片，可展开看参数/结果）
- 输入栏：多行 TextField + 发送按钮 + 元素选取按钮
- 快捷键：`⌘⏎` 发送，`⌘⇧I` 切换

### 6.2 AIFloatingPanel（浮动窗口）

- `NSWindow` level: `.floating`，无边框
- 默认位置：屏幕右下角
- 大小：320×400，可拖拽
- 内容：最近 3 条消息 + 输入框 + 最小化按钮
- 点击「展开」→ 切换到 AIPanel 侧栏模式
- 浮动窗口独立于 Tab，共享全局会话

### 6.3 AI 元素选取

- 复用现有的 `elementPickerJS`（注入在 WebView init 时）
- 新增 `BrowserState.aiElementPicked: ((selector: String, html: String) -> Void)?`
- 当 AI 面板中点击「选取元素」：
  - `isPickingElement = true`（复用已有状态）
  - 用户 hover/click 页面元素
  - `elementPicker` message 触发
  - Coordinator 检查是 AI pick 模式 → 获取元素 outerHTML
  - 将 `selector + html` 插入 AI 聊天输入框，用户可以附加指令

## 7. 集成点

### ContentView.swift
- 初始化 `AIPreferenceStore` + `AISessionStore`（主 Tab 全局）
- `ZStack` 叠加 `AIPanel`（`showAIPanel: Bool` 控制）
- 工具栏添加 AI 按钮
- Reuse `ElementBlockStore` 的 `isPickingElement` 状态

### Toolbar.swift
- 添加 AI 按钮（`AppCommand.toggleAI`）

### DesireApp.swift
- 注册快捷键 `⌘⇧I` → `.toggleAI`
- 添加菜单项

### WebView.swift
- `BrowserToolProvider` 通过 `BrowserState.webView` 获取引用
- 截图通过 `ScreenshotCapture.captureDisplayRect` 复用

### SettingsView.swift
- 在隐私/高级设置中添加 AI 配置 section
- API Key 输入 + 模型选择 + 自定义 system prompt

## 8. 安全考虑

- API Key 仅存 Keychain（`kSecClassInternetPassword`）
- AI 执行的 JS 代码限制在页面沙箱内（WKWebView 默认）
- 所有导航操作用户可见（AI 不会在隐藏 iframe 中操作）
- 用户在 AIPanel 中可以随时停止 AI 操作

## 9. 关键技术决策

| 决策 | 选择 | 理由 |
|------|------|------|
| LLM 协议 | OpenAI API 格式 | 可兼容 OpenAI / Anthropic / Ollama / 国内服务 |
| Streaming | SSE | 实时展示 AI 回复，用户体验好 |
| Key 存储 | Keychain | 安全要求，不可落 UserDefaults |
| Tool 执行方式 | evaluateJavaScript | 零依赖，直接操控页面 DOM |
| 截图方式 | 复用 ScreenshotCapture | 已有实现，避免重复 |
| 元素选取 | 复用 elementPickerJS | 已有选中高亮 + CSS 选择器提取 |
| 浮动窗口 | NSWindow + NSHostingView | 原生 macOS 浮窗，无依赖 |
