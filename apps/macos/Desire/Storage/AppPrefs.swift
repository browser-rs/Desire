import Foundation

/// **系统偏好的唯一入口**（v0.8.26 之后的教训，2026-11-25 落地）。
///
/// 全应用的 `UserDefaults` 读写都从这里走。正常启动它就是 `.standard`，行为与
/// 从前逐字节一致；封闭启动（`--data-dir`）它是一个独立的命名域。
///
/// 为什么需要：`--data-dir` 只重定向文件存储，而偏好按应用标识存放——测试实例
/// 与安装版共用同一份。实测事故：自动化里"激活假档案"把用户的活动模型服务
/// 改掉，用户的安装版随后指向了错误的服务（一晚上发生了三次）。
///
/// 为什么不用 `CFFIXED_USER_HOME`：命令行小程序实验里它看起来有效，但对真实
/// 的应用包无效——应用照常写进了用户的偏好域（2026-11-25 实测，偏好文件
/// 修改时间与值都变了）。依赖系统层面的隐式行为不可靠；这里用进程内显式的
/// 独立域，`HermeticLaunchGuard` 在启动时断言它确实不是 `.standard`。
nonisolated enum AppPrefs {

    /// 封闭模式的独立偏好域（`~/Library/Preferences/<这个名字>.plist`）。
    /// 名字固定：反复启动复用同一份，不在用户的偏好目录里堆积。
    static let automationSuiteName = "me.siwi.Desire.automation"

    /// 封闭启动时创建的独立域；正常启动为 nil。
    private static let isolated: UserDefaults? = {
        guard StorageRoot.isOverridden else { return nil }
        return UserDefaults(suiteName: automationSuiteName)
    }()

    /// 全应用的偏好读写入口。
    static var defaults: UserDefaults {
        guard StorageRoot.isOverridden else { return .standard }
        // 封闭模式下拿不到独立域是致命的：退回 `.standard` 就等于写进用户的
        // 真实设置。宁可在这里停住。
        guard let isolated else {
            fatalError("hermetic launch: could not create the isolated preferences domain '\(automationSuiteName)'")
        }
        return isolated
    }

    /// 当前是否在独立域上（守卫的自检用）。
    static var isIsolated: Bool { StorageRoot.isOverridden && isolated != nil }
}
