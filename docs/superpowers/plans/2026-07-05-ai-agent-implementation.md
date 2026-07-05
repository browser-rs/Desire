# AI Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate an AI agent that can control the browser, extract data, run scripts, and converse with the user through a sidebar panel and floating window.

**Architecture:** Tool-Use protocol via function calling. Each Tab has an `AISessionStore` that manages message history and a tool-call loop. `BrowserToolProvider` defines tool schemas and executes them via `evaluateJavaScript`. `AIService` streams LLM responses over URLSession. Views: sidebar panel (`AIPanel`) + floating window (`NSWindow`).

**Tech Stack:** SwiftUI, WKWebView (evaluateJavaScript), URLSession, Keychain

## Global Constraints

- `@MainActor` on all observable types
- Strict concurrency checking on (`SWIFT_APPROACHABLE_CONCURRENCY = YES`)
- Each file must `import` every framework it uses directly
- App Sandbox with `com.apple.security.network.client` entitlement for web access
- No SPM/CocoaPods/package dependencies
- Zero `#Preview` required
- API Key stored in Keychain, not UserDefaults
- Build via xcodebuild before reporting completion

---

### Task 1: Data Models (AIMessage.swift)

**Files:**
- Create: `Desire/Features/AI/AIMessage.swift`

**Interfaces:**
- Produces: `AIMessage`, `AIMessageRole`, `AIToolCall`, `AIToolFunction`, `AIToolDef` types used by all later tasks

- [ ] **Create `Desire/Features/AI/AIMessage.swift`:**

```swift
import Foundation

enum AIMessageRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

struct AIMessage: Identifiable, Codable, Sendable {
    let id: UUID
    let role: AIMessageRole
    var content: String?
    var toolCalls: [AIToolCall]?
    var toolCallId: String?
    let createdAt: Date

    init(role: AIMessageRole, content: String? = nil, toolCalls: [AIToolCall]? = nil, toolCallId: String? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.createdAt = Date()
    }
}

struct AIToolCall: Identifiable, Codable, Sendable {
    let id: String
    let type: String
    let function: AIToolFunction
}

struct AIToolFunction: Codable, Sendable {
    let name: String
    let arguments: String
}

struct AIToolDef: Codable, Sendable {
    let type: String
    let function: AIToolFunctionDef
}

struct AIToolFunctionDef: Codable, Sendable {
    let name: String
    let description: String
    let parameters: AIJSONSchema
}

struct AIJSONSchema: Codable, Sendable {
    let type: String
    var properties: [String: AIJSONSchema]?
    var required: [String]?
    var description: String?
    var items: AIJSONSchema?
    var enumValues: [String]?

    enum CodingKeys: String, CodingKey {
        case type, properties, required, description, items
        case enumValues = "enum"
    }
}
```

- [ ] **Build:** `xcodebuild -project Desire.xcodeproj -scheme Desire build`

---

### Task 2: AIPreferenceStore

**Files:**
- Create: `Desire/Features/AI/AIPreferenceStore.swift`

**Interfaces:**
- Produces: `AIPreferenceStore` — consumed by `AIService`, `AISessionStore`, `AIPanel`
- Exposes: `apiKey`, `model`, `endpoint`, `systemPrompt`, `maxTokens`, `temperature`

- [ ] **Create `Desire/Features/AI/AIPreferenceStore.swift`:**

```swift
import Combine
import Foundation
import Security

@MainActor
class AIPreferenceStore: ObservableObject {
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "aiModel") }
    }
    @Published var endpoint: String {
        didSet { UserDefaults.standard.set(endpoint, forKey: "aiEndpoint") }
    }
    @Published var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: "aiSystemPrompt") }
    }
    @Published var maxTokens: Int {
        didSet { UserDefaults.standard.set(maxTokens, forKey: "aiMaxTokens") }
    }
    @Published var temperature: Double {
        didSet { UserDefaults.standard.set(temperature, forKey: "aiTemperature") }
    }
    @Published var hasAPIKey: Bool = false

    private let keychainService = "me.siwi.Desire"
    private let keychainAccount = "ai-api-key"

    init() {
        model = UserDefaults.standard.string(forKey: "aiModel") ?? "gpt-4o"
        endpoint = UserDefaults.standard.string(forKey: "aiEndpoint") ?? "https://api.openai.com/v1"
        systemPrompt = UserDefaults.standard.string(forKey: "aiSystemPrompt") ?? Self.defaultPrompt
        maxTokens = UserDefaults.standard.object(forKey: "aiMaxTokens") as? Int ?? 4096
        temperature = UserDefaults.standard.object(forKey: "aiTemperature") as? Double ?? 0.7
        hasAPIKey = loadAPIKey() != nil
    }

    func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    func saveAPIKey(_ key: String) {
        deleteAPIKey()
        guard let data = key.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
        hasAPIKey = true
    }

    func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        hasAPIKey = false
    }

    static let defaultPrompt = """
You are an AI assistant integrated into the Desire browser. You can:
- Read the current page content and structure
- Navigate to URLs, click elements, fill forms, scroll
- Extract data and execute JavaScript
- Take screenshots of the viewport

When the user asks you to do something, use the available tools. Always explain what you're doing. Prefer non-destructive actions.
"""
}
```

