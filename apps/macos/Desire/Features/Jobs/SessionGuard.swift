import AppKit

/// **会话前台状态探针**（v0.8.63 批 1）。
///
/// 值守处置（.handle）的浏览器类动作（navigate/click/截图…）在**应用不在
/// 前台**时静默失效——`NSApp.isActive=false` 的后台实例里 WKWebView 页面
/// 不加载（CI 教训的本地同源，0.8.62 批 4 终版定性）。处置回合发起前用本
/// 探针把关：无前台应用（锁屏/会话锁定）→ 挂起等解锁，不白白消耗闸门。
///
/// 探针实现 = `NSWorkspace.frontmostApplication`：**System Events 的
/// frontmost 查询在该场景会误报"无效的索引"（0.8.62 批 4 深挖记录），
/// NSWorkspace 则始终给出真实前台应用——别换成 System Events。**
@MainActor
enum SessionGuard {
    /// 是否存在前台应用（false = 锁屏/会话锁定/无 frontmost）。
    static func isFrontmostAvailable() -> Bool {
        NSWorkspace.shared.frontmostApplication != nil
    }

    /// 前台应用名（诊断/日志用；nil = 无前台应用）。
    static var frontmostName: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }
}
