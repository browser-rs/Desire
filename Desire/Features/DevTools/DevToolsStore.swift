import Combine
import Foundation
import WebKit

@MainActor
class DevToolsStore: ObservableObject {
    @Published var consoleMessages: [ConsoleMessage] = []
    @Published var networkRequests: [NetworkRequest] = []
    @Published var inspectedElement: InspectedElement?
    @Published var isInspectingElement = false
    @Published var isDevModeEnabled = false
    @Published var activePanel: DevPanel = .console
    @Published var pendingRequests: [UUID: NetworkRequest] = [:]

    /// 面板的标签页作用域。Console / Network 的数据源是 app 级共享 store
    /// （每个 webview 都往同一实例发消息），所以必须能按标签页收敛：
    /// `current` 跟随面板所在标签页，`all` 是全部标签页的合并流，
    /// `tab(id)` 锁定某一个（含已关闭的标签页，便于回头看它留下的日志）。
    enum TabScope: Equatable, Hashable {
        case current
        case all
        case tab(UUID)

        /// 桥/持久化用的字符串形式：`current` / `all` / UUID 串。
        var bridgeValue: String {
            switch self {
            case .current: "current"
            case .all: "all"
            case .tab(let id): id.uuidString
            }
        }

        init?(bridgeValue: String) {
            switch bridgeValue {
            case "current": self = .current
            case "all": self = .all
            default:
                guard let id = UUID(uuidString: bridgeValue) else { return nil }
                self = .tab(id)
            }
        }
    }

    @Published var tabScope: TabScope = .current

    /// 面板所在的标签页（`DevToolsPanel` 在标签页变化时写入）。`.current`
    /// 由它解析；解析不到（面板尚未挂上）时退化为不过滤。
    @Published var activeTabID: UUID?

    /// 消息里出现过的标签页（作用域菜单的标题来源）。按首次出现排序——
    /// 菜单开着时不会跳来跳去；标题随导航更新。
    struct TabRef: Identifiable, Equatable {
        let id: UUID
        var title: String?
        var url: String?
    }

    @Published private(set) var knownTabs: [TabRef] = []
    private let knownTabsCap = 20

    /// 当前作用域解析出的标签页（nil = 不过滤）。
    var scopedTabID: UUID? {
        switch tabScope {
        case .all: nil
        case .current: activeTabID
        case .tab(let id): id
        }
    }

    func isInScope(_ tabID: UUID?) -> Bool {
        guard let scoped = scopedTabID else { return true }
        return tabID == scoped
    }

    var scopedConsoleMessages: [ConsoleMessage] { consoleMessages.filter { isInScope($0.tabID) } }
    var scopedNetworkRequests: [NetworkRequest] { networkRequests.filter { isInScope($0.tabID) } }

    /// 作用域内的计数（面板徽章与桥共用）。数组本身有上限（1000 / 500），
    /// 直接扫描比维护增量不容易出错——增量在"按标签页清除"后会立刻失真。
    var consoleErrorCount: Int { scopedConsoleMessages.filter { $0.level == .error }.count }
    var consoleWarningCount: Int { scopedConsoleMessages.filter { $0.level == .warn }.count }
    var networkFailedCount: Int { scopedNetworkRequests.filter(\.failed).count }

    /// 登记/更新一个标签页（标题与 URL 供作用域菜单显示）。
    /// 只有内容真的变了才写回——这条路径会被每条 console/network 消息调用，
    /// 每次发布都会让面板重绘。
    func noteTab(id: UUID, title: String? = nil, url: String? = nil) {
        if let index = knownTabs.firstIndex(where: { $0.id == id }) {
            var ref = knownTabs[index]
            var changed = false
            if let title, !title.isEmpty, ref.title != title {
                ref.title = title
                changed = true
            }
            if let url, !url.isEmpty, ref.url != url {
                ref.url = url
                changed = true
            }
            if changed { knownTabs[index] = ref }
            return
        }
        knownTabs.append(TabRef(id: id, title: title, url: url))
        if knownTabs.count > knownTabsCap {
            knownTabs.removeFirst(knownTabs.count - knownTabsCap)
        }
    }

    /// 作用域菜单里的显示名：标题 → 主机+路径 → 短 id。
    ///
    /// 标题常常拿不到（WebKit 的 title 晚于首次消息，标签页可能还没进过前台），
    /// 此时只给主机名会让同一站点的多个标签页看起来一模一样，所以带上路径。
    func displayName(for ref: TabRef) -> String {
        if let title = ref.title, !title.isEmpty { return title }
        if let url = ref.url, let parsed = URL(string: url), let host = parsed.host, !host.isEmpty {
            let path = parsed.path
            return (path.isEmpty || path == "/") ? host : host + path
        }
        return String(ref.id.uuidString.prefix(8))
    }

    /// Max retained console entries.
    private let consoleCap = 1000
    /// 每条长连接（WebSocket / SSE）保留的消息帧上限——流是无限的。
    private let frameCap = 200
    /// 网络面板条目上限（0.3.4）：无上限时长会话里 chatter 页面能让
    /// 数组无限增长。500 条覆盖任何合理检查窗口。
    private let networkCap = 500

    enum DevPanel: String, CaseIterable {
        case console = "Console"
        case network = "Network"
        case element = "Element"
        /// Chrome 的 Application 页签：Cookie / localStorage / sessionStorage。
        case application = "Application"
    }

    /// 插件存储（Application 页签的"扩展存储"）。Store 依赖 Store 是允许的
    /// 模式；由 SystemState 在构造后接线（两边都归它所有）。
    var pluginStore: PluginStore?

