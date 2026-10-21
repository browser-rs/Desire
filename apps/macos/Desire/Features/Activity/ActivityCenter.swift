import Foundation

/// 活动中心（v0.7.29）：把下载、批量媒体、媒体导出、定时任务、运行中的
/// Agent 与 crew 收成一张"现在在跑什么"的清单。纯逻辑（进 harness）——
/// 采集在 `ActivityCenterCollector`，桥与面板共用同一构建。
nonisolated enum ActivityCenter {
    enum Kind: String, CaseIterable {
        case download, batch, export, scheduledRun, agent, crew

        var title: String {
            switch self {
            case .download: return String(localized: "Downloads")
            case .batch: return String(localized: "Batch media")
            case .export: return String(localized: "Media exports")
            case .scheduledRun: return String(localized: "Scheduled tasks")
            case .agent: return String(localized: "Agent sessions")
            case .crew: return String(localized: "Crew")
            }
        }

        var icon: String {
            switch self {
            case .download: return "arrow.down.circle"
            case .batch: return "square.stack.3d.up"
            case .export: return "film"
            case .scheduledRun: return "clock.arrow.circlepath"
            case .agent: return "sparkles"
            case .crew: return "person.3.sequence"
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let id: String
        let kind: Kind
        var title: String
        var detail: String
        var status: String
        var progress: Double?
        var timestamp: Date

        /// 仍在跑/等待（排序时置顶）。
        var active: Bool { Self.activeStatuses.contains(status) }

        static let activeStatuses: Set<String> = [
            "inProgress", "running", "pending", "resolving", "downloading",
            "paused", "queued", "needsHuman", "delivered", "busy", "remuxing",
        ]
    }

    struct Inputs {
        struct Download {
            var id: String
            var filename: String
            var state: String
            var progress: Double?
            var error: String?
            var timestamp: Date
        }
        struct Batch {
            var id: String
            var folder: String
            var state: String
            var settled: Int
            var total: Int
            var timestamp: Date
        }
        struct Export {
            var id: String
            var title: String
            var state: String
            var summary: String?
            var timestamp: Date
        }
        struct Run {
            var id: String
            var taskName: String
            var status: String
            var error: String?
            var firedAt: Date
            var finishedAt: Date?
        }
        struct AgentSession {
            var id: String
            var title: String
            var busy: Bool
            var timestamp: Date
        }
        struct Crew {
            var objective: String
            var done: Int
            var total: Int
            var settled: Bool
            var timestamp: Date
        }

        var downloads: [Download] = []
        var batches: [Batch] = []
        var exports: [Export] = []
        var runs: [Run] = []
        var sessions: [AgentSession] = []
        var crew: Crew?
    }

    static func build(_ inputs: Inputs) -> [Item] {
        var items: [Item] = []
        for download in inputs.downloads {
            items.append(Item(
                id: "download-\(download.id)", kind: .download,
                title: download.filename,
                detail: download.error ?? (download.progress.map {
                    "\(Int(($0 * 100).rounded()))%"
                } ?? ""),
                status: download.state,
                progress: download.progress,
                timestamp: download.timestamp))
        }
        for batch in inputs.batches {
            items.append(Item(
                id: "batch-\(batch.id)", kind: .batch,
                title: "Batch \(batch.folder)",
                detail: "\(batch.settled)/\(batch.total) settled",
                status: batch.state,
                progress: batch.total > 0 ? Double(batch.settled) / Double(batch.total) : nil,
                timestamp: batch.timestamp))
        }
        for export in inputs.exports {
            items.append(Item(
                id: "export-\(export.id)", kind: .export,
                title: export.title,
                detail: export.summary ?? "",
                status: export.state,
                progress: nil,
                timestamp: export.timestamp))
        }
        for run in inputs.runs {
            items.append(Item(
                id: "run-\(run.id)", kind: .scheduledRun,
                title: run.taskName,
                detail: run.error ?? run.status,
                status: run.status,
                progress: nil,
                timestamp: run.finishedAt ?? run.firedAt))
        }
        for session in inputs.sessions where session.busy {
            items.append(Item(
                id: "agent-\(session.id)", kind: .agent,
                title: session.title,
                detail: String(localized: "Working on a turn"),
                status: "busy",
                progress: nil,
                timestamp: session.timestamp))
        }
        if let crew = inputs.crew {
            items.append(Item(
                id: "crew", kind: .crew,
                title: crew.objective,
                detail: "\(crew.done)/\(crew.total) workers done",
                status: crew.settled ? "finished" : "running",
                progress: crew.total > 0 ? Double(crew.done) / Double(crew.total) : nil,
                timestamp: crew.timestamp))
        }
        return items.sorted { a, b in
            if a.active != b.active { return a.active }
            return a.timestamp > b.timestamp
        }
    }

    /// 桥/页头用的计数摘要。
    static func summary(_ items: [Item]) -> [String: Any] {
        var byKind: [String: Int] = [:]
        for item in items { byKind[item.kind.rawValue, default: 0] += 1 }
        return [
            "ok": true,
            "active": items.filter(\.active).count,
            "total": items.count,
            "byKind": byKind,
            "items": items.map { item -> [String: Any] in
                var row: [String: Any] = [
                    "id": item.id,
                    "kind": item.kind.rawValue,
                    "title": item.title,
                    "detail": item.detail,
                    "status": item.status,
                    "active": item.active,
                    "timestamp": item.timestamp.timeIntervalSince1970,
                ]
                if let progress = item.progress { row["progress"] = progress }
                return row
            },
        ]
    }
}