- [ ] **Build:** `xcodebuild -project Desire.xcodeproj -scheme Desire build`

---

### Task 3: BrowserToolProvider

**Files:**
- Create: `Desire/Features/AI/BrowserToolProvider.swift`

**Interfaces:**
- Consumes: `AIToolDef` (from Task 1)
- Produces: `BrowserToolProvider` — consumed by `AISessionStore`
- Exposes: `toolDefs: [AIToolDef]`, `execute(_ call: AIToolCall, in webView: WKWebView) async -> String`

- [ ] **Create `Desire/Features/AI/BrowserToolProvider.swift`:**

```swift
import WebKit

@MainActor
class BrowserToolProvider {
    static var toolDefs: [AIToolDef] {
        [
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getPageText", description: "Get the visible text content of the current page",
                parameters: AIJSONSchema(type: "object", properties: nil, required: nil)
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getPageHTML", description: "Get the full HTML of the current page",
                parameters: AIJSONSchema(type: "object", properties: nil, required: nil)
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getPageTitle", description: "Get the page title",
                parameters: AIJSONSchema(type: "object", properties: nil, required: nil)
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "screenshot", description: "Take a screenshot of the current viewport, returns base64 PNG",
                parameters: AIJSONSchema(type: "object", properties: nil, required: nil)
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getSelectedText", description: "Get the text currently selected by the user on the page",
                parameters: AIJSONSchema(type: "object", properties: nil, required: nil)
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "navigate", description: "Navigate to a URL",
                parameters: AIJSONSchema(type: "object", properties: ["url": AIJSONSchema(type: "string", description: "The URL to navigate to")], required: ["url"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "goBack", description: "Go back in history",
                parameters: AIJSONSchema(type: "object", properties: nil, required: nil)
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "goForward", description: "Go forward in history",
                parameters: AIJSONSchema(type: "object", properties: nil, required: nil)
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "click", description: "Click an element identified by CSS selector",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchema(type: "string", description: "CSS selector of the element")], required: ["selector"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "fill", description: "Fill a form field with a value",
                parameters: AIJSONSchema(type: "object", properties: [
                    "selector": AIJSONSchema(type: "string", description: "CSS selector of the input"),
                    "value": AIJSONSchema(type: "string", description: "Value to fill")
                ], required: ["selector", "value"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "select", description: "Select an option from a dropdown",
                parameters: AIJSONSchema(type: "object", properties: [
                    "selector": AIJSONSchema(type: "string", description: "CSS selector of the select element"),
                    "value": AIJSONSchema(type: "string", description: "Value to select")
                ], required: ["selector", "value"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "scroll", description: "Scroll the page to coordinates",
                parameters: AIJSONSchema(type: "object", properties: [
                    "x": AIJSONSchema(type: "number", description: "Horizontal scroll position"),
                    "y": AIJSONSchema(type: "number", description: "Vertical scroll position")
                ], required: ["x", "y"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "hover", description: "Hover over an element",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchema(type: "string", description: "CSS selector")], required: ["selector"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "focus", description: "Focus an element",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchema(type: "string", description: "CSS selector")], required: ["selector"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "extract", description: "Extract text content from elements matching a CSS selector",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchema(type: "string", description: "CSS selector")], required: ["selector"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "find", description: "Find elements by CSS selector, returns count and first match text",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchema(type: "string", description: "CSS selector")], required: ["selector"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "wait", description: "Wait for a specified number of milliseconds",
                parameters: AIJSONSchema(type: "object", properties: ["ms": AIJSONSchema(type: "number", description: "Milliseconds to wait")], required: ["ms"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "waitForElement", description: "Wait for an element to appear in the DOM",
                parameters: AIJSONSchema(type: "object", properties: [
                    "selector": AIJSONSchema(type: "string", description: "CSS selector"),
                    "timeout": AIJSONSchema(type: "number", description: "Max milliseconds to wait")
                ], required: ["selector"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "executeJS", description: "Execute arbitrary JavaScript code in the page context and return the result",
                parameters: AIJSONSchema(type: "object", properties: ["code": AIJSONSchema(type: "string", description: "JavaScript code")], required: ["code"])
            )),
        ]
    }

    func execute(_ call: AIToolCall, in webView: WKWebView) async -> String {
        let args = try? JSONSerialization.jsonObject(with: call.function.arguments.data(using: .utf8) ?? Data()) as? [String: Any]
        switch call.function.name {
        case "getPageText":
            return await eval(webView, "document.body.innerText")
        case "getPageHTML":
            return await eval(webView, "document.documentElement.outerHTML")
        case "getPageTitle":
            return await eval(webView, "document.title")
        case "screenshot":
            // Delegate to ScreenshotCapture – return a placeholder for now
            return "[Screenshot capture not yet integrated]"
        case "getSelectedText":
            return await eval(webView, "window.getSelection().toString()")
        case "navigate":
            if let url = args?["url"] as? String, let u = URL(string: url) {
                webView.load(URLRequest(url: u))
                return "Navigated to \(url)"
            }
            return "Invalid URL"
        case "goBack":
            webView.goBack()
            return "Going back"
        case "goForward":
            webView.goForward()
            return "Going forward"
        case "click":
            if let sel = args?["selector"] as? String {
                return await eval(webView, """
                (function() {
                    var el = document.querySelector('\(sel.jsEscaped)');
                    if (!el) return 'Element not found: \(sel.jsEscaped)';
                    el.click();
                    return 'Clicked \(sel.jsEscaped)';
                })()
                """)
            }
            return "Missing selector"
        case "fill":
            if let sel = args?["selector"] as? String, let val = args?["value"] as? String {
                return await eval(webView, """
                (function() {
                    var el = document.querySelector('\(sel.jsEscaped)');
                    if (!el) return 'Element not found';
                    el.value = '\(val.jsEscaped)';
                    el.dispatchEvent(new Event('input', {bubbles:true}));
                    el.dispatchEvent(new Event('change', {bubbles:true}));
                    return 'Filled \(sel.jsEscaped)';
                })()
                """)
            }
            return "Missing selector or value"
        case "select":
            if let sel = args?["selector"] as? String, let val = args?["value"] as? String {
                return await eval(webView, """
                (function() {
                    var el = document.querySelector('\(sel.jsEscaped)');
                    if (!el) return 'Element not found';
                    el.value = '\(val.jsEscaped)';
                    el.dispatchEvent(new Event('change', {bubbles:true}));
                    return 'Selected \(val)';
                })()
                """)
            }
            return "Missing selector or value"
        case "scroll":
            let x = args?["x"] as? CGFloat ?? 0
            let y = args?["y"] as? CGFloat ?? 0
            return await eval(webView, "window.scrollTo(\(x), \(y)); return 'Scrolled to (\(x), \(y))'")
        case "hover":
            if let sel = args?["selector"] as? String {
                return await eval(webView, """
                (function() {
                    var el = document.querySelector('\(sel.jsEscaped)');
                    if (!el) return 'Element not found';
                    el.dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));
                    return 'Hovered \(sel.jsEscaped)';
                })()
                """)
            }
            return "Missing selector"
        case "focus":
            if let sel = args?["selector"] as? String {
                return await eval(webView, """
                (function() {
                    var el = document.querySelector('\(sel.jsEscaped)');
                    if (!el) return 'Element not found';
                    el.focus();
                    return 'Focused \(sel.jsEscaped)';
                })()
                """)
            }
            return "Missing selector"
        case "extract":
            if let sel = args?["selector"] as? String {
                return await eval(webView, """
                (function() {
                    var els = document.querySelectorAll('\(sel.jsEscaped)');
                    return Array.from(els).map(function(e){ return e.textContent.trim(); }).filter(Boolean).join('\\n---\\n');
                })()
                """)
            }
            return "Missing selector"
        case "find":
            if let sel = args?["selector"] as? String {
                return await eval(webView, """
                (function() {
                    var els = document.querySelectorAll('\(sel.jsEscaped)');
                    if (els.length === 0) return 'No elements found for \(sel.jsEscaped)';
                    var first = els[0].textContent.trim().substring(0, 200);
                    return 'Found ' + els.length + ' elements. First match: ' + first;
                })()
                """)
            }
            return "Missing selector"
        case "wait":
            let ms = args?["ms"] as? Int ?? 1000
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            return "Waited \(ms)ms"
        case "waitForElement":
            let sel = args?["selector"] as? String ?? ""
            let timeout = args?["timeout"] as? Int ?? 5000
            return await eval(webView, """
            (function() {
                var start = Date.now();
                return new Promise(function(resolve) {
                    function check() {
                        var el = document.querySelector('\(sel.jsEscaped)');
                        if (el) return resolve('Found element');
                        if (Date.now() - start > \(timeout)) return resolve('Timeout after \(timeout)ms');
                        setTimeout(check, 200);
                    }
                    check();
                });
            })()
            """)
        case "executeJS":
            if let code = args?["code"] as? String {
                let result = await eval(webView, code)
                return result ?? "Executed (no return value)"
            }
            return "Missing code"
        default:
            return "Unknown tool: \(call.function.name)"
        }
    }

    private func eval(_ wv: WKWebView, _ js: String) async -> String {
        await withCheckedContinuation { continuation in
            wv.evaluateJavaScript(js) { result, error in
                if let error = error {
                    continuation.resume(returning: "Error: \(error.localizedDescription)")
                } else if let result = result as? String {
                    continuation.resume(returning: result)
                } else if let result = result {
                    continuation.resume(returning: "\(result)")
                } else {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}

private extension String {
    var jsEscaped: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }
}
```

