import Foundation

/// 活动中心的实时采集（MainActor，读各 store 的 live/singleton 实例）。
/// 纯构建在 `ActivityCenter.build`；桥与面板都走这里。
@MainActor
enum ActivityCenterCollector {
    static func liveInputs() -> ActivityCenter.Inputs {
        var inputs = ActivityCenter.Inputs()

        if let downloads = DownloadStore.live {
            inputs.downloads = downloads.downloads.prefix(30).map { item in
                ActivityCenter.Inputs.Download(
                    id: item.id.uuidString,
                    filename: item.filename,
                    state: item.isQueued ? "queued"
                        : (item.isPaused ? "paused" : item.state.rawValue),
                    progress: item.totalBytes > 0 ? item.progress : nil,
                    error: item.error,
                    timestamp: item.lastUpdateTime)
            }
        }

        inputs.batches = BatchMediaExportStore.shared.batches.prefix(10).map { batch in
            ActivityCenter.Inputs.Batch(
                id: batch.id.uuidString,
                folder: batch.folderName,
                state: batch.state.rawValue,
                settled: batch.settledCount,
                total: batch.items.count,
                timestamp: batch.createdAt)
        }

        inputs.exports = MediaExportStore.shared.jobs.prefix(10).map { job in
            ActivityCenter.Inputs.Export(
                id: job.id.uuidString,
                title: job.title,
                state: job.state.rawValue,
                summary: job.summary,
                timestamp: job.finishedAt ?? job.startedAt)
        }

        inputs.runs = AgentScheduler.shared.runs.prefix(20).map { run in
            ActivityCenter.Inputs.Run(
                id: run.id.uuidString,
                taskName: run.taskName,
                status: run.status,
                error: run.error,
                firedAt: run.firedAt,
                finishedAt: run.finishedAt)
        }

        inputs.sessions = AgentScheduler.shared.liveSessions().compactMap { session in
            guard let store = session.store, store.isProcessing else { return nil }
            return ActivityCenter.Inputs.AgentSession(
                id: session.id.uuidString,
                title: session.displayLabel,
                busy: true,
                timestamp: Date())
        }

        if let crew = AgentCrewStore.shared.crew {
            inputs.crew = ActivityCenter.Inputs.Crew(
                objective: crew.objective,
                done: crew.completedCount,
                total: crew.tasks.count,
                settled: crew.isSettled,
                timestamp: crew.finishedAt ?? crew.createdAt)
        }

        return inputs
    }
}