    init() {}

    func addConsoleMessage(level: ConsoleMessage.Level, message: String, url: String? = nil, line: Int? = nil, column: Int? = nil, tabID: UUID? = nil, parts: [ConsoleMessage.Part]? = nil) {
        let msg = ConsoleMessage(level: level, message: message, url: url, line: line, column: column, tabID: tabID, parts: parts)
        // Mutate the backing array once (append + optional trim), then publish
        // a single time. The previous append-then-trim sequence published twice.
        var newMessages = consoleMessages
        newMessages.append(msg)
        if newMessages.count > consoleCap {
            newMessages.removeFirst(newMessages.count - consoleCap)
        }
        consoleMessages = newMessages
    }

    /// 清空所有标签页的日志。
    func clearConsole() {
        consoleMessages.removeAll()
    }

    /// 只清一个标签页的日志（`clearConsoleOnNavigate` 走这条：导航的是那个
    /// 标签页，不该顺手抹掉别的标签页的日志）。
    func clearConsole(tabID: UUID) {
        consoleMessages.removeAll { $0.tabID == tabID }
    }

    /// 面板"清除"按钮：清掉当前作用域内的条目（作用域是"全部"就是全部）。
    func clearConsoleInScope() {
        if let scoped = scopedTabID {
            consoleMessages.removeAll { $0.tabID == scoped }
        } else {
            consoleMessages.removeAll()
        }
    }

    func startNetworkRequest(url: String, method: String, resourceType: NetworkRequest.ResourceType, requestHeaders: [String: String]? = nil, requestBody: String? = nil, tabID: UUID? = nil) -> UUID {
        let request = NetworkRequest(url: url, method: method, resourceType: resourceType, requestHeaders: requestHeaders, requestBody: requestBody, tabID: tabID)
        pendingRequests[request.id] = request
        networkRequests.append(request)
        if networkRequests.count > networkCap {
            networkRequests.removeFirst(networkRequests.count - networkCap)
        }
        return request.id
    }

    func completeNetworkRequest(id: UUID, statusCode: Int, statusText: String?, mimeType: String?, responseHeaders: [String: String]?, responseBody: String?) {
        guard let pending = pendingRequests[id] else { return }
        let completed = pending.completed(statusCode: statusCode, statusText: statusText, mimeType: mimeType, responseHeaders: responseHeaders, responseBody: responseBody)
        pendingRequests.removeValue(forKey: id)
        if let index = networkRequests.firstIndex(where: { $0.id == id }) {
            networkRequests[index] = completed
        }
    }

    func failNetworkRequest(id: UUID, error: String) {
        guard let pending = pendingRequests[id] else { return }
        let failed = pending.failed(error: error)
        pendingRequests.removeValue(forKey: id)
        if let index = networkRequests.firstIndex(where: { $0.id == id }) {
            networkRequests[index] = failed
        }
    }

    /// 清空所有标签页的请求记录。
    func clearNetworkRequests() {
        networkRequests.removeAll()
        pendingRequests.removeAll()
        jsRequestIDs.removeAll()
    }

    /// 面板"清除"按钮：只清当前作用域内的请求。
    func clearNetworkRequestsInScope() {
        if let scoped = scopedTabID {
            let removed = Set(networkRequests.filter { $0.tabID == scoped }.map(\.id))
            guard !removed.isEmpty else { return }
            networkRequests.removeAll { removed.contains($0.id) }
            pendingRequests = pendingRequests.filter { !removed.contains($0.key) }
        } else {
            clearNetworkRequests()
        }
    }

    func setInspectedElement(_ element: InspectedElement?) {
        inspectedElement = element
        isInspectingElement = false
    }

    func toggleDevMode() {
        isDevModeEnabled.toggle()
        if !isDevModeEnabled {
            isInspectingElement = false
            inspectedElement = nil
        }
    }

    func setActivePanel(_ panel: DevPanel) {
        activePanel = panel
    }

    var networkPendingCount: Int {
        pendingRequests.values.filter { isInScope($0.tabID) }.count
    }

    /// 当前作用域内已记录请求的传输字节合计。
    var networkTotalBytes: Int64 {
        scopedNetworkRequests.reduce(0) { $0 + ($1.size ?? 0) }
    }

    /// JS 侧生成的请求 id → store 的请求 id（fetch/XHR 钩子先 start、
    /// 再 complete/body 两次上报，需要把同一条请求串起来）。
    private var jsRequestIDs: [String: UUID] = [:]