- [ ] **Build:** `xcodebuild -project Desire.xcodeproj -scheme Desire build`

---

### Task 4: AIService (LLM API Client)

**Files:**
- Create: `Desire/Features/AI/AIService.swift`

**Interfaces:**
- Consumes: `AIMessage`, `AIToolDef` (Task 1), `AIPreferenceStore` (Task 2)
- Produces: `AIService` — consumed by `AISessionStore`
- Exposes: `static stream(messages:tools:prefs:) -> AsyncThrowingStream<AIStreamEvent, Error>`

- [ ] **Create `Desire/Features/AI/AIService.swift`:**

```swift
import Foundation

enum AIStreamEvent {
    case text(String)
    case toolCall(AIToolCall)
}

enum AIServiceError: LocalizedError {
    case noAPIKey
    case network(Error)
    case decoding(Error)
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "API Key not configured. Set it in Settings > AI."
        case .network(let e): return "Network error: \(e.localizedDescription)"
        case .decoding(let e): return "Response parsing error: \(e.localizedDescription)"
        case .httpStatus(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        }
    }
}

struct AIService {
    static func stream(messages: [AIMessage], tools: [AIToolDef], prefs: AIPreferenceStore) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let apiKey = prefs.loadAPIKey() else {
                    continuation.finish(throwing: AIServiceError.noAPIKey)
                    return
                }

                let url = URL(string: prefs.endpoint.hasSuffix("/chat/completions")
                    ? prefs.endpoint : prefs.endpoint + "/chat/completions")!

                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                req.setValue("chatcmpl-\(UUID().uuidString.prefix(8))", forHTTPHeaderField: "X-Request-Id")

                var body: [String: Any] = [
                    "model": prefs.model,
                    "messages": messages.map { msg in
                        var m: [String: Any] = ["role": msg.role.rawValue]
                        if let content = msg.content { m["content"] = content }
                        if let tcs = msg.toolCalls {
                            m["tool_calls"] = tcs.map { tc in
                                [
                                    "id": tc.id,
                                    "type": tc.type,
                                    "function": [
                                        "name": tc.function.name,
                                        "arguments": tc.function.arguments
                                    ]
                                ]
                            }
                        }
                        if let tid = msg.toolCallId {
                            m["tool_call_id"] = tid
                        }
                        return m
                    },
                    "stream": true,
                    "max_tokens": prefs.maxTokens,
                    "temperature": prefs.temperature,
                ]

                if !tools.isEmpty {
                    body["tools"] = tools.map { t in
                        [
                            "type": t.type,
                            "function": [
                                "name": t.function.name,
                                "description": t.function.description,
                                "parameters": t.function.parameters,
                            ]
                        ]
                    }
                }

                req.httpBody = try? JSONSerialization.data(withJSONObject: body)

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: AIServiceError.network(NSError(domain: "AI", code: -1)))
                        return
                    }
                    guard http.statusCode == 200 else {
                        var errBody = ""
                        for try await line in bytes.lines { errBody += line }
                        continuation.finish(throwing: AIServiceError.httpStatus(http.statusCode, errBody))
                        return
                    }

                    var currentToolCall: (id: String, name: String, args: String)?

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let data = String(line.dropFirst(6))
                        if data == "[DONE]" { break }
                        guard let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                              let delta = (json as NSDictionary).value(forKeyPath: "choices.0.delta") as? [String: Any] else { continue }

                        // Text content
                        if let text = delta["content"] as? String {
                            continuation.yield(.text(text))
                        }

                        // Tool calls
                        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                            for tc in toolCalls {
                                let index = tc["index"] as? Int ?? 0
                                if index == 0 {
                                    if let id = tc["id"] as? String {
                                        currentToolCall = (id, "", "")
                                    }
                                    if let fn = tc["function"] as? [String: Any] {
                                        if let name = fn["name"] as? String, !name.isEmpty {
                                            currentToolCall?.name = (currentToolCall?.name ?? "") + name
                                        }
                                        if let args = fn["arguments"] as? String, !args.isEmpty {
                                            currentToolCall?.args = (currentToolCall?.args ?? "") + args
                                        }
                                    }
                                }
                            }
                        }

                        // Finish reason with tool_calls
                        if let finish = (json as NSDictionary).value(forKeyPath: "choices.0.finish_reason") as? String,
                           finish == "tool_calls", let tc = currentToolCall {
                            let call = AIToolCall(
                                id: tc.id,
                                type: "function",
                                function: AIToolFunction(name: tc.name, arguments: tc.args)
                            )
                            continuation.yield(.toolCall(call))
                            currentToolCall = nil
                        }
                    }

                    // Emit remaining tool call if finish_reason wasn't caught
                    if let tc = currentToolCall {
                        let call = AIToolCall(
                            id: tc.id,
                            type: "function",
                            function: AIToolFunction(name: tc.name, arguments: tc.args)
                        )
                        continuation.yield(.toolCall(call))
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIServiceError.network(error))
                }
            }
        }
    }
}
```

