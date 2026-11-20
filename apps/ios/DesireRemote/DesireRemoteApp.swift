import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 切后台/切任务的系统快照以窗口底色兜底——默认黑，改为系统背景色
        UIWindow.appearance().backgroundColor = UIColor.systemBackground
        return true
    }
}

@main
struct DesireRemoteApp: App {
    @StateObject private var client = RemoteClient()
    @StateObject private var appLock = AppLock.shared
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environmentObject(client)
                // App 锁覆盖层（v0.8.69）：开着且未解锁时全屏盖住——下方
                // 消息/产物不可见。unlock 在覆盖层按钮上。
                if appLock.isLocked {
                    AppLockOverlay(lock: appLock)
                        .environmentObject(client)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    client.appForegrounded()
                    // 回前台：锁定态不自动弹认证（覆盖层按钮触发——避免
                    // 系统弹窗与画面切换抢焦点）。
                case .background: 
                    client.appWentBackground()
                    appLock.lockIfEnabled()
                default: break
                }
            }
        }
    }
}
