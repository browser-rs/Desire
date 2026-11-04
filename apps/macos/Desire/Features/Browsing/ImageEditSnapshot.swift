import CoreGraphics
import Foundation

/// 编辑快照持久化（迭代 2 · v0.8.42 批 5）：保存时写 `<file>.editstate.json`
/// 记录管线/undo 栈/选区参数，重开同一文件时恢复（关闭重开还能继续编辑）。
nonisolated struct ImageEditSnapshot: Codable {
    var pipeline: ImageEditPipeline
    /// undo 栈里的历史管线（跳转回放用）
    var undoStack: [ImageEditPipeline]
    /// 选区（rect 模式）
    var selection: ImageSelectionParams?
    /// 保存时间
    var savedAt: Date
}

nonisolated enum ImageEditSnapshotIO {

    static func snapshotURL(for fileURL: URL) -> URL {
        fileURL.deletingPathExtension()
            .appendingPathExtension(fileURL.pathExtension + ".editstate.json")
    }

    /// 写入编辑快照（save 时调用）。
    static func save(_ snapshot: ImageEditSnapshot, for fileURL: URL) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = snapshotURL(for: fileURL)
        try? data.write(to: url, options: .atomic)
    }

    /// 读取编辑快照（重开文件时调用）；不存在返回 nil。
    static func load(for fileURL: URL) -> ImageEditSnapshot? {
        let url = snapshotURL(for: fileURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ImageEditSnapshot.self, from: data)
    }

    /// 删除快照（编辑器 Back / 文档关闭时调用——表示不再继续编辑）。
    static func remove(for fileURL: URL) {
        let url = snapshotURL(for: fileURL)
        try? FileManager.default.removeItem(at: url)
    }
}