- [ ] **Build:** `xcodebuild -project Desire.xcodeproj -scheme Desire build`

---

### Task 5: AISessionStore (Conversation + Tool Loop)

**Files:**
- Create: `Desire/Features/AI/AISessionStore.swift`

**Interfaces:**
- Consumes: `AIMessage` (Task 1), `AIPreferenceStore` (Task 2), `BrowserToolProvider` (Task 3), `AIService` (Task 4)
- Consumes: `WKWebView` (passed at runtime)
- Produces: `AISessionStore` — consumed by `AIPanel`
- Exposes: `messages: [AIMessage]`, `isProcessing: Bool`, `currentAction: String?`, `sendMessage(text:)`, `cancel()`, `clear()`, `addContext(html:)`, `setWebView(_:)`

- [ ] **Create `Desire/Features/AI/AISessionStore.swift`:**

```swift
import Combine
import WebKit

@MainActor
class AISessionStore: ObservableObject {
    @Published var messages: [AIMessage] = []
    @Published var isProcessing = false
    @Published var currentAction: String?

    let preference: AIPreferenceStore
    private let toolProvider = BrowserToolProvider()
    private weak var webView: WKWebView?
    private var isCancelled = false

    init(preference: AIPreferenceStore) {
        self.preference = preference
    }

    func setWebView(_ wv: WKWebView?) {
        webView = wv
    }

    func sendMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        messages.append(AIMessage(role: .user, content: text))
        isProcessing = true
        isCancelled = false
        Task { await processLoop() }
    }

    func addContext(html: String, selector: String) {
        let context = "<\(selector)>: \(html.prefix(1000))"
        messages.append(AIMessage(role: .user, content: "[Selected element]\n\(context)"))
    }

    func cancel() {
        isCancelled = true
        isProcessing = false
        currentAction = nil
    }

    func clear() {
        messages.removeAll()
        isProcessing = false
        currentAction = nil
        isCancelled = false
    }

    private func processLoop() async {
        defer {
            isProcessing = false
            currentAction = nil
        }

        for _ in 0..<20 { // safety limit — max 20 tool iterations
            if isCancelled { return }

            let hasTools = !messages.contains { $0.role == .tool }
            let stream = AIService.stream(
                messages: messages,
                tools: hasTools ? BrowserToolProvider.toolDefs : [],
                prefs: preference
            )

            var assistantMsg = AIMessage(role: .assistant, content: "")
            messages.append(assistantMsg)

            do {
                for try await event in stream {
                    if isCancelled { return }
                    switch event {
                    case .text(let delta):
                        assistantMsg.content = (assistantMsg.content ?? "") + delta
                        if let idx = messages.lastIndex(where: { $0.id == assistantMsg.id }) {
                            messages[idx] = assistantMsg
                        }
                    case .toolCall(let call):
                        assistantMsg.toolCalls = (assistantMsg.toolCalls ?? []) + [call]
                        if let idx = messages.lastIndex(where: { $0.id == assistantMsg.id }) {
                            messages[idx] = assistantMsg
                        }
                    }
                }
            } catch {
                let errMsg = AIMessage(role: .assistant, content: "Error: \(error.localizedDescription)")
                messages.append(errMsg)
                return
            }

            // Update the final assistant message
            if let idx = messages.firstIndex(where: { $0.id == assistantMsg.id }) {
                messages[idx] = assistantMsg
            }

            // Check if there are tool calls to execute
            guard let tcs = assistantMsg.toolCalls, !tcs.isEmpty else { return }

            // Execute each tool call
            for tc in tcs {
                if isCancelled { return }
                currentAction = tc.function.name
                let result = await toolProvider.execute(tc, in: webView ?? WKWebView())
                messages.append(AIMessage(role: .tool, content: result, toolCallId: tc.id))
            }
            currentAction = nil

            // Loop: send results back to LLM
        }
    }
}
```

