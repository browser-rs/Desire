import Foundation
@preconcurrency import UserNotifications

extension Notification.Name {
    /// 点通知/通知动作后的深链：object 为会话 id（nil = 回到 Agent 首页）。
    static let remoteOpenSession = Notification.Name("remoteOpenSession")
}

/// Remote 通知（0.6.8 起；v0.8.38 批三升级为带动作的类别）：
/// Mac 推 `turnDone` / `notify` 帧 → 这里落成**本地**通知。
/// iOS 对前台 app 默认不展示本地通知；本版由 delegate 显式选择展示 banner，
/// 同一审批/提问用固定 identifier 覆盖，不会因重复帧堆成一串。
/// app 被杀后收不到是平台事实（本地通知只活在进程里；不承诺推送）。
@MainActor
enum RemoteNotifications {
    private static var permissionRequested = false

    static let approvalCategory = "REMOTE_APPROVAL"
    static let openCategory = "REMOTE_OPEN"
    static let allowAction = "REMOTE_ALLOW"
    static let denyAction = "REMOTE_DENY"

    /// 懒请求（TCC 纪律：只在配对成功这个用户动作之后发起，不在 app 启动路径）。
    static func requestPermissionIfNeeded() {
        guard !permissionRequested else { return }
        permissionRequested = true
        let center = UNUserNotificationCenter.current()
        center.delegate = RemoteNotificationDelegate.shared
        let approval = UNNotificationCategory(
            identifier: approvalCategory,
            actions: [
                UNNotificationAction(identifier: allowAction, title: "允许一次",
                                     options: []),
                UNNotificationAction(identifier: denyAction, title: "拒绝",
                                     options: [.destructive]),
            ],
            intentIdentifiers: [],
            options: [])
        let open = UNNotificationCategory(
            identifier: openCategory,
            actions: [
                UNNotificationAction(identifier: UNNotificationDefaultActionIdentifier,
                                     title: "打开", options: [.foreground]),
            ],
            intentIdentifiers: [],
            options: [])
        center.setNotificationCategories([approval, open])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func postInbox(title: String, body: String) {
        requestPermissionIfNeeded()
        post(title: title, body: body, category: openCategory,
             identifier: "inbox-\(UUID().uuidString)", userInfo: [:])
    }

    static func postTurnDone(title: String, body: String, session: String?) {
        permissionRequested = true   // 收到过帧说明链路活着；未授权时 add 静默失败
        var info: [String: Any] = [:]
        if let session { info["session"] = session }
        post(title: "回合完成 · \(title)", body: body, category: openCategory,
             identifier: "turnDone-\(UUID().uuidString)", userInfo: info)
    }

    static func postApproval(id: String, title: String, body: String, session: String?) {
        permissionRequested = true
        var info: [String: Any] = ["id": id]
        if let session { info["session"] = session }
        post(title: title.isEmpty ? "Agent 需要审批" : title,
             body: body, category: approvalCategory,
             identifier: "approval-\(id)", userInfo: info)
    }

    static func postQuestion(id: String, title: String, body: String, session: String?) {
        permissionRequested = true
        var info: [String: Any] = ["id": id]
        if let session { info["session"] = session }
        post(title: title.isEmpty ? "Agent 有问题要问你" : title,
             body: body, category: openCategory,
             identifier: "question-\(id)", userInfo: info)
    }

    private static func post(title: String, body: String, category: String,
                             identifier: String, userInfo: [String: Any]) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = userInfo
        // 同一审批/提问的重复通知合并成一条
        content.threadIdentifier = identifier.split(separator: "-").first.map(String.init) ?? category
        let request = UNNotificationRequest(identifier: identifier,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// 通知动作：Allow/Deny 直接审批；其余点击回到对应会话。
final class RemoteNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RemoteNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let id = info["id"] as? String
        let session = info["session"] as? String
        Task { @MainActor in
            switch action {
            case RemoteNotifications.allowAction:
                if let id { RemoteClient.active?.approve(id: id, decision: .allowOnce) }
            case RemoteNotifications.denyAction:
                if let id { RemoteClient.active?.approve(id: id, decision: .deny) }
            default:
                NotificationCenter.default.post(
                    name: .remoteOpenSession, object: session)
            }
        }
        completionHandler()
    }
}
