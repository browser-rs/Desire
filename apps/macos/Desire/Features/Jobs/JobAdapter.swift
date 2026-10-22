import Foundation

/// 旧子系统 → Job 账本的只读适配（v0.8.2）。下载/批量/媒体导出/定时运行/
/// Agent 回合/crew 继续由各自 store 做状态真相；这里只把它们映射成 JobRecord
/// 供 Jobs 面板与桥统一展示，**不写回、不复制状态**（id 用稳定哈希，刷新不跳行）。
nonisolated enum JobAdapter {
    static func jobs(from items: [ActivityCenter.Item]) -> [JobRecord] {
        items.map { item in
            let kind: JobRecord.Kind
            switch item.kind {
            case .download: kind = .download
            case .batch: kind = .download
            case .export: kind = .download
            case .scheduledRun: kind = .scheduled
            case .agent: kind = .agent
            case .crew: kind = .agent
            }
            let state = mapState(item.status)
            var job = JobRecord(
                id: stableUUID(item.id),
                title: title(for: item),
                kind: kind,
                state: state,
                detail: item.detail,
                progress: item.progress,
                source: "activity",
                externalID: item.id,
                createdAt: item.timestamp,
                updatedAt: item.timestamp)
            if state == .done || state == .failed || state == .cancelled {
                job.finishedAt = item.timestamp
            }
            return job
        }
    }

    static func title(for item: ActivityCenter.Item) -> String {
        switch item.kind {
        case .export: "Export: \(item.title)"
        case .crew: "Crew: \(item.title)"
        default: item.title
        }
    }

    static func mapState(_ raw: String) -> JobRecord.State {
        switch raw.lowercased() {
        case "completed", "success", "done", "finished", "settled":
            return .done
        case "failed", "error", "missed":
            return .failed
        case "cancelled", "canceled":
            return .cancelled
        case "paused":
            return .paused
        case "needshuman", "needsapproval":
            return .needsApproval
        case "queued", "pending":
            return .queued
        default:
            return .running
        }
    }

    /// 稳定 UUID：同一 ActivityCenter item id 每次映射得到同一行。
    static func stableUUID(_ key: String) -> UUID {
        var h1: UInt64 = 14_695_981_039_346_656_037
        var h2: UInt64 = 1_099_511_628_211
        for byte in key.utf8 {
            h1 = (h1 ^ UInt64(byte)) &* 1_099_511_628_211
            h2 = (h2 &+ UInt64(byte)) &* 1_099_511_628_211
        }
        let hex = String(format: "%016llx%016llx", h1, h2)
        let parts = [hex.prefix(8),
                     hex.dropFirst(8).prefix(4),
                     hex.dropFirst(12).prefix(4),
                     hex.dropFirst(16).prefix(4),
                     hex.dropFirst(20).prefix(12)]
        return UUID(uuidString: parts.map(String.init).joined(separator: "-")) ?? UUID()
    }
}