- [ ] **Build:** `xcodebuild -project Desire.xcodeproj -scheme Desire build`

---

### Task 6: AI Element Picker

**Files:**
- Modify: `Desire/Features/AI/AIElementPicker.swift` (Create)
- Modify: `Desire/Features/Browsing/WebView.swift` (add `aiElementPicked` callback)

- [ ] **Create `Desire/Features/AI/AIElementPicker.swift`:**

```swift
import WebKit

struct AIElementPicker {
    static func extractElementHTML(selector: String, in webView: WKWebView) async -> String {
        await withCheckedContinuation { continuation in
            let js = """
            (function() {
                var el = document.querySelector('\(selector.replacingOccurrences(of: "'", with: "\\'"))');
                if (!el) return '';
                return el.outerHTML.substring(0, 2000);
            })()
            """
            webView.evaluateJavaScript(js) { result, _ in
                continuation.resume(returning: (result as? String) ?? "")
            }
        }
    }
}
```

- [ ] **In `BrowserState` (WebView.swift), add:**

```swift
var onAIElementPicked: ((String, String) -> Void)?
```

- [ ] **In `Coordinator.userContentController`, update the `elementPicker` handler:**

Current code:
```swift
} else if message.name == "elementPicker", let dict = message.body as? [String: String],
          let selector = dict["cssSelector"] {
    let xpath = dict["xpath"]
    parent.onElementPicked?(selector, xpath)
```

