import Combine
import Foundation

@MainActor
class DevToolsStore: ObservableObject {
    @Published var consoleMessages: [ConsoleMessage] = []
    @Published var networkRequests: [NetworkRequest] = []
    @Published var inspectedElement: InspectedElement?
    @Published var isInspectingElement = false
    @Published var isDevModeEnabled = false
    @Published var activePanel: DevPanel = .console
    @Published var pendingRequests: [UUID: NetworkRequest] = [:]

    /// Incrementally maintained so the panel header badges don't re-scan the
    /// whole (up to 1000-entry) console array on every publish.
    @Published private(set) var consoleErrorCount = 0
    @Published private(set) var consoleWarningCount = 0
    @Published private(set) var networkFailedCount = 0

    /// Max retained console entries.
    private let consoleCap = 1000

    enum DevPanel: String, CaseIterable {
        case console = "Console"
        case network = "Network"
        case element = "Element"
    }

    init() {}

    func addConsoleMessage(level: ConsoleMessage.Level, message: String, url: String? = nil, line: Int? = nil, column: Int? = nil) {
        let msg = ConsoleMessage(level: level, message: message, url: url, line: line, column: column)
        // Mutate the backing array once (append + optional trim), then publish
        // a single time. The previous append-then-trim sequence published twice.
        var newMessages = consoleMessages
        newMessages.append(msg)
        if newMessages.count > consoleCap {
            let dropped = newMessages.prefix(newMessages.count - consoleCap)
            newMessages.removeFirst(newMessages.count - consoleCap)
            for dropped in dropped {
                applyCount(dropped.level, delta: -1)
            }
        }
        consoleMessages = newMessages
        applyCount(msg.level, delta: 1)
    }

    func clearConsole() {
        consoleMessages.removeAll()
        consoleErrorCount = 0
        consoleWarningCount = 0
    }

    func startNetworkRequest(url: String, method: String, resourceType: NetworkRequest.ResourceType, requestHeaders: [String: String]? = nil, requestBody: String? = nil) -> UUID {
        let request = NetworkRequest(url: url, method: method, resourceType: resourceType, requestHeaders: requestHeaders, requestBody: requestBody)
        pendingRequests[request.id] = request
        networkRequests.append(request)
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
            networkFailedCount += 1
        }
    }

    func clearNetworkRequests() {
        networkRequests.removeAll()
        pendingRequests.removeAll()
        networkFailedCount = 0
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
        pendingRequests.count
    }

    private func applyCount(_ level: ConsoleMessage.Level, delta: Int) {
        switch level {
        case .error: consoleErrorCount = max(0, consoleErrorCount + delta)
        case .warn: consoleWarningCount = max(0, consoleWarningCount + delta)
        default: break
        }
    }
}