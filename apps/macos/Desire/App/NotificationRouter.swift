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
        // UNNotificationContent.userInfo 是 [AnyHashable: Any]；路由层固定用
        // [String: Any]（桥端也是 JSON 字典），这里收口一次。
        var userInfo: [String: Any] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            if let key = key as? String { userInfo[key] = value }
        }
        let category = response.notification.request.content.categoryIdentifier
        let actionID = response.actionIdentifier
        let notificationUserInfo = userInfo
        Task { @MainActor in
            self.handleAction(category: category, identifier: identifier,
                              userInfo: notificationUserInfo, actionID: actionID)
            completionHandler()
        }
    }

    /// 动作路由的单一实现：系统代理与自动化桥（`POST /notifications/action`）
    /// 走同一条路径——测试不会测到一份"只存在于测试里"的分支。
    @MainActor
    func handleAction(category: String, identifier: String,
                      userInfo: [String: Any], actionID: String) {
        NSApp.activate(ignoringOtherApps: true)
        if identifier.hasPrefix("desire.update.") || category == "UPDATE_AVAILABLE" {
            UpdateChecker.handleTap(userInfo: ["url": (userInfo["url"] as? String) ?? ""])
        } else if identifier.hasPrefix("desire.agent.") || category == "AGENT" {
            Self.ensureAgentPanel()
        } else if identifier.hasPrefix("desire.download.") || category == "DOWNLOAD_COMPLETE" {
            let filePath = userInfo["filePath"] as? String ?? ""
            if actionID == "OPEN_DOWNLOAD", FileManager.default.fileExists(atPath: filePath) {
                NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
            } else if actionID == "SHOW_IN_FINDER", FileManager.default.fileExists(atPath: filePath) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
            }
        } else if identifier.hasPrefix("desire.task.") || category == "SCHEDULED_TASK_FAILED" {
            let taskName = userInfo["taskName"] as? String
            if actionID == "RETRY_TASK", let taskName, !taskName.isEmpty {
                _ = AgentScheduler.shared.fireNow(named: taskName)
            } else {
                Self.ensureAgentPanel()
            }
        } else if identifier.hasPrefix("desire.job.") || category == "JOB_COMPLETE" {
            let artifact = userInfo["artifact"] as? String ?? ""
            if actionID == "OPEN_JOB_RESULT", !artifact.isEmpty {
                if artifact.hasPrefix("http://") || artifact.hasPrefix("https://") {
                    TabSessionCoordinator.shared.activeTabManager?.addTab(url: artifact)
                } else {
                    NSWorkspace.shared.open(URL(fileURLWithPath: artifact))
                }
            } else {
                NotificationCenter.default.post(name: .openJobsPanel, object: nil)
            }
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
