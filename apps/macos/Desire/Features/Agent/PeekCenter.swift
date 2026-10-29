import Combine
import Foundation
import WebKit

/// 一次"需要用户看一眼/动一下"的请求（v0.8.23）。
nonisolated struct PeekRequest: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable {
        case pending, visible, resolved, dismissed
    }

    var id: UUID
    var reason: String
    var needsPage: Bool
    var createdAt: Date
    var status: Status
}

/// 接管锁（v0.8.23）：用户在用某个浏览面（专注模式的面板）时，Agent 的
/// 工具必须让路——目标解析命中锁就返回明确的 `Error:`，不静默失败。
@MainActor
final class SurfaceLock: ObservableObject {
    static let shared = SurfaceLock()

    @Published private(set) var locked: Set<ObjectIdentifier> = []
    private var reasons: [ObjectIdentifier: String] = [:]

    private init() {}

    func lock(_ manager: TabManager, reason: String) {
        locked.insert(ObjectIdentifier(manager))
        reasons[ObjectIdentifier(manager)] = reason
    }

    func unlock(_ manager: TabManager) {
        locked.remove(ObjectIdentifier(manager))
        reasons[ObjectIdentifier(manager)] = nil
    }

    func reason(for manager: TabManager) -> String? {
        reasons[ObjectIdentifier(manager)]
    }

    func isLocked(_ manager: TabManager) -> Bool {
        locked.contains(ObjectIdentifier(manager))
    }
}

/// Peek 协议（v0.8.23）：Agent 请求用户处理（登录/验证码/看一眼），
/// 用户完成后把"页面是否变化"写成系统备注交还给 Agent。
///
/// 呈现按模式分：专注模式 = 工作台面板就地展开（并加接管锁）；
/// 混合/浏览器模式 = 系统通知 + 面板徽标，点开才展开。
@MainActor
final class PeekCenter: ObservableObject {
    static let shared = PeekCenter()

    @Published private(set) var active: PeekRequest?
    @Published private(set) var lastResolution: String?

    private init() {}

    @discardableResult
    func request(reason: String, needsPage: Bool = true) -> PeekRequest {
        let request = PeekRequest(id: UUID(), reason: reason, needsPage: needsPage,
                                  createdAt: Date(), status: .pending)
        active = request
        ProactiveNotificationStore.shared.deliver(
            title: String(localized: "Agent needs you"),
            body: reason,
            tier: .urgent)
        return request
    }

    /// 展开：专注模式锁住面板（用户接管期间 Agent 工具让路）。
    func present() {
        guard var request = active else { return }
        request.status = .visible
        active = request
        if AppModeStore.shared.mode == .agentFocus {
            SurfaceLock.shared.lock(AgentPaneManager.shared.ensure(), reason: request.reason)
        }
    }

    /// 完成/关闭：解锁、对比页面前后状态、写系统备注告知模型。
    func resolve(completed: Bool) {
        guard let request = active else { return }
        let manager = AgentPaneManager.shared.manager
        let before = manager.map { Self.snapshot($0) }
        if let manager { SurfaceLock.shared.unlock(manager) }
        let after = manager.map { Self.snapshot($0) }
        active = nil

        let note: String
        if let before, let after {
            let page = before == after ? "page unchanged" : "page changed"
            note = "Peek \(completed ? "completed" : "dismissed") — \(page) (\(before.isEmpty ? "no page" : before) → \(after.isEmpty ? "no page" : after)). Reason: \(request.reason)"
        } else {
            note = "Peek \(completed ? "completed" : "dismissed"). Reason: \(request.reason)"
        }
        lastResolution = note
        AgentScheduler.shared.deliveryTarget?.appendExternalNote(note)
    }

    func payload() -> [String: Any] {
        var result: [String: Any] = ["locked": SurfaceLock.shared.locked.count]
        if let active {
            result["active"] = [
                "id": active.id.uuidString,
                "reason": active.reason,
                "needsPage": active.needsPage,
                "status": active.status.rawValue,
            ]
        }
        if let lastResolution { result["lastResolution"] = lastResolution }
        return result
    }

    private static func snapshot(_ manager: TabManager) -> String {
        let tab = manager.selectedTab
        return tab?.browser.webView.url?.absoluteString ?? tab?.urlString ?? ""
    }
}
