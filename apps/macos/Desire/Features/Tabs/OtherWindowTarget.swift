import Foundation

/// 标签"移动到其他窗口"的目标（v0.8.52 批 2）：窗口会话 id + 展示标题。
/// 视图层用它渲染子菜单，避免把 TabManager 直接暴露给组件。
nonisolated struct OtherWindowTarget: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
}

/// 其他窗口的标签（v0.8.52 批 2 跨窗搜索）：窗口会话 id + 窗口标题 + 标签。
struct ExternalTabEntry: Identifiable {
    let sessionID: UUID
    let windowTitle: String
    let tab: Tab

    var id: String { "\(sessionID.uuidString)|\(tab.id.uuidString)" }
}