Replace with:
```swift
} else if message.name == "elementPicker", let dict = message.body as? [String: String],
          let selector = dict["cssSelector"] {
    let xpath = dict["xpath"]
    if let aiHandler = parent.state.onAIElementPicked {
        let escaped = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        parent.state.webView.evaluateJavaScript("""
        (function() {
            var el = document.querySelector('\(escaped)');
            return el ? el.outerHTML.substring(0, 2000) : '';
        })()
        """) { result, _ in
            if let html = result as? String {
                aiHandler(selector, html)
            }
        }
    } else {
        parent.onElementPicked?(selector, xpath)
    }
```

- [ ] **Build:** `xcodebuild -project Desire.xcodeproj -scheme Desire build`

---

### Task 7: AIPanel (Sidebar View)

**Files:**
- Create: `Desire/Features/AI/AIPanel.swift`

- [ ] **Create `Desire/Features/AI/AIPanel.swift`:**

```swift
import SwiftUI

struct AIPanel: View {
    @ObservedObject var session: AISessionStore
    @Binding var isVisible: Bool
    var onPickElement: (() -> Void)?
    var onToggleFloating: (() -> Void)?

    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Circle()
                    .fill(session.isProcessing ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text("AI").font(.headline)
                Spacer()
                if session.isProcessing {
                    Button { session.cancel() } label: {
                        Image(systemName: "stop.fill").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
                if let onToggleFloating {
                    Button { onToggleFloating() } label: {
                        Image(systemName: "arrow.up.backward.and.arrow.down.forward").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Button { session.clear() } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button { isVisible = false } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(session.messages) { msg in
                            MessageBubble(message: msg)
                        }
                        if session.isProcessing {
                            HStack {
                                ProgressView().scaleEffect(0.5)
                                if let action = session.currentAction {
                                    Text(action).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .id("bottom")
                        }
                    }
                    .padding(8)
                }
                .onChange(of: session.messages.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            Divider()

            // Input bar
            HStack(spacing: 6) {
                if let onPickElement {
                    Button { onPickElement() } label: {
                        Image(systemName: "cursorarrow.rays")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Pick element from page")
                }

                TextField("Ask AI to do something…", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused(isInputFocused)
                    .onSubmit { send() }

                Button { send() } label: {
                    Text("Send").font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isProcessing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        session.sendMessage(text)
        inputText = ""
    }
}

private struct MessageBubble: View {
    let message: AIMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer()
                Text(message.content ?? "")
                    .font(.system(size: 12))
                    .padding(8)
                    .background(Color.accentColor.opacity(0.15))
                    .cornerRadius(8)
                    .textSelection(.enabled)
            }
        case .assistant:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let content = message.content, !content.isEmpty {
                        Text(content)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                    }
                    if let tcs = message.toolCalls {
                        ForEach(tcs) { tc in
                            ToolCallView(toolCall: tc)
                        }
                    }
                }
                Spacer()
            }
        case .tool:
            HStack {
                Text(message.content ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
                    .textSelection(.enabled)
                Spacer()
            }
        default:
            EmptyView()
        }
    }
}

private struct ToolCallView: View {
    let toolCall: AIToolCall

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Text(toolCall.function.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            if let args = toolCall.function.arguments.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: args) as? [String: Any] {
                Text(json.compactMap { "\($0.key): \($0.value)" }.joined(separator: ", "))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(4)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(4)
    }
}
```

