import Foundation

/// 同步健康状态（v0.7.25 可发现性）：从 store 的既有字段派生，纯逻辑进
/// harness。优先级：未登录 > 同步中 > 错误 > 正常（同步中的短暂错误不闪红，
/// 下一轮结束会落定）。
nonisolated enum SyncHealth: String {
    case signedOut
    case syncing
    case error
    case ok

    static func derive(signedIn: Bool, syncing: Bool, hasError: Bool) -> SyncHealth {
        if !signedIn { return .signedOut }
        if syncing { return .syncing }
        if hasError { return .error }
        return .ok
    }

    /// 悬停提示（状态一句话）。
    var title: String {
        switch self {
        case .signedOut: String(localized: "Sync: signed out")
        case .syncing: String(localized: "Sync: syncing…")
        case .error: String(localized: "Sync: needs attention")
        case .ok: String(localized: "Sync: up to date")
        }
    }
}
