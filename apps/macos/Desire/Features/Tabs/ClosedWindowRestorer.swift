import Foundation

/// 整窗恢复（v0.8.52 批 2）：把关闭窗口快照落成一个**新窗口**。
///
/// 做法：给快照写一份新的会话文件（`session-<uuid>.json`），把 frame 排进
/// 待还原表，然后由 ContentView 用 `openWindow(id:"main", value: uuid)` 开窗——
/// 新窗口的 SessionRestore 会按自己的 key 恢复标签，窗口标记按 key 还原 frame。
@MainActor
enum ClosedWindowRestorer {
    /// 准备恢复；返回新窗口应携带的会话 UUID（调用方负责 openWindow）。
    static func stage(_ closed: ClosedWindow) -> UUID? {
        guard !closed.session.tabs.isEmpty else { return nil }
        let uuid = UUID()
        let key = TabSessionCoordinator.shared.sessionKey(for: uuid)
        DiskStore.saveWithBackup(closed.session, key: key)
        // DiskStore 是 500ms 防抖异步写；openWindow 紧接着就会读这个文件——
        // 不 flush 会读到缺失/旧内容，新窗口开成空白页（2026-11-11 实测）。
        DiskStore.flushSync()
        WindowRoleRegistry.shared.register(sessionKey: key, role: .user)
        TabSessionCoordinator.shared.stageFrame(for: key, frame: closed.frame)
        return uuid
    }
}
