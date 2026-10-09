import AppKit
import Foundation
import UserNotifications

/// 系统通知的统一路由（每个 app 只能有一个 UNUserNotificationCenterDelegate）：
/// - `desire.update.*`：转发 UpdateChecker（点击打开 release 页）。
/// - `desire.agent.*`：点击激活应用并确保 Agent 面板打开（已打开则只激活）。
/// - 前台横幅：所有通知统一 banner + sound。
/// 在应用 init 时 install() 一次；此后任何代码不得再直接设置 center.delegate。
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let userInfo = response.notification.request.content.userInfo
        let isUpdate = identifier.hasPrefix("desire.update.")
        let isAgent = identifier.hasPrefix("desire.agent.")
        let url = userInfo["url"] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if isUpdate {
                UpdateChecker.handleTap(userInfo: ["url": url ?? ""])
            } else if isAgent {
                Self.ensureAgentPanel()
            }
            completionHandler()
        }
    }

    /// 深链动作：Agent 面板未开则补一条打开命令（已开则保持——不能用
    /// toggle，会把已开的面板关掉）。
    static func ensureAgentPanel() {
        let key = TabSessionCoordinator.shared.activeTabManager?.sessionKey
        if !AgentPanelVisibilityStore.shared.isShown(key: key) {
            CommandBus.shared.send(.toggleAgentPanel)
        }
    }
}
