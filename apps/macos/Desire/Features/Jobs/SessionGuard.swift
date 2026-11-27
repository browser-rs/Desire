import AppKit
import CoreGraphics

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
    /// 诊断/测试用的锁屏覆盖（v0.8.80 批 6：桥可模拟锁屏，免得真锁屏才能测）。
    static var debugLockedOverride: Bool?

    /// **真锁屏检测**：`CGSessionCopyCurrentDictionary()[CGSSessionScreenIsLocked]`
    /// 是系统唯一权威标志（v0.8.80 批 6 替换"frontmostApplication != nil"的代理
    /// ——后者在锁屏时仍可能给出 loginwindow，漏判）。取不到会话字典时回退到
    /// "有没有前台应用"。
    static func isScreenLocked() -> Bool {
        if let debugLockedOverride { return debugLockedOverride }
        if let info = CGSessionCopyCurrentDictionary() as? [String: Any],
           let locked = info["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        return NSWorkspace.shared.frontmostApplication == nil
    }

    /// 是否存在前台应用（false = 锁屏/会话锁定/无 frontmost）。
    static func isFrontmostAvailable() -> Bool {
        !isScreenLocked() && NSWorkspace.shared.frontmostApplication != nil
    }

    /// 前台应用名（诊断/日志用；nil = 无前台应用）。
    static var frontmostName: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }
}
