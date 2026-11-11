import Foundation

/// 后台任务的取消/重试分派（v0.8.39）：Agent 工具、自动化桥、Remote 共用
/// 一份实现，避免三处各写一套导致行为漂移。
@MainActor
enum JobControl {
    static func cancel(_ id: UUID) -> Result<String, CommandLaunchError> {
        guard let job = JobStore.shared.allJobs.first(where: { $0.id == id }) else {
            return .failure(CommandLaunchError(String(localized: "No background task with that id")))
        }
        if job.kind == .command {
            guard BackgroundCommandStore.shared.runningIDs.contains(id) else {
                return .failure(CommandLaunchError(
                    String(localized: "That command is not running (state: \(job.state.label))")))
            }
            BackgroundCommandStore.shared.cancel(id)
            return .success(String(localized: "Cancellation requested for \(job.title)."))
        }
        let external = job.externalID ?? ""
        if job.source == "batchTool" {
            guard BatchToolStore.shared.jobID == id else {
                return .failure(CommandLaunchError(
                    String(localized: "That batch is not running (state: \(job.state.label))")))
            }
            BatchToolStore.shared.cancel()
            return .success(String(localized: "Cancellation requested for the batch."))
        }
        if external.hasPrefix("batch-"),
           let batchID = UUID(uuidString: String(external.dropFirst("batch-".count))) {
            BatchMediaExportStore.shared.cancel(batchID: batchID)
            return .success(String(localized: "Cancellation requested for the batch download."))
        }
        if external.hasPrefix("download-"),
           let downloadID = UUID(uuidString: String(external.dropFirst("download-".count))) {
            DownloadStore.live?.remove(id: downloadID)
            return .success(String(localized: "Download removed and transfer cancelled."))
        }
        if external.hasPrefix("export-"),
           let exportID = UUID(uuidString: String(external.dropFirst("export-".count))) {
            MediaExportStore.shared.cancel(id: exportID)
            return .success(String(localized: "Cancellation requested for the media export."))
        }
        return .failure(CommandLaunchError(
            String(localized: "This kind of task cannot be cancelled from here (state: \(job.state.label))")))
    }

    static func retry(_ id: UUID) async -> Result<UUID, CommandLaunchError> {
        guard let job = JobStore.shared.allJobs.first(where: { $0.id == id }) else {
            return .failure(CommandLaunchError(String(localized: "No background task with that id")))
        }
        guard job.kind == .command else {
            return .failure(CommandLaunchError(
                String(localized: "Retry is not available for \(job.kind.label) tasks yet.")))
        }
        switch await BackgroundCommandStore.shared.retry(id) {
        case .success(let newID):
            return .success(newID)
        case .failure(let error):
            return .failure(error)
        }
    }
}