- [ ] **Build:** `xcodebuild -project Desire.xcodeproj -scheme Desire build`

---

### Task 8: Floating Window

**Files:**
- Create: `Desire/Features/AI/AIFloatingPanelController.swift`
- Create: `Desire/Features/AI/AIFloatingPanelView.swift`

- [ ] **Create `Desire/Features/AI/AIFloatingPanelView.swift`:**

```swift
import SwiftUI

struct AIFloatingPanelView: View {
    @ObservedObject var session: AISessionStore
    var onExpand: (() -> Void)?

    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Title bar with drag handle
            HStack {
                Circle()
                    .fill(session.isProcessing ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                Text("AI").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let onExpand {
                    Button { onExpand() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            // Recent messages
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(session.messages.suffix(3)) { msg in
                        Text(msg.content ?? "")
                            .font(.system(size: 11))
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                            .background(msg.role == .user ? Color.accentColor.opacity(0.1) : Color.clear)
                            .cornerRadius(4)
                    }
                    if session.isProcessing {
                        HStack {
                            ProgressView().scaleEffect(0.3)
                            if let action = session.currentAction {
                                Text(action).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            HStack(spacing: 4) {
                TextField("Ask…", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .onSubmit { send() }
                Button { send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 10))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(inputText.isEmpty || session.isProcessing)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(width: 280, height: 200)
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        session.sendMessage(text)
        inputText = ""
    }
}
```

- [ ] **Create `Desire/Features/AI/AIFloatingPanelController.swift`:**

```swift
import AppKit
import SwiftUI

@MainActor
class AIFloatingPanelController {
    private var window: NSWindow?
    private let session: AISessionStore
    private var onExpand: (() -> Void)?

    init(session: AISessionStore, onExpand: (() -> Void)? = nil) {
        self.session = session
        self.onExpand = onExpand
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }

        let view = AIFloatingPanelView(session: session, onExpand: {
            self.hide()
            self.onExpand?()
        })

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 280, height: 200)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = hosting
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true

        // Position bottom-right of main screen
        if let screen = NSScreen.main {
            let rect = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: rect.maxX - 300, y: rect.minY + 20))
        }

        panel.makeKeyAndOrderFront(nil)
        self.window = panel
    }

    func hide() {
        window?.close()
        window = nil
    }

    func toggle() {
        if window != nil { hide() } else { show() }
    }
}
```

- [ ] **Build:** `xcodebuild -project Desire.xcodeproj -scheme Desire build`

---

### Task 9: Integration (ContentView, Toolbar, Settings, WebView)

**Files:**
- Modify: `Desire/Views/ContentView.swift`
- Modify: `Desire/Features/Toolbar/Toolbar.swift`
- Modify: `Desire/App/DesireApp.swift`
- Modify: `Desire/Features/Settings/SettingsView.swift`
- Modify: `Desire/Features/Settings/GeneralSettingsSection.swift`
- Modify: `Desire/Features/Browsing/WebView.swift` (add `onAIElementPicked` callback)
- Modify: `Desire/Features/Tabs/TabManager.swift` (pass `AIPreferenceStore` to tabs)

- [ ] **In ContentView.swift:**

Add state:
```swift
@StateObject private var aiPreference = AIPreferenceStore()
@State private var showAIPanel = false
@State private var showAIFloating = false
```

Add to the `@StateObject` list near line 26:
```swift
@StateObject private var aiPreference = AIPreferenceStore()
```

