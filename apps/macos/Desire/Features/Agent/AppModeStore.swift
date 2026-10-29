import Combine
import Foundation

/// 使用模式的持久化单例（UserDefaults `app.usageMode`，默认 browser）。
/// 只负责状态与通知；窗口/工作台的编排在 `AppModeCoordinator`。
@MainActor
final class AppModeStore: ObservableObject {
    static let shared = AppModeStore()

    @Published private(set) var mode: AppUsageMode
    /// 登录态策略（v0.8.23）：true = Agent 沿用当前档案（便利优先）；
    /// false（默认）= 独立 Agent 容器（隔离优先）。
    @Published private(set) var agentSharesUserProfile: Bool
    /// 首次切到非浏览器模式时的说明（非 nil = 显示引导 sheet）。
    @Published private(set) var guideMode: AppUsageMode?

    private static let key = "app.usageMode"
    private static let shareKey = "agent.shareUserProfile"
    private static let guideKey = "app.mode.guideShown"

    private init() {
        mode = AppUsageMode(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .browser
        agentSharesUserProfile = UserDefaults.standard.bool(forKey: Self.shareKey)
    }

    func setMode(_ newMode: AppUsageMode) {
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.key)
        let defaults = UserDefaults.standard
        if newMode != .browser, !defaults.bool(forKey: Self.guideKey) {
            defaults.set(true, forKey: Self.guideKey)
            guideMode = newMode
        }
        NotificationCenter.default.post(name: .appUsageModeChanged, object: nil)
    }

    func dismissGuide() {
        guideMode = nil
    }

    func setAgentSharesUserProfile(_ shares: Bool) {
        guard shares != agentSharesUserProfile else { return }
        agentSharesUserProfile = shares
        UserDefaults.standard.set(shares, forKey: Self.shareKey)
        NotificationCenter.default.post(name: .appUsageModeChanged, object: nil)
    }

    /// 桥 `GET /app/mode` 的载荷。
    func payload() -> [String: Any] {
        [
            "mode": mode.rawValue,
            "modes": AppUsageMode.allCases.map { mode -> [String: Any] in
                ["id": mode.rawValue, "title": mode.title]
            },
            "agentWindowSessionKey": WindowRoleRegistry.shared.agentSessionKey() ?? "",
        ]
    }
}