    /// 处理 `network-monitor.js` 上报的一条事件。
    ///
    /// phase: `start`（fetch/XHR 发起）/ `complete`（含 PerformanceObserver 的
    /// 一次性上报）/ `body`（响应体截断文本）。没有 jsId 的 complete 视为独立
    /// 资源（PerformanceObserver），按 URL 与最近 2s 内 start 过的请求去重。
    ///
    /// `tabID` 是上报它的标签页：既写进新请求，也参与去重（同一个 URL 在
    /// 两个标签页里各发一次是两条请求，不能互相吞掉）。
    func applyNetworkEvent(_ dict: [String: Any], tabID: UUID? = nil) {
        let phase = (dict["phase"] as? String) ?? "complete"
        guard let url = dict["url"] as? String, !url.isEmpty else { return }
        // 自家注入/数据 URL 不进面板。
        if url.hasPrefix("data:") || url.hasPrefix("blob:") || url.hasPrefix("about:") { return }
        let method = ((dict["method"] as? String) ?? "GET").uppercased()
        let type = NetworkRequest.ResourceType(rawValue: (dict["resourceType"] as? String) ?? "other") ?? .other
        let jsId = dict["jsId"] as? String
        let status = dict["status"] as? Int
        let duration = dict["duration"] as? Double
        let size = (dict["size"] as? NSNumber)?.int64Value
        let fromCache = dict["fromCache"] as? Bool
        var timing: NetworkRequest.Timing?
        if let raw = dict["timing"] as? [String: Any] {
            func seconds(_ key: String) -> Double? { (raw[key] as? NSNumber)?.doubleValue }
            let parsed = NetworkRequest.Timing(
                blocked: seconds("blocked"),
                dns: seconds("dns"),
                connect: seconds("connect"),
                tls: seconds("tls"),
                ttfb: seconds("ttfb"),
                download: seconds("download")
            )
            timing = parsed
        }
        let headers = dict["responseHeaders"] as? [String: String]
        let reqBody = dict["requestBody"] as? String
        let respBody = dict["responseBody"] as? String
        let mime = dict["mimeType"] as? String
        let initiator = dict["initiator"] as? String
        let streaming = dict["streaming"] as? Bool ?? false

        // 长连接的消息帧：挂到对应请求上（连接本身早就报过 start）。
        if phase == "frame" {
            let direction = NetworkRequest.Frame.Direction(rawValue: (dict["direction"] as? String) ?? "in") ?? .system
            let payload = (dict["payload"] as? String) ?? ""
            let target = jsId.flatMap { jsRequestIDs[$0] } ?? recentRequestID(url: url, tabID: tabID)
            guard let target, let index = networkRequests.firstIndex(where: { $0.id == target }) else { return }
            networkRequests[index] = networkRequests[index]
                .addingFrame(NetworkRequest.Frame(direction: direction, payload: payload), cap: frameCap)
            return
        }

        // 已有请求：补全。
        let existingID = jsId.flatMap { jsRequestIDs[$0] }
            ?? (jsId == nil ? recentRequestID(url: url, tabID: tabID) : nil)
        if let id = existingID, let index = networkRequests.firstIndex(where: { $0.id == id }) {
            networkRequests[index] = networkRequests[index].completedFromJS(
                statusCode: status,
                duration: duration,
                timing: timing,
                fromCache: fromCache,
                size: size,
                mimeType: mime,
                responseHeaders: headers,
                requestBody: reqBody,
                responseBody: respBody
            )
            if let jsId { jsRequestIDs[jsId] = id }
            if let status, status >= 400 { noticeFailure(of: id) }
            return
        }
        guard phase != "body" else { return }   // 没有对应请求的 body 事件忽略

        // 新请求。
        var request = NetworkRequest(
            url: url,
            method: method,
            resourceType: type,
            requestBody: reqBody,
            tabID: tabID,
            initiator: initiator,
            streaming: streaming
        )
        if status != nil || duration != nil || size != nil || headers != nil || respBody != nil {
            request = request.completedFromJS(
                statusCode: status,
                duration: duration,
                timing: timing,
                fromCache: fromCache,
                size: size,
                mimeType: mime,
                responseHeaders: headers,
                responseBody: respBody
            )
        }
        networkRequests.append(request)
        if networkRequests.count > networkCap {
            networkRequests.removeFirst(networkRequests.count - networkCap)
        }
        if let jsId { jsRequestIDs[jsId] = request.id }
        if let status, status >= 400 { noticeFailure(of: request.id) }
    }

    /// 最近的、同 URL（且同标签页）未完成的请求（PerformanceObserver 去重用）。
    private func recentRequestID(url: String, tabID: UUID?) -> UUID? {
        networkRequests.last { $0.url == url && $0.tabID == tabID && $0.statusCode == nil && !$0.failed }?.id
    }

    private func noticeFailure(of id: UUID) {
        guard let index = networkRequests.firstIndex(where: { $0.id == id }),
              !networkRequests[index].failed else { return }
        networkRequests[index] = networkRequests[index].failed(error: networkRequests[index].statusText ?? "HTTP \(networkRequests[index].statusCode ?? 0)")
    }

    /// Application 页签的子页签（放到 store 里：既能跨面板重建保持，也便于
    /// 自动化直接选中某一节）。
    enum ApplicationSection: String, CaseIterable {
        case cookies, localStorage, sessionStorage, extensionStorage
        case indexedDB, cacheStorage, serviceWorkers

        var title: String {
            switch self {
            case .cookies: String(localized: "Cookies")
            case .localStorage: StorageKind.local.title
            case .sessionStorage: StorageKind.session.title
            case .extensionStorage: String(localized: "Extension Storage")
            case .indexedDB: String(localized: "IndexedDB")
            case .cacheStorage: String(localized: "Cache Storage")
            case .serviceWorkers: String(localized: "Service Workers")
            }
        }

        var icon: String {
            switch self {
            case .cookies: "birthday.cake"
            case .localStorage: "internaldrive"
            case .sessionStorage: "clock.arrow.circlepath"
            case .extensionStorage: "puzzlepiece.extension"
            case .indexedDB: "cylinder.split.1x2"
            case .cacheStorage: "square.stack.3d.up"
            case .serviceWorkers: "gearshape.2"
            }
        }

        var storageKind: StorageKind? {
            switch self {
            case .cookies, .extensionStorage, .indexedDB, .cacheStorage, .serviceWorkers: nil
            case .localStorage: .local
            case .sessionStorage: .session
            }
        }

