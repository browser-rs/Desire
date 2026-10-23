import Foundation

/// 账号健康（v0.8.3，纯逻辑 + 判定）：发布/战役前回答"这个渠道现在能不能发"。
/// 只读检查：登录信号、账号视图或 composer 是否可达；不读 Keychain、不发布。
///
/// Foundation-only 的判定部分进 harness；实际打开页面在 Checker 里。
nonisolated enum PromotionAccountHealth {
    enum State: String, Equatable {
        case ready
        case loginRequired
        case adapterMissing
        case adapterDisabled
        case noSignal
        case unknown

        var label: String {
            switch self {
            case .ready: String(localized: "Ready")
            case .loginRequired: String(localized: "Login required")
            case .adapterMissing: String(localized: "Adapter missing")
            case .adapterDisabled: String(localized: "Adapter disabled")
            case .noSignal: String(localized: "No login signal")
            case .unknown: String(localized: "Unknown")
            }
        }
    }

    struct Assessment: Equatable {
        var state: State
        var detail: String
        var checkedAt: Date?

        init(state: State, detail: String = "", checkedAt: Date? = nil) {
            self.state = state
            self.detail = detail
            self.checkedAt = checkedAt
        }
    }

    /// 打开页面之前能说的结论：没有适配/被禁用/没有可检查的声明。
    /// `.unknown` = 已声明登录信号/账号或 composer 视图，等一次实际检查。
    static func declaredState(adapter: DPPAdapter?, enabled: Bool) -> Assessment {
        guard let adapter else {
            return Assessment(state: .adapterMissing,
                              detail: "No ops adapter for this channel — author one to make readiness deterministic.")
        }
        guard enabled else {
            return Assessment(state: .adapterDisabled,
                              detail: "The ops adapter is installed but disabled.")
        }
        let report = DPPOpsContract.report(for: adapter.protocolBody)
        let hasSignal = adapter.protocolBody.signals["opsLoginRequired"] != nil
        let hasAccount = report.capabilities.contains(.account)
        let hasComposer = report.capabilities.contains(.composer) || report.capabilities.contains(.compose)
        if hasSignal || hasAccount || hasComposer {
            return Assessment(state: .unknown, detail: "Open the site to check the login state.")
        }
        return Assessment(state: .noSignal,
                          detail: "The adapter declares no opsLoginRequired/opsAccount/opsComposer — cannot check readiness.")
    }

    /// 页面检查结果 → 结论。优先登录信号，其次账号视图条目，再次 composer。
    static func evaluate(loginMatched: Bool, accountItems: Int, composerFound: Bool) -> Assessment {
        if loginMatched {
            return Assessment(state: .loginRequired,
                              detail: "A visible login prompt matches the adapter's opsLoginRequired signal.")
        }
        if accountItems > 0 {
            return Assessment(state: .ready,
                              detail: "Account view returned \(accountItems) item(s).")
        }
        if composerFound {
            return Assessment(state: .ready,
                              detail: "Composer is reachable.")
        }
        return Assessment(state: .unknown,
                          detail: "No login prompt or composer found — the page may have changed.")
    }
}
