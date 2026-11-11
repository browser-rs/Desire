import Combine
import Foundation

/// 已关闭窗口的快照（v0.8.52 批 2）：标签集 + frame + 关闭时间。
/// 与"最近关闭标签"并存：这里是**整窗**，恢复 = 开一扇新窗口装载快照。
nonisolated struct ClosedWindow: Codable, Identifiable {
    let id: UUID
    var title: String
    var session: SavedSession
    var frame: WindowFrame?
    var closedAt: Date

    var tabCount: Int { session.tabs.count }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return "\(tabCount) tabs"
    }
}

/// 关闭窗口的持久化账本（DiskStore `closed-windows`，cap 20，新在前）。
/// 只在**用户主动关窗**时记录（App 退出流程与 Agent 窗口不记）。
@MainActor
final class ClosedWindowStore: ObservableObject {
    static let shared = ClosedWindowStore()

    @Published private(set) var windows: [ClosedWindow] = []

    private static let key = "closed-windows"
    private static let cap = 20

    private init() {
        windows = (DiskStore.load([ClosedWindow].self, key: Self.key) ?? [])
            .sorted { $0.closedAt > $1.closedAt }
        if windows.count > Self.cap { windows.removeLast(windows.count - Self.cap) }
    }

    func record(session: SavedSession, frame: WindowFrame?, title: String) {
        guard !session.tabs.isEmpty else { return }
        windows.insert(ClosedWindow(id: UUID(),
                                    title: title,
                                    session: session,
                                    frame: frame,
                                    closedAt: Date()), at: 0)
        if windows.count > Self.cap { windows.removeLast(windows.count - Self.cap) }
        persist()
    }

    func mostRecent() -> ClosedWindow? { windows.first }

    func remove(_ id: UUID) {
        windows.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        windows.removeAll()
        persist()
    }

    private func persist() {
        DiskStore.save(windows, key: Self.key)
    }
}
