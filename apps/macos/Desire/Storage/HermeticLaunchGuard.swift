import Foundation
import os

/// **封闭启动守卫**（v0.8.76，Foundation-only 进 tests/run.sh）。
///
/// `--data-dir` 只重定向文件存储。系统偏好（UserDefaults）按 bundle id 存，
/// 不随 dataDir 走——带 `--data-dir` 的测试实例与安装版共用同一份偏好。
/// 实测事故：测试里"激活假档案"把活动档案写成了一个随后被删除的假档案，
/// 用户下次启动安装版读不到它，回落到列表第一个服务——用户的智能体整整
/// 两个小时指向了错误的模型服务。
///
/// `CFFIXED_USER_HOME` 让偏好写入既不进真实域也不落盘（只在该进程内有效，
/// 实测于 macOS 27）。所以封闭启动**必须**同时带它；没带就拒绝启动——
/// 宁可让自动化连不上桥，也不再有一次写进用户偏好的机会。
nonisolated enum HermeticLaunchGuard {

    static let homeEnvironmentKey = "CFFIXED_USER_HOME"

    enum Verdict: Equatable, Sendable {
        /// 没带 `--data-dir`：正常启动，与安装版行为完全一致。
        case normalLaunch
        /// 封闭启动，且偏好已隔离。
        case hermeticIsolated(fixedHome: String)
        /// 封闭启动，但偏好没有隔离——必须拒绝。
        case hermeticNotIsolated
    }

    static func verdict(arguments: [String] = CommandLine.arguments,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> Verdict {
        guard arguments.contains(where: { $0.hasPrefix("--data-dir=") }) else {
            return .normalLaunch
        }
        guard let home = environment[homeEnvironmentKey],
              !home.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .hermeticNotIsolated
        }
        return .hermeticIsolated(fixedHome: home)
    }

    /// 启动最早期调用——**`DesireApp.init()` 的第一行**。必须在那里：SwiftUI 在
    /// App 的 init 之后才构造 `@StateObject` 的 AppState（模型档案的装配与迁移），
    /// 而委托回调 `applicationWillFinishLaunching` 要再晚两百多毫秒——守卫放在
    /// 委托回调里时偏好已经被写过一次。封闭启动但偏好未隔离 → 记日志并退出。
    static func enforce() {
        switch verdict() {
        case .normalLaunch:
            break
        case .hermeticIsolated(let fixedHome):
            Logger(subsystem: "me.siwi.Desire", category: "app").info(
                "hermetic launch: preferences isolated (CFFIXED_USER_HOME=\(fixedHome, privacy: .public))")
        case .hermeticNotIsolated:
            Logger(subsystem: "me.siwi.Desire", category: "app").fault(
                "hermetic launch REFUSED: --data-dir is set but CFFIXED_USER_HOME is not — system preferences would be written into the user's real domain. Launch with tools/launch-hermetic.sh (it sets both).")
            exit(70)
        }
    }
}
