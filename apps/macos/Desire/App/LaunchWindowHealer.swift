import AppKit
import Foundation
import os

/// 启动无窗自愈（v0.8.49 批 1）。
///
/// 症状（2026-10-20 / 2026-11-05 / 2026-11-10 多次实测）：强杀或崩溃后
/// 首次启动偶发"进程活着、桥可连、但没有任何主窗"（`/state` tabs=0、
/// `activeTabManager == nil`）。SwiftUI 的 `.defaultLaunchBehavior(.presented)`
/// 在个别启动路径下没有把主窗创建出来，而应用自身的会话恢复只在
/// ContentView.onAppear 里跑——没有窗口就永远跑不到。
///
/// 自愈顺序（保守、可观测、不循环）：
/// 1. 启动后 4s / 8s / 12s 三次探针：只要出现用户窗口就收手（并清计数）。
/// 2. 窗口对象在但没有上屏 → `makeKeyAndOrderFront` 一次。
/// 3. 仍无窗口 → 重启自己**一次**（保留原始启动参数），计数写在
///    UserDefaults，成功启动（有窗口）时清零；第二次仍失败只记 fault，
///    不再重启（避免无限循环）。
@MainActor
enum LaunchWindowHealer {
    private static let attemptsKey = "app.launchWindowHealAttempts"
    private static let maxAttempts = 1

    static func start() {
        Task { @MainActor in
            for seconds in [4.0, 8.0, 12.0] {
                try? await Task.sleep(for: .seconds(seconds - (lastCheck ?? 0)))
                lastCheck = seconds
                if hasUserWindow {
                    UserDefaults.standard.removeObject(forKey: attemptsKey)
                    return
                }
                Log.app.fault("launch: no user window after \(Int(seconds), privacy: .public)s")
            }
            await heal()
        }
    }

    private static var lastCheck: Double?

    private static var hasUserWindow: Bool {
        TabSessionCoordinator.shared.liveManagers().contains { manager in
            guard let key = manager.sessionKey else { return false }
            return !WindowRoleRegistry.shared.isAgentSession(key)
        }
    }

    private static func heal() async {
        // (1) 窗口对象存在但没上屏/没成为 key：先试着拿回来。
        if let hidden = NSApp.windows.first(where: { $0.canBecomeMain }) {
            Log.app.fault("launch heal: ordering an existing window front")
            hidden.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .seconds(2))
            if hasUserWindow {
                Log.app.info("launch heal: recovered by ordering an existing window")
                UserDefaults.standard.removeObject(forKey: attemptsKey)
                return
            }
        }
        // (2) 真的没有窗口：重启一次（保留参数）。
        let attempts = UserDefaults.standard.integer(forKey: attemptsKey)
        guard attempts < maxAttempts else {
            Log.app.fault("launch heal: still no window after relaunch — giving up (diagnose via LaunchAudit)")
            return
        }
        UserDefaults.standard.set(attempts + 1, forKey: attemptsKey)
        relaunch()
    }

    /// 用 `/bin/sh` 起一个延迟 open 再退出当前进程：`open` 在旧进程还活着时
    /// 只会 activate，必须先让本进程退出。
    private static func relaunch() {
        let bundle = Bundle.main.bundleURL.path
        let args = CommandLine.arguments.dropFirst()
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        // `open --args` 后面一个参数都没有时行为不保证——无参数就不带这一段。
        let argsClause = args.isEmpty ? "" : " --args \(args)"
        let command = "sleep 1.5; /usr/bin/open \"\(bundle)\"\(argsClause)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        do {
            try process.run()
        } catch {
            Log.app.fault("launch heal: relaunch spawn failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        Log.app.fault("launch heal: relaunching after a windowless start")
        // 无窗口状态下走 terminate 会经过 AppKit 的窗口收尾（可能卡住，BUG-K），
        // 直接 exit 更干净——此刻也没有可持久化的窗口状态。
        exit(0)
    }
}
