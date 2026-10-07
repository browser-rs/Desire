import Foundation

/// 跨功能的**防撞文件名**与 ISO8601 文案收口（ARCH-7：此前三份手写
/// uniqueURL 循环、ISO8601DateFormatter 现场 new 十余次）。
nonisolated enum FilePathing {

    /// 落盘文件名消毒（0.7.4 安全轮）：下载的 suggestedFilename 来自
    /// 远端（Content-Disposition / URL 末段）——`../../.zshenv` 这类穿越
    /// 名在 `.replace` 策略下直接 appendingPathComponent，能把文件写出
    /// Downloads。统一：取末段（吃掉所有 `..` 段）、禁隐敓名、空名兜底。
    /// 截图等 app 生成的名字过一遍无副作用。
    static func sanitizeFileName(_ filename: String) -> String {
        var name = (filename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { return "download" }
        if name.hasPrefix(".") { name = "_" + name.dropFirst() }
        return name
    }

    /// 在 `folder` 里为 `filename` 找一个不存在的落点：命中即用，否则追加
    /// " 2"、" 3"……（唯一实现；DownloadStore / 截图落盘共用）。
    static func uniqueURL(in folder: URL, for filename: String) -> URL {
        let safe = sanitizeFileName(filename)
        let base = folder.appendingPathComponent(safe)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let ext = (safe as NSString).pathExtension
        let stem = (safe as NSString).deletingPathExtension
        var i = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
            i += 1
        }
    }
}

/// 统一的 ISO8601 文案（桥端点/日志的时间戳口径）。
nonisolated enum ISO {
    /// ISO8601DateFormatter 输出线程安全（现代 macOS）——共享一个实例，
    /// 免得每个 handler 现场 new。
    private static let formatter = ISO8601DateFormatter()

    static func string(from date: Date) -> String { formatter.string(from: date) }
}
