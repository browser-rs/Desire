import CoreGraphics
import Foundation

/// 自动草稿（迭代 15b）：编辑过程中把合成图写进草稿目录，崩溃/强杀后可恢复。
/// 草稿只保存像素（图层结构不入草稿）；成功保存正式文件后清除。
nonisolated enum ImageEditorDraft {

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Desire/ImageEditorDrafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 以源文件路径（或"untitled"）为键的草稿文件。
    static func url(for sourcePath: String) -> URL {
        var hash: UInt64 = 1469598103934665603
        for byte in sourcePath.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return directory.appendingPathComponent(String(format: "%016llx.png", hash))
    }

    static func save(_ image: CGImage, for sourcePath: String) -> Bool {
        do {
            try ImageTransforms.save(image, to: url(for: sourcePath))
            return true
        } catch {
            return false
        }
    }

    static func load(for sourcePath: String) -> CGImage? {
        let path = url(for: sourcePath)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return ImageTransforms.load(from: path)
    }

    static func remove(for sourcePath: String) {
        try? FileManager.default.removeItem(at: url(for: sourcePath))
    }

    static func exists(for sourcePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: sourcePath).path)
    }

    static func modified(for sourcePath: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url(for: sourcePath).path))?[.modificationDate] as? Date
    }
}
