import Foundation

/// 批量下载任务日志：**每批一份**、按时间追加的全链路记录。
///
/// 记录点（BatchMediaExportStore 各阶段调用 `append`）：批创建（目录/分卷/
/// 并发/项数）、逐项解析/下载开始与完成（耗时/大小）、失败与原因、跳过与
/// 原因、分卷顺延、合成（remux）开始与结束、暂停/恢复/挂起/取消/完成。
/// 面板批次卡可展开查看；桥 `GET /media/batch/log?id=` 可取。
///
/// 存储：DiskStore 每批一个键（`batch-log-<uuid>`），FIFO 上限 3600 行；
/// 批次从面板移除时一并删除。
struct BatchMediaLog: Codable, Identifiable, Equatable {
    var id = UUID()
    var at: Date
    var line: String
}

enum BatchMediaLogStore {
    private static let cap = 3600
    private static func key(_ batchID: UUID) -> String { "batch-log-\(batchID.uuidString)" }

    // 进程内缓存：append 是"读-改-写"，DiskStore 防抖 500ms 内连续多个事件
    //（如多项接连完成）各自 load 到**盘上旧值**、互相覆盖丢行（实测 [03] 的
    // 开始/完成两行丢失）。缓存后读改写全在内存，防抖只负责落盘。
    private nonisolated(unsafe) static var cache: [String: [BatchMediaLog]] = [:]

    static func append(_ batchID: UUID, _ line: String) {
        var entries = entries(batchID)
        entries.append(BatchMediaLog(at: Date(), line: line))
        if entries.count > cap {
            entries.removeFirst(entries.count - cap)
        }
        cache[key(batchID)] = entries
        DiskStore.save(entries, key: key(batchID))
    }

    static func entries(_ batchID: UUID) -> [BatchMediaLog] {
        let k = key(batchID)
        if let cached = cache[k] { return cached }
        let loaded = DiskStore.load([BatchMediaLog].self, key: k) ?? []
        cache[k] = loaded
        return loaded
    }

    static func remove(_ batchID: UUID) {
        // **归档而不是删除**（2026-11-26 事故：从面板移除批次把日志一起删了，排障时证据没了）。
        archive(batchID)
        cache[key(batchID)] = nil
        DiskStore.remove(key: key(batchID))
    }

    /// 把这一批的日志另存到 `storage/batch-log-archive/`（上限 100 份，按修改时间淘汰最旧）。
    private static func archive(_ batchID: UUID) {
        let entries = entries(batchID)
        guard !entries.isEmpty, let data = try? JSONEncoder().encode(entries) else { return }
        let fm = FileManager.default
        let dir = StorageRoot.directory.appendingPathComponent("batch-log-archive", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("batch-log-\(batchID.uuidString).json"), options: .atomic)
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l < r
            } ?? []
        for stale in files.dropLast(100) { try? fm.removeItem(at: stale) }
    }
}
