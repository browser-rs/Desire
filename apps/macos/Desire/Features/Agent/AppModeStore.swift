import Combine
import Foundation

/// 使用模式的持久化单例（UserDefaults `app.usageMode`，默认 browser）。
/// 只负责状态与通知；窗口/工作台的编排在 `AppModeCoordinator`。
@MainActor
final class AppModeStore: ObservableObject {
    static let shared = AppModeStore()

    @Published private(set) var mode: AppUsageMode

    private static let key = "app.usageMode"

    private init() {
        mode = AppUsageMode(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .browser
    }

    func setMode(_ newMode: AppUsageMode) {
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.key)
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
