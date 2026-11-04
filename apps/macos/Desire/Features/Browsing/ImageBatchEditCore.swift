import Foundation

/// 图片批量编辑流水线（迭代 3 · v0.8.43）：对文件夹应用统一管线
/// （预设 + 缩放 + 格式），复用 Job 队列的取消/进度/通知语义。
nonisolated struct ImageBatchEditJob: Codable, Identifiable, Equatable {
    var id: UUID
    var folder: String
    var presetName: String?
    var format: String
    var quality: Double
    var longEdge: Int?
    var recursive: Bool
    var conversationID: UUID?
    var createdAt: Date
}

/// 管线核心：纯数据校验（Foundation-only）。
nonisolated enum ImageBatchEditCore {
    static let supportedInputExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "tiff", "tif", "webp", "gif",
    ]
    static let supportedFormats: Set<String> = ["jpeg", "png", "heic"]

    static func validationError(folder: URL, format: String) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir),
              isDir.boolValue else {
            return String(localized: "Folder does not exist") + ": " + folder.path
        }
        guard supportedFormats.contains(format.lowercased()) else {
            return String(localized: "Format must be jpeg, png or heic")
        }
        return nil
    }

    static func inputFiles(in folder: URL, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        let urls = (try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: options)) ?? []
        for url in urls {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile ?? false
            guard isRegular,
                  supportedInputExtensions.contains(
                      url.pathExtension.lowercased())
            else { continue }
            result.append(url)
        }
        if recursive {
            guard let enumerator = fm.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: options.union([.skipsSubdirectoryDescendants])) else {
                return result
            }
            for case let dirURL as URL in enumerator
            where dirURL.hasDirectoryPath {
                for url in inputFiles(in: dirURL, recursive: false) {
                    result.append(url)
                }
            }
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 输出文件唯一命名。
    static func outputURL(for source: URL, in outputDir: URL,
                          format: String) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        var candidate = outputDir.appendingPathComponent("\(stem).\(format)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = outputDir.appendingPathComponent("\(stem)-\(n).\(format)")
            n += 1
        }
        return candidate
    }
}