        /// 值可改的节：Web 存储与插件存储（行内编辑）；Cookie 的值也可改
        /// （走 `WKHTTPCookieStore.setCookie`，见 `setCookie`）。
        var isEditable: Bool {
            switch self {
            case .localStorage, .sessionStorage, .extensionStorage, .cookies: true
            case .indexedDB, .cacheStorage, .serviceWorkers: false
            }
        }

        /// 只读节（列举 + 删除，不能新增/改值）。
        var isReadOnly: Bool { !isEditable }
    }

    // MARK: - Application ▸ IndexedDB / Cache Storage / Service Worker

    /// 一个 IndexedDB 对象存储（库名 + 版本 + 存储名 + 条数）。
    struct IndexedDBStore: Identifiable, Hashable, Codable {
        let database: String
        let version: Int
        let name: String
        let count: Int

        var id: String { "\(database)\u{1}\(name)" }
    }

    /// Cache Storage 里的一条缓存条目。
    struct CacheEntry: Identifiable, Hashable, Codable {
        let cache: String
        let url: String
        let method: String

        var id: String { "\(cache)\u{1}\(method)\u{1}\(url)" }
    }

    /// 一个 Service Worker 注册。
    struct ServiceWorkerRegistration: Identifiable, Hashable, Codable {
        let scope: String
        let scriptURL: String
        let state: String

        var id: String { scope }
    }

    /// 页面侧数据源脚本（`page-storage.js`）的统一入口：传 `mode` 与参数，
    /// 拿回 JSON 字符串。异常抛出（面板/桥都要能看到原因）。
    private func runPageStorage(mode: String, _ extra: [String: Any] = [:], in webView: WKWebView) async throws -> String {
        let script = UserScriptLoader.load("page-storage")
        guard !script.isEmpty else { throw PageStorageError.scriptMissing }
        var arguments: [String: Any] = ["mode": mode]
        for (key, value) in extra { arguments[key] = value }
        let result = try await webView.callAsyncJavaScript(
            script,
            arguments: arguments,
            in: nil,
            contentWorld: .page
        )
        guard let json = result as? String else { throw PageStorageError.emptyResult }
        return json
    }

    enum PageStorageError: Error {
        case scriptMissing
        case emptyResult
    }

    private func decodePageStorage<T: Decodable>(_ type: T.Type, mode: String, _ extra: [String: Any] = [:], in webView: WKWebView) async -> T? {
        guard let json = try? await runPageStorage(mode: mode, extra, in: webView),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private struct IndexedDBPayload: Decodable { let stores: [IndexedDBStore]? }
    private struct CachePayload: Decodable { let entries: [CacheEntry]? }
    private struct ServiceWorkerPayload: Decodable { let workers: [ServiceWorkerRegistration]? }

    func loadIndexedDB(in webView: WKWebView) async -> [IndexedDBStore] {
        let payload = await decodePageStorage(IndexedDBPayload.self, mode: "idb-list", in: webView)
        return payload?.stores ?? []
    }

    func loadCacheStorage(in webView: WKWebView) async -> [CacheEntry] {
        let payload = await decodePageStorage(CachePayload.self, mode: "cache-list", ["limit": 300], in: webView)
        return payload?.entries ?? []
    }

    func loadServiceWorkers(in webView: WKWebView) async -> [ServiceWorkerRegistration] {
        let payload = await decodePageStorage(ServiceWorkerPayload.self, mode: "sw-list", in: webView)
        return payload?.workers ?? []
    }

    /// 删除一个 IndexedDB 库（该库的所有对象存储一起没了）。返回页面侧的结果
    /// JSON（`{"ok":…}`），便于桥断言。
    @discardableResult
    func deleteDatabase(named name: String, in webView: WKWebView) async -> String? {
        try? await runPageStorage(mode: "idb-delete", ["name": name], in: webView)
    }

    /// 删一条缓存条目 / 清空所有缓存 / 注销 Service Worker。
    func deleteCacheEntry(cache: String, url: String, in webView: WKWebView) async {
        _ = try? await runPageStorage(mode: "cache-delete", ["cacheName": cache, "url": url], in: webView)
    }

    @discardableResult
    func clearCaches(in webView: WKWebView) async -> String? {
        try? await runPageStorage(mode: "cache-clear", in: webView)
    }

    @discardableResult
    func unregisterServiceWorker(scope: String, in webView: WKWebView) async -> String? {
        try? await runPageStorage(mode: "sw-unregister", ["scope": scope], in: webView)
    }

    @discardableResult
    func unregisterAllServiceWorkers(in webView: WKWebView) async -> String? {
        try? await runPageStorage(mode: "sw-unregister", in: webView)
    }

    /// 写一个 Cookie（新增或改值）：走 `WKHTTPCookieStore`，因此 HttpOnly 的
    /// 也能写——`document.cookie` 那条路写不了它们。
    func setCookie(_ cookie: HTTPCookie, in dataStore: WKWebsiteDataStore) async {
        await dataStore.httpCookieStore.setCookie(cookie)
    }

    /// 由面板的"新增 Cookie"行构造一个 Cookie：域/路径按当前页面补默认值。
    func makeCookie(name: String, value: String, domain: String, path: String, secure: Bool, httpOnly: Bool) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path.isEmpty ? "/" : path,
        ]
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    @Published var applicationSection: ApplicationSection = .cookies

