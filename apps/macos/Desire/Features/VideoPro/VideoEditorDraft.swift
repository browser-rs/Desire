import Foundation

/// VideoPro 工程草稿（`Application Support/Desire/VideoProDrafts`）。
/// 编辑后 3s 防抖落盘（`VideoEditorStore.scheduleDraftSave`），崩溃/强杀后
/// 重开可恢复；显式保存或放弃时清掉。
///
/// 键 = 工程文件路径；未保存工程 = `"untitled"`（对齐 ImagePro 草稿语义）。
nonisolated enum VideoEditorDraft {

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Desire/VideoProDrafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func url(for sourceKey: String) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in sourceKey.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return directory.appendingPathComponent(String(format: "%016llx.dtl", hash))
    }

    @discardableResult
    static func save(_ project: TimelineCore.Project, for sourceKey: String) -> Bool {
        guard let data = try? JSONEncoder().encode(project) else { return false }
        return (try? data.write(to: url(for: sourceKey), options: .atomic)) != nil
    }

    static func load(for sourceKey: String) -> TimelineCore.Project? {
        guard let data = try? Data(contentsOf: url(for: sourceKey)) else { return nil }
        return try? JSONDecoder().decode(TimelineCore.Project.self, from: data)
    }

    static func remove(for sourceKey: String) {
        try? FileManager.default.removeItem(at: url(for: sourceKey))
    }

    static func exists(for sourceKey: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: sourceKey).path)
    }

    static func modified(for sourceKey: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url(for: sourceKey).path))?[.modificationDate] as? Date
    }
}