Add AI panel + floating controller:
```swift
@State private var showAIPanel = false
@State private var showAIFloating = false
@State private var aiFloatingController: AIFloatingPanelController?
```

After `tabManager` init:
```swift
tabManager.aiPreference = aiPreference
```

Add AI toggle to the toolbar actions (in the `Toolbar` call):
```swift
toggleAI: { showAIPanel.toggle() },
```

Add the AI panel overlay in the `ZStack` (after the web view):
```swift
if showAIPanel, let tab = tabManager.selectedTab {
    HStack(spacing: 0) {
        Spacer()
        AIPanel(
            session: tab.aiSession,
            isVisible: $showAIPanel,
            onPickElement: {
                tab.browser.isPickingElement = true
                tab.browser.onAIElementPicked = { selector, html in
                    tab.browser.isPickingElement = false
                    tab.browser.onAIElementPicked = nil
                    tab.aiSession.addContext(html: html, selector: selector)
                }
            },
            onToggleFloating: {
                showAIPanel = false
                if aiFloatingController == nil {
                    aiFloatingController = AIFloatingPanelController(session: tab.aiSession, onExpand: {
                        showAIPanel = true
                    })
                }
                aiFloatingController?.toggle()
            }
        )
    }
    .transition(.move(edge: .trailing))
    .animation(.easeInOut(duration: 0.2), value: showAIPanel)
}
```

Add `allow` command for `.toggleAI` in `handleCommand`:
```swift
case .toggleAI:
    showAIPanel.toggle()
```

Add `.toggleAI` to `BrowserCommand` enum in DesireApp.swift.

- [ ] **In Toolbar.swift:**

Add to `Actions`:
```swift
let toggleAI: () -> Void
```

Add AI button in the toolbar HStack:
```swift
HoverIcon(systemName: "brain", action: actions.toggleAI, help: "AI Assistant")
```

- [ ] **In DesireApp.swift:**

Add to `BrowserCommand`:
```swift
case toggleAI
```

Add menu item in the View menu:
```swift
Button("AI Assistant") { postCommand(.toggleAI) }
.keyboardShortcut("i", modifiers: [.command, .shift])
```

- [ ] **In TabManager.swift:**

Add:
```swift
var aiPreference: AIPreferenceStore?
```

In `TabManager`, update `Tab` to hold an `AISessionStore`:
```swift
class Tab: ObservableObject {
    ...
    let aiSession: AISessionStore
    ...
}
```

In Tab init, create the AI session:
```swift
aiSession = AISessionStore(preference: aiPreference ?? AIPreferenceStore())
```

And set the webView on the session when the webView is ready (in `TabManager` after creating the tab):
```swift
tab.aiSession.setWebView(tab.browser.webView)
```

- [ ] **In SettingsView.swift:**

Add AI section:
```swift
Section("AI") {
    NavigationLink("AI Configuration") {
        AISettingsView(store: aiPreference)
    }
}
```

- [ ] **Create `Desire/Features/AI/AISettingsView.swift`:**

```swift
import SwiftUI

struct AISettingsView: View {
    @ObservedObject var store: AIPreferenceStore
    @State private var apiKeyInput = ""

    var body: some View {
        Form {
            Section("API Configuration") {
                if store.hasAPIKey {
                    HStack {
                        Text("API Key")
                        Spacer()
                        Text("••••••••")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Button("Change") {
                            apiKeyInput = store.loadAPIKey() ?? ""
                            store.deleteAPIKey()
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                    }
                } else {
                    SecureField("API Key", text: $apiKeyInput)
                    Button("Save Key") {
                        store.saveAPIKey(apiKeyInput)
                        apiKeyInput = ""
                    }
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                TextField("Endpoint", text: $store.endpoint)
                    .font(.caption)

                TextField("Model", text: $store.model)
                    .font(.caption)
            }

            Section("Parameters") {
                HStack {
                    Text("Max Tokens")
                    Spacer()
                    TextField("", value: $store.maxTokens, format: .number)
                        .frame(width: 80)
                        .font(.caption)
                }
                HStack {
                    Text("Temperature")
                    Spacer()
                    Slider(value: $store.temperature, in: 0...2, step: 0.1)
                        .frame(width: 120)
                    Text(String(format: "%.1f", store.temperature))
                        .font(.caption)
                        .frame(width: 24)
                }
            }

            Section("System Prompt") {
                TextEditor(text: $store.systemPrompt)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 200)
            }
        }
        .padding()
        .frame(width: 500)
    }
}
```

- [ ] **Build:** `xcodebuild -project Desire.xcodeproj -scheme Desire build` — fix any integration issues
