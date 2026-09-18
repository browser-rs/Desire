import Foundation

/// 拖出暂存区：标签被拖出成新窗口时，Tab 实例（连同其 webview 状态）先
/// 暂存到目标窗口会话 UUID 下；新窗口 onAppear 时取走并 absorb。
/// 仅主线程访问。
@MainActor
enum TabTransfer {
    private static var pending: [UUID: Tab] = [:]

    static func stage(_ tab: Tab, for sessionID: UUID) {
        pending[sessionID] = tab
    }

    static func take(for sessionID: UUID) -> Tab? {
        pending.removeValue(forKey: sessionID)
    }
}
