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

    enum DevPanel: String, CaseIterable {
        case console = "Console"
        case network = "Network"
        case element = "Element"
    }

    init() {}

    func addConsoleMessage(level: ConsoleMessage.Level, message: String, url: String? = nil, line: Int? = nil, column: Int? = nil) {
        let msg = ConsoleMessage(level: level, message: message, url: url, line: line, column: column)
        consoleMessages.append(msg)
        if consoleMessages.count > 1000 {
            consoleMessages.removeFirst(consoleMessages.count - 1000)
        }
    }

    func clearConsole() {
        consoleMessages.removeAll()
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
        }
    }

    func clearNetworkRequests() {
        networkRequests.removeAll()
        pendingRequests.removeAll()
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

    var consoleErrorCount: Int {
        consoleMessages.filter { $0.level == .error }.count
    }

    var consoleWarningCount: Int {
        consoleMessages.filter { $0.level == .warn }.count
    }

    var networkFailedCount: Int {
        networkRequests.filter { $0.failed }.count
    }

    var networkPendingCount: Int {
        pendingRequests.count
    }
}