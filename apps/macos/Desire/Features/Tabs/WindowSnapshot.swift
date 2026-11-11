import Foundation

/// 窗口几何（屏幕坐标，原点左下、y 向上——与 NSWindow.frame 一致）。
/// Foundation-only：恢复计划与 harness 共用，不 import AppKit。
nonisolated struct WindowFrame: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// 窗口恢复策略（设置页三档；v0.8.52）。
nonisolated enum WindowRestoreMode: String, Codable, CaseIterable, Sendable {
    /// 全部窗口（默认）。
    case all
    /// 只恢复上次活跃的那扇（= 首窗），不补开其他窗口。
    case activeOnly
    /// 不恢复窗口（按启动设置开新页）。
    case off
}

/// 一扇窗口的持久化快照（`window-index-v2` 的元素）。
/// 解码对缺键宽容：未来加字段/旧文件缺字段都不至于整份索引失效。
nonisolated struct WindowSnapshot: Codable, Equatable, Sendable, Identifiable {
    let sessionKey: String
    var frame: WindowFrame?
    /// "user" / "agent"（存 rawValue；不依赖 WindowRole 类型，保持 Foundation-only）。
    var role: String
    var isActive: Bool
    var lastActiveAt: Date
    var tabCount: Int
    var isMinimized: Bool

    var id: String { sessionKey }

    init(sessionKey: String, frame: WindowFrame? = nil, role: String = "user",
         isActive: Bool = false, lastActiveAt: Date = Date(), tabCount: Int = 0,
         isMinimized: Bool = false) {
        self.sessionKey = sessionKey
        self.frame = frame
        self.role = role
        self.isActive = isActive
        self.lastActiveAt = lastActiveAt
        self.tabCount = tabCount
        self.isMinimized = isMinimized
    }

    private enum CodingKeys: String, CodingKey {
        case sessionKey, frame, role, isActive, lastActiveAt, tabCount, isMinimized
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionKey = try container.decode(String.self, forKey: .sessionKey)
        frame = try container.decodeIfPresent(WindowFrame.self, forKey: .frame)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "user"
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt) ?? .distantPast
        tabCount = try container.decodeIfPresent(Int.self, forKey: .tabCount) ?? 0
        isMinimized = try container.decodeIfPresent(Bool.self, forKey: .isMinimized) ?? false
    }
}