    /// 导航时是否清空控制台（默认否：保留日志便于对比前后两次加载）。
    @Published var clearConsoleOnNavigate = UserDefaults.standard.bool(forKey: "devtoolsClearConsoleOnNavigate") {
        didSet { UserDefaults.standard.set(clearConsoleOnNavigate, forKey: "devtoolsClearConsoleOnNavigate") }
    }

    /// 改元素的内联样式（`value` 为 nil = 删除该属性）。改完立刻重新采集。
    func setElementStyle(selector: String, name: String, value: String?, in webView: WKWebView) async {
        let script: String
        if let value {
            script = "el.style.setProperty('\(Self.escapeJS(name))', '\(Self.escapeJS(value))');"
        } else {
            script = "el.style.removeProperty('\(Self.escapeJS(name))');"
        }
        await runElementMutation(selector: selector, body: script, in: webView)
    }

    /// 改元素属性（`value` 为 nil = 删除该属性）。
    func setElementAttribute(selector: String, name: String, value: String?, in webView: WKWebView) async {
        let script: String
        if let value {
            script = "el.setAttribute('\(Self.escapeJS(name))', '\(Self.escapeJS(value))');"
        } else {
            script = "el.removeAttribute('\(Self.escapeJS(name))');"
        }
        await runElementMutation(selector: selector, body: script, in: webView)
    }

