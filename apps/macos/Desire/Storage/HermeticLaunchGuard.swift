import Foundation
import os

/// **封闭启动守卫**（v0.8.76，Foundation-only 进 tests/run.sh）。
///
/// `--data-dir` 只重定向文件存储；系统偏好由 `AppPrefs` 另行隔离到一个独立的
/// 命名域。本守卫在启动最早期断言"封闭模式下偏好入口确实不是 `.standard`"，
/// 不成立就拒绝启动——宁可让自动化连不上桥，也不再有一次写进用户偏好的机会。
///
/// 实测事故（2026-11-25，同一晚三次）：自动化里"激活假档案"把用户的活动
/// 模型服务改掉，用户的安装版随后指向了错误的服务。第一版守卫依赖
/// `CFFIXED_USER_HOME`——命令行小程序实验里看似有效，对真实应用包却无效，
/// 守卫日志写着"已隔离"而偏好照样被写。现在只认进程内显式的独立域。
nonisolated enum HermeticLaunchGuard {

    enum Verdict: Equatable, Sendable {
        /// 没带 `--data-dir`：正常启动，偏好入口就是 `.standard`。
        case normalLaunch
        /// 封闭启动，且偏好入口是独立域。
        case hermeticIsolated(suite: String)
        /// 封闭启动，但偏好入口仍是用户的那一份——必须拒绝。
        case hermeticNotIsolated
    }

    static func verdict(isOverridden: Bool = StorageRoot.isOverridden,
                        isolated: Bool = AppPrefs.isIsolated) -> Verdict {
        guard isOverridden else { return .normalLaunch }
        return isolated ? .hermeticIsolated(suite: AppPrefs.automationSuiteName) : .hermeticNotIsolated
    }

    /// 启动最早期调用——**`DesireApp.init()` 的第一行**。必须在那里：SwiftUI 在
    /// App 的 init 之后才构造 `@StateObject` 的 AppState（模型档案的装配与迁移），
    /// 而委托回调 `applicationWillFinishLaunching` 要再晚两百多毫秒——守卫放在
    /// 委托回调里时偏好已经被写过一次。
    static func enforce() {
        switch verdict() {
        case .normalLaunch:
            break
        case .hermeticIsolated(let suite):
            Logger(subsystem: "me.siwi.Desire", category: "app").info(
                "hermetic launch: preferences isolated in domain '\(suite, privacy: .public)'")
        case .hermeticNotIsolated:
            Logger(subsystem: "me.siwi.Desire", category: "app").fault(
                "hermetic launch REFUSED: --data-dir is set but the preferences entry point is still the user's standard domain. Launch with tools/launch-hermetic.sh.")
            exit(70)
        }
    }
}
