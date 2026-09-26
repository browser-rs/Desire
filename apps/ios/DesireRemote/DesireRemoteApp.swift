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
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: client.appForegrounded()
                    case .background: client.appWentBackground()
                    default: break
                    }
                }
        }
    }
}
