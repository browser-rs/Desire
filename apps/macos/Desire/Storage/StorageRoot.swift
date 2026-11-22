import Foundation

/// **存储根**（v0.8.75 批 3）：全局唯一真相——所有 "Desire/<子目录>" 路径都
/// 从这里出发，禁止各文件自行解析 applicationSupportDirectory（23 处散写是
/// 封闭测试做不了的根因）。
///
/// 启动参数 `--data-dir=/path` 重定向整个主目录：自动化/E2E 实例从此与用户
/// 存储零接触——套件不再恢复用户浏览会话、不碰用户记忆/档案/技能，闸门在
/// 任何环境下都封闭可跑。默认启动（无参数）的路径**逐字节不变**。
nonisolated enum StorageRoot {

    /// `--data-dir=/path` 是否生效（封闭模式）。
    static let isOverridden: Bool = CommandLine.arguments.contains { $0.hasPrefix("--data-dir=") }

    /// Desire 主目录。静态 let：首次访问即解析 CommandLine——早于一切 store
    /// 单例的初始化。
    static let directory: URL = {
        for arg in CommandLine.arguments where arg.hasPrefix("--data-dir=") {
            let raw = String(arg.dropFirst("--data-dir=".count)).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath,
                           isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Desire", isDirectory: true)
    }()

    /// 会话目录：历史路径 = AppSupport/me.siwi.Desire/conversations（**默认
    /// 启动保持逐字节不变**——迁移老会话是另一件事）；封闭模式下重定向到
    /// dataDir/conversations。
    static var conversationsDirectory: URL {
        if isOverridden {
            return directory.appendingPathComponent("conversations", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("me.siwi.Desire/conversations", isDirectory: true)
    }
}
