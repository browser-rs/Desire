import Foundation
@preconcurrency import UserNotifications

/// Remote 完成通知（0.6.8）：Mac 回合结束推 `turnDone` 帧 → 这里落成
/// **本地**通知。iOS 对前台 app 默认不展示本地通知——"页面在前台就不打扰"
/// 是系统行为，不用自己判 scenePhase。app 被杀后收不到是平台事实
/// （本地通知只活在进程里；不承诺推送）。
@MainActor
enum RemoteNotifications {
    private static var permissionRequested = false

    /// 懒请求（TCC 纪律：只在配对成功这个用户动作之后发起，不在 app 启动路径）。
    static func requestPermissionIfNeeded() {
        guard !permissionRequested else { return }
        permissionRequested = true
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func postTurnDone(title: String, body: String) {
        permissionRequested = true   // 收到过帧说明链路活着；未授权时 add 静默失败
        let content = UNMutableNotificationContent()
        content.title = "回合完成 · \(title)"
        if !body.isEmpty { content.body = body }
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