    /// 悬停元素条目时在页面上描边（离开时撤掉）——比对着 selector 找快得多。
    func highlightElement(selector: String, on: Bool, in webView: WKWebView) {
        let body = on
            ? "el.style.setProperty('outline', '2px solid #FF2D55', 'important'); el.style.setProperty('outline-offset', '1px');"
            : "el.style.removeProperty('outline'); el.style.removeProperty('outline-offset');"
        let script = """
        (function() {
            var el = document.querySelector('\(selector)');
            if (!el) return;
            \(body)
        })()
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func runElementMutation(selector: String, body: String, in webView: WKWebView) async {
        let script = """
        (function() {
            var el = document.querySelector('\(selector)');
            if (!el) return 'not-found';
            \(body)
            return 'ok';
        })()
        """
        _ = try? await webView.callAsyncJavaScript(
            "return (function(){ \(script) })()",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        await inspectElement(selector: selector, in: webView)
    }

    private static func escapeJS(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// 按选择器采集一个元素（DevTools ▸ Element 页签）。
    /// JS 在 `UserScripts/element-inspect.js`，返回 `InspectedElement` 形状的 JSON。
    func inspectElement(selector: String, in webView: WKWebView) async {
        let escaped = selector
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let script = UserScriptLoader.load("element-inspect")
            .replacingOccurrences(of: "__SELECTOR__", with: escaped)
        guard !script.isEmpty else { return }
        isInspectingElement = false
        let raw: String? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
        guard let raw, let data = raw.data(using: .utf8),
              let element = try? JSONDecoder().decode(InspectedElement.self, from: data) else { return }
        setInspectedElement(element)
    }

    // MARK: - Application（Cookie / Web 存储）

    /// 读当前标签页数据存储里的 Cookie。
    ///
    /// 与设置里的"Cookie 管理"不同，这里读的是**该标签页所在的**
    /// `WKWebsiteDataStore`（容器标签、无痕标签各有自己的存储），所以看到的就是
    /// 这个页面真正的 Cookie。HttpOnly 的也在这里（`document.cookie` 看不到）。
    func loadCookies(in dataStore: WKWebsiteDataStore) async -> [CookieEntry] {
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { cookies in
                let entries = cookies.map { cookie in
                    CookieEntry(
                        domain: cookie.domain,
                        name: cookie.name,
                        value: cookie.value,
                        path: cookie.path,
                        expiryDate: cookie.expiresDate,
                        isSecure: cookie.isSecure,
                        isHttpOnly: cookie.isHTTPOnly,
                        sameSitePolicy: Self.sameSiteLabel(cookie)
                    )
                }
                continuation.resume(returning: entries.sorted { ($0.domain, $0.name) < ($1.domain, $1.name) })
            }
        }
    }

    /// SameSite 徽章：`HTTPCookie.sameSitePolicy` 是公开 API（macOS 10.15+）。
    /// 没用 KVC 猜私有键——`value(forKey: "_sameSitePolicy")` 会抛
    /// NSUnknownKeyException 直接 abort（2026-09-20 23:01 崩溃报告）。
    ///
    /// **只认显式声明过 SameSite 的 Cookie**：没声明时 `sameSitePolicy` 照样返回值，
    /// 而 `HTTPCookieStringPolicy` 是个 struct（没有 `.none` 这个成员）——写
    /// `policy == .none` 实际是在跟 `Optional.none` 比、**恒为 false**（编译器警告），
    /// 于是"看 properties 里有没有 samesite 键"那段成了死代码。判定只能靠 properties：
    /// 有键才挂徽章（Chrome 也是空单元格）。
    private static func sameSiteLabel(_ cookie: HTTPCookie) -> String? {
        let declared = cookie.properties?.keys.contains { $0.rawValue.lowercased().contains("samesite") } ?? false
        guard declared, let policy = cookie.sameSitePolicy else { return nil }
        return policy.rawValue
    }

    func deleteCookie(name: String, domain: String, path: String, in dataStore: WKWebsiteDataStore) async {
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        for cookie in cookies where cookie.name == name && cookie.domain == domain && cookie.path == path {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                dataStore.httpCookieStore.delete(cookie) { continuation.resume() }
            }
        }
    }

    /// 清空该数据存储里的全部 Cookie（两步确认在 UI 层做，不用模态框）。
    func clearCookies(in dataStore: WKWebsiteDataStore) async {
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        for cookie in cookies {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                dataStore.httpCookieStore.delete(cookie) { continuation.resume() }
            }
        }
    }

    // MARK: 扩展存储（插件 chrome.storage.local）

    struct ExtensionSnapshot: Identifiable {
        let id: String
        let name: String
        let items: [String: String]
    }

    /// 已安装插件（用户插件 + .msex 扩展）的 `storage.local` 快照。插件存储
    /// 后端是 `WebExtensionStore`（UserDefaults 的 `desire.webext.storage.<id>`
    /// 桶），所以直接读内存，无需异步。
    func extensionStorageSnapshots() -> [ExtensionSnapshot] {
        guard let pluginStore else { return [] }
        var snapshots = pluginStore.plugins.map { plugin in
            ExtensionSnapshot(id: plugin.id.uuidString, name: plugin.name, items: Self.displayItems(WebExtensionStore.get(keys: nil, ext: plugin.id.uuidString)))
        }
        .sorted { $0.name < $1.name }
        // 0.2.13 的共享桶（没有插件身份的写入，历史数据）：有内容才列出来，
        // 免得用户以为数据消失了。
        let legacy = WebExtensionStore.get(keys: nil, ext: nil)
        if !legacy.isEmpty {
            snapshots.append(ExtensionSnapshot(id: "", name: String(localized: "Shared (legacy)"), items: Self.displayItems(legacy)))
        }
        return snapshots
    }

    /// 任意 JSON 值 → 可展示的文本（字符串原样，对象/数组转 JSON）。
    private static func displayItems(_ raw: [String: Any]) -> [String: String] {
        var items: [String: String] = [:]
        for (key, value) in raw {
            if let text = value as? String {
                items[key] = text
            } else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
                      let text = String(data: data, encoding: .utf8) {
                items[key] = text
            } else {
                items[key] = String(describing: value)
            }
        }
        return items
    }

    /// 改/删某插件 `storage.local` 的一项（`value` 为 nil = 删除）。
    /// 能解析成 JSON 的文本按 JSON 存（插件读回的是对象），否则存字符串。
    /// `pluginID` 为空字符串 = 0.2.13 的共享桶（`WebExtensionStore` 用空串
    /// 当作无身份）。面板的行 id 用 `"<extID>|<key>"`，共享桶的 extID 就是 ""。
    func setExtensionStorageValue(pluginID: String, key: String, value: String?) {
        let ext: String? = pluginID.isEmpty ? nil : pluginID
        guard let value else {
            WebExtensionStore.remove(keys: [key], ext: ext)
            return
        }
        let parsed: Any = (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed])) ?? value
        WebExtensionStore.set(items: [key: parsed], ext: ext)
    }

    struct StorageItem: Identifiable, Hashable, Decodable {
        let key: String
        let value: String
        let bytes: Int
        var id: String { key }
    }

    /// 读页面的 localStorage / sessionStorage（走页面 JS，所以拿到的是页面自己
    /// 看到的那份；无痕/容器标签自然隔离）。
    func loadWebStorage(kind: StorageKind, in webView: WKWebView) async -> [StorageItem] {
        let script = """
        (function() {
            var store = \(kind == .local ? "window.localStorage" : "window.sessionStorage");
            var out = [];
            for (var i = 0; i < store.length; i++) {
                var key = store.key(i);
                var value = store.getItem(key);
                out.push({ key: key, value: value == null ? '' : value, bytes: (key + value).length });
            }
            return JSON.stringify(out);
        })()
        """
        let raw: String? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
        guard let raw, let data = raw.data(using: .utf8),
              let items = try? JSONDecoder().decode([StorageItem].self, from: data) else { return [] }
        return items
    }

    enum StorageKind: String, CaseIterable {
        case local, session

        var title: String {
            switch self {
            case .local: String(localized: "Local Storage")
            case .session: String(localized: "Session Storage")
            }
        }
    }

    /// 写一条 Web 存储（页面 JS，立即生效；key 不存在时即新增）。
    func setStorageItem(kind: StorageKind, key: String, value: String, in webView: WKWebView) async {
        let store = kind == .local ? "window.localStorage" : "window.sessionStorage"
        let script = "\(store).setItem(\(jsString(key)), \(jsString(value))); 'ok'"
        _ = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    /// 单引号安全的 JS 字符串字面量（存储值里出现引号/换行是常态）。
    private func jsString(_ text: String) -> String {
        var out = "'"
        for ch in text {
            switch ch {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default: out.append(ch)
            }
        }
        return out + "'"
    }

    /// 删除/清空 Web 存储（页面 JS，立即生效）。
    func removeStorageItem(kind: StorageKind, key: String?, in webView: WKWebView) async {
        let store = kind == .local ? "window.localStorage" : "window.sessionStorage"
        let script: String
        if let key {
            script = "\(store).removeItem(\(jsString(key))); 'ok'"
        } else {
            script = "\(store).clear(); 'ok'"
        }
        _ = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    /// 把响应体写到下载目录（排查接口时把大 JSON 存下来慢慢看）。
    func saveResponseBody(_ request: NetworkRequest) -> URL? {
        guard let body = request.responseBody, !body.isEmpty else { return nil }
        let name = URL(string: request.url)?.lastPathComponent
        let base = (name?.isEmpty == false ? name! : "response")
        guard let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent("desire-\(base).txt") else { return nil }
        try? body.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return url
    }

    /// 导出网络日志（JSON，够用又不至于做成 HAR 规范）。
    func exportNetworkLog(_ requests: [NetworkRequest]) -> URL? {
        let rows: [[String: Any]] = requests.map { request in
            var row: [String: Any] = [
                "method": request.method,
                "url": request.url,
                "type": request.resourceType.rawValue,
            ]
            if let status = request.statusCode { row["status"] = status }
            if let duration = request.duration { row["durationMs"] = Int(duration * 1000) }
            if let size = request.size { row["bytes"] = size }
            if let cached = request.fromCache { row["fromCache"] = cached }
            if let headers = request.responseHeaders { row["responseHeaders"] = headers }
            return row
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        guard let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent("desire-network-\(stamp).json"),
              let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        try? data.write(to: url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return url
    }

    // MARK: - Console REPL

    /// 控制台里手输的一行 JS：执行并把"输入 + 结果/异常"写进日志。
    ///
    /// 先按输入形态选路径（`looksLikeStatement`），避免先撞一次语法错——那次失败
    /// 会被页面的 window.onerror 记成 "Script error." 噪声行。异常文本要用
    /// `WKJavaScriptExceptionMessage`（见 AGENTS.md）。
    /// REPL 的便捷绑定（Chrome 同款）：`$0` = 最后检查的元素、`$_` = 上一次的结果、
    /// `$(sel)` / `$$(sel)` = querySelector(All) 简写。页面自己定义了 `$`
    /// （jQuery 之类）就不覆盖。
    private static let replPreamble = """
    if (!window.$) { window.$ = document.querySelector.bind(document); window.$$ = document.querySelectorAll.bind(document); }
    """

    /// 执行前把 `$0` 指到最后检查（拾取）的那个元素上。
    private func prepareReplHelpers(in webView: WKWebView) async {
        guard let selector = inspectedElement?.selector, !selector.isEmpty else { return }
        let script = "try { window.$0 = document.querySelector('\(Self.escapeJS(selector))'); } catch (e) {}"
        _ = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    /// 按句柄取一个控制台对象的属性（一层）：值是活对象、留在页面里，
    /// 属性值仍是对象时会给新句柄，面板可以继续展开。
    func loadConsoleRef(_ ref: String, in webView: WKWebView) async -> ConsoleRefNode? {
        let script = """
        if (!window.__desireConsole) return null;
        return window.__desireConsole.describe(ref);
        """
        do {
            let result = try await webView.callAsyncJavaScript(
                script,
                arguments: ["ref": ref],
                in: nil,
                contentWorld: .page
            )
            guard let json = result as? String, let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ConsoleRefNode.self, from: data)
        } catch {
            return nil
        }
    }

    /// `tabID` 是执行这一行的标签页：输入回显与结果都归到它名下，这样
    /// 作用域切到"当前标签页"时 REPL 的输出不会消失。
    func evaluateConsoleInput(_ source: String, in webView: WKWebView, tabID: UUID? = nil) async {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addConsoleMessage(level: .log, message: "› \(trimmed)", tabID: tabID)
        await prepareReplHelpers(in: webView)

        if Self.looksLikeStatement(trimmed) {
            await runStatements(trimmed, in: webView, tabID: tabID)
        } else {
            await runExpression(trimmed, in: webView, tabID: tabID)
        }
    }

    private static func looksLikeStatement(_ source: String) -> Bool {
        if source.contains(";") || source.contains("\n") { return true }
        // 只认"语句关键字开头"，别把 document./window. 也算进来——它们是
        // 最常敲的表达式（`document.body`、`document.querySelectorAll(…).length`）。
        for prefix in ["const ", "let ", "var ", "if ", "for ", "while ", "function ", "return ", "throw ", "class ", "await ", "switch ", "try "] {
            if source.hasPrefix(prefix) { return true }
        }
        return false
    }

    // MARK: - Network 动作

    /// 重放一个请求：在页面里用同样的方法/头/体再发一次，结果写进控制台。
    /// 跨域请求可能被 CORS 拦下——那就把错误原样写进日志（这本身就是答案）。
    func replayRequest(_ request: NetworkRequest, in webView: WKWebView) async {
        var headers = request.requestHeaders ?? [:]
        headers.removeValue(forKey: "Cookie")   // Cookie 由浏览器自己带
        // 形参名（= 字典键）不能和脚本里的声明重名（`callAsyncJavaScript` 把
        // 键当包装函数的形参）——见 previewImageDataURL 里的实测说明。
        let script = """
        const init = { method: verb, headers: extra, credentials: 'include' };
        if (payload !== null && verb !== 'GET' && verb !== 'HEAD') init.body = payload;
        const started = performance.now();
        const response = await fetch(target, init);
        const text = await response.text();
        return JSON.stringify({
            status: response.status,
            ms: Math.round(performance.now() - started),
            bytes: text.length,
            head: text.slice(0, 400)
        });
        """
        addConsoleMessage(level: .log, message: "↻ \(request.method) \(request.url)", tabID: request.tabID)
        do {
            let result = try await webView.callAsyncJavaScript(
                script,
                arguments: [
                    "target": request.url,
                    "verb": request.method,
                    "extra": headers,
                    "payload": request.requestBody as Any,
                ],
                in: nil,
                contentWorld: .page
            )
            addConsoleMessage(level: .log, message: Self.describe(result), tabID: request.tabID)
        } catch {
            addConsoleMessage(level: .error, message: Self.exceptionMessage(error) ?? error.localizedDescription, tabID: request.tabID)
        }
    }

    /// Element 页签的 DOM 树：按 nth-child 链取**一层**子节点（懒展开）。
    /// 返回 nil 表示取不到（页面没加载、路径失效、脚本缺失）。
    func loadTreeChildren(path: String, in webView: WKWebView) async -> DOMNode? {
        let script = UserScriptLoader.load("dom-tree")
        guard !script.isEmpty else { return nil }
        do {
            // 形参名必须与字典键一致（AGENTS.md 的 callAsyncJavaScript 约定）。
            let result = try await webView.callAsyncJavaScript(
                script,
                arguments: ["path": path, "maxChildren": 200],
                in: nil,
                contentWorld: .page
            )
            guard let json = result as? String, let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(DOMNode.self, from: data)
        } catch {
            return nil
        }
    }

    /// 在页面里取一张图片并转成 data URL，供 Network 详情内联预览。
    ///
    /// 走**页面自己的 fetch**（带 cookie），所以同源资源一定能取到；跨域图片
    /// 要看对方的 CORS 头——取不到就让调用方显示"加载不了"。超过 `maxBytes`
    /// 直接放弃（面板里预览大图没有意义）。
    func previewImageDataURL(for request: NetworkRequest, in webView: WKWebView, maxBytes: Int = 512 * 1024) async throws -> String? {
        // 形参名（= 字典键）**不能**和脚本里的声明重名：`callAsyncJavaScript`
        // 把字典的键当作包装函数的形参，脚本里再 `const url = …` 就是
        // "Cannot declare a const variable twice: 'url'"（实测）。
        let script = """
        const response = await fetch(src, { credentials: 'include' });
        if (!response.ok) return null;
        const buffer = await response.arrayBuffer();
        if (buffer.byteLength > cap) return null;
        const bytes = new Uint8Array(buffer);
        let binary = '';
        for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
        const type = response.headers.get('content-type') || 'image/png';
        return 'data:' + type + ';base64,' + btoa(binary);
        """
        // 异常要抛出去（而不是吞成 nil）：面板要能说清"为什么没预览成"，
        // 桥也要能把真实异常文本回给调用方。
        let result = try await webView.callAsyncJavaScript(
            script,
            arguments: ["src": request.url, "cap": maxBytes],
            in: nil,
            contentWorld: .page
        )
        return result as? String
    }

    /// 表达式路径：① 直接求值（结果可 JSON 化）；② 字符串化（DOM 节点给
    /// outerHTML）；③ 都不行时退回语句路径。
    private func runExpression(_ source: String, in webView: WKWebView, tabID: UUID?) async {
        let exprBody = """
        \(Self.replPreamble)
        window.$_ = (
        \(source)
        );
        return window.$_;
        """
        do {
            let value = try await webView.callAsyncJavaScript(exprBody, arguments: [:], in: nil, contentWorld: .page)
            addConsoleMessage(level: .log, message: Self.describe(value), tabID: tabID)
            return
        } catch {
            if let message = Self.exceptionMessage(error), !message.hasPrefix("SyntaxError") {
                addConsoleMessage(level: .error, message: message, tabID: tabID)
                return
            }
        }

        let stringifyBody = """
        \(Self.replPreamble)
        const __v = (\(source));
        window.$_ = __v;
        if (__v === undefined) return 'undefined';
        if (__v === null) return 'null';
        // DOM 节点先给标记（JSON.stringify 一个元素只会吐它的可枚举属性，没用）。
        if (__v && __v.nodeType) return String(__v.outerHTML || __v.nodeValue || __v).slice(0, 4000);
        if (typeof __v === 'object') {
            try { const s = JSON.stringify(__v); if (s !== undefined && s !== null) return s; } catch (e) {}
            if (__v.outerHTML) return String(__v.outerHTML).slice(0, 4000);
            if (typeof __v.length === 'number') return '[' + __v.length + ' items]';
        }
        return String(__v);
        """
        if let text = try? await webView.callAsyncJavaScript(stringifyBody, arguments: [:], in: nil, contentWorld: .page) as? String {
            addConsoleMessage(level: .log, message: text, tabID: tabID)
            return
        }
        await runStatements(source, in: webView, tabID: tabID)
    }

    /// 语句路径：整体当函数体跑；有返回值就显示，没有就报 undefined。
    private func runStatements(_ source: String, in webView: WKWebView, tabID: UUID?) async {
        // 包一层 async IIFE 才能拿到完成值并记进 `$_`（`return` 语义不变）。
        let body = """
        \(Self.replPreamble)
        const __result = await (async () => {
        \(source)
        })();
        if (__result !== undefined) window.$_ = __result;
        return __result;
        """
        do {
            let value = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
            addConsoleMessage(level: .log, message: value == nil ? "undefined" : Self.describe(value), tabID: tabID)
        } catch {
            addConsoleMessage(level: .error, message: Self.exceptionMessage(error) ?? error.localizedDescription, tabID: tabID)
        }
    }

    private static func describe(_ value: Any?) -> String {
        switch value {
        case nil: return "undefined"
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        case let array as [Any]: return (try? JSONSerialization.data(withJSONObject: array, options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) } ?? "\(array)"
        case let dict as [String: Any]: return (try? JSONSerialization.data(withJSONObject: dict, options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) } ?? "\(dict)"
        default: return "\(value!)"
        }
    }

    private static func exceptionMessage(_ error: Error) -> String? {
        let userInfo = (error as NSError).userInfo
        for key in ["WKJavaScriptExceptionMessage", "NSLocalizedDescriptionKey"] {
            if let message = userInfo[key] as? String, !message.isEmpty { return message }
        }
        return nil
    }

}