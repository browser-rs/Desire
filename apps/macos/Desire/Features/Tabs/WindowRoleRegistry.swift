import Combine
import Foundation

/// 窗口角色（v0.8.23）：user（用户的浏览窗口）/ agent（Agent 自己的窗口）。
nonisolated enum WindowRole: String, Codable, Sendable {
    case user
    case agent
    /// 专注模式的内嵌浏览面板（不是窗口；同样不得被用户窗口收养/归档）。
    case agentPane
}

nonisolated struct WindowRoleRecord: Codable, Equatable, Sendable {
    var sessionKey: String
    var role: WindowRole
    /// Agent 窗口默认落在哪个容器（cookie 隔离）。
    var containerID: UUID?
    var createdAt: Date
}

/// 窗口角色注册表（DiskStore `window-roles`，sessionKey → 角色）。
///
/// 为什么不塞进 session-index：那里是 `[String]` 的键清单，改结构会破坏旧盘。
/// 角色必须落盘——否则重启/崩溃后 Agent 窗口会被恢复成用户窗口，或者 Agent
/// 会话被首窗收养。
@MainActor
final class WindowRoleRegistry: ObservableObject {
    static let shared = WindowRoleRegistry()

    @Published private(set) var roles: [String: WindowRoleRecord] = [:]

    private static let storeKey = "window-roles"
    private static let containerKey = "agent.containerID"

    /// 建窗时临时携带的角色（由 `openWindow` 前的调用方设置，SessionRestore 消费）。
    var pendingRole: WindowRole?

    private init() {
        if let loaded = DiskStore.load([WindowRoleRecord].self, key: Self.storeKey) {
            roles = Dictionary(uniqueKeysWithValues: loaded.map { ($0.sessionKey, $0) })
        }
    }

    func role(for sessionKey: String?) -> WindowRole {
        guard let sessionKey, let record = roles[sessionKey] else { return .user }
        return record.role
    }

    func register(sessionKey: String, role: WindowRole, containerID: UUID? = nil) {
        roles[sessionKey] = WindowRoleRecord(sessionKey: sessionKey,
                                             role: role,
                                             containerID: containerID,
                                             createdAt: roles[sessionKey]?.createdAt ?? Date())
        persist()
    }

    func remove(sessionKey: String) {
        guard roles.removeValue(forKey: sessionKey) != nil else { return }
        persist()
    }

    func agentSessionKeys() -> Set<String> {
        Set(roles.values.filter { $0.role != .user }.map(\.sessionKey))
    }

    func agentSessionKey() -> String? {
        roles.values
            .filter { $0.role == .agent }
            .sorted { $0.createdAt > $1.createdAt }
            .first?
            .sessionKey
    }

    /// 收养过滤：用户窗口不得把 Agent 会话当成"上次的浏览会话"。
    /// 非用户会话（Agent 窗口 / Agent 面板）：用户窗口不得收养，孤儿清理不得归档。
    func isAgentSession(_ sessionKey: String) -> Bool {
        guard let role = roles[sessionKey]?.role else { return false }
        return role != .user
    }

    func agentContainerID() -> UUID {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.containerKey),
           let id = UUID(uuidString: raw),
           ContainerStore.shared.containers.contains(where: { $0.id == id }) {
            return id
        }
        if let existing = ContainerStore.shared.containers.first(where: { $0.name == "Agent" }) {
            defaults.set(existing.id.uuidString, forKey: Self.containerKey)
            return existing.id
        }
        let created = ContainerStore.shared.addContainer(name: "Agent")
        defaults.set(created.id.uuidString, forKey: Self.containerKey)
        return created.id
    }

    private func persist() {
        DiskStore.save(Array(roles.values), key: Self.storeKey)
    }
}
