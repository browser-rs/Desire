import Combine
import Foundation

/// 批量纯工具执行（v0.8.51 批 4）：逐文件跑 `BatchToolCore.process`，
/// 进 Jobs 台账（进度、逐文件回执、失败可见、可取消）。工具箱页与
/// Agent 工具共用同一个实例，后台跑完给通知与会话备注。
@MainActor
final class BatchToolStore: ObservableObject {
    static let shared = BatchToolStore()

    @Published private(set) var isRunning = false
    @Published private(set) var jobID: UUID?
    @Published private(set) var progress: Double = 0
    @Published private(set) var detail = ""
    @Published private(set) var results: [BatchToolFileResult] = []
    @Published private(set) var summary = ""

    private var runner: Task<Void, Never>?

    private init() {}

    /// 启动一批；已有任务在跑时返回 nil（不排队——批量作业不该悄悄叠）。
    @discardableResult
    func start(action: BatchToolAction, files: [URL],
               options: BatchToolOptions) -> UUID? {
        guard !isRunning, !files.isEmpty else { return nil }
        let batch = Array(files.prefix(BatchToolCore.maxFiles))
        let job = JobStore.shared.start(
            title: String(localized: "Batch \(action.title)"),
            kind: .other,
            detail: "\(batch.count) file(s)",
            source: "batchTool")
        isRunning = true
        jobID = job
        results = []
        summary = ""
        progress = 0
        detail = "0/\(batch.count)"

        runner = Task { @MainActor [weak self] in
            guard let self else { return }
            var collected: [BatchToolFileResult] = []
            var cancelled = false
            for (index, file) in batch.enumerated() {
                if Task.isCancelled {
                    cancelled = true
                    break
                }
                let options = options
                let result = await Task.detached(priority: .utility) {
                    BatchToolCore.process(file: file, action: action, options: options)
                }.value
                collected.append(result)
                self.results = collected
                self.progress = Double(index + 1) / Double(batch.count)
                self.detail = "\(index + 1)/\(batch.count): \(file.lastPathComponent)"
                JobStore.shared.update(job, detail: self.detail, progress: self.progress)
            }
            let text = BatchToolCore.summary(action: action, results: collected)
            self.summary = text
            self.results = collected
            self.isRunning = false
            self.runner = nil
            self.jobID = nil
            let failed = collected.filter { !$0.isSuccess }.count
            if cancelled {
                JobStore.shared.finish(job, state: .cancelled,
                                       detail: "Cancelled after \(collected.count)/\(batch.count)",
                                       receipt: text)
            } else {
                JobStore.shared.finish(job,
                                       state: failed == 0 ? .done : .failed,
                                       detail: "\(collected.count - failed)/\(collected.count) ok",
                                       receipt: text,
                                       error: failed == 0 ? nil : "\(failed) file(s) failed")
                AgentScheduler.shared.deliveryTarget?.appendExternalNote(
                    "Batch \(action.title) finished: \(collected.count - failed)/\(collected.count) ok")
                ProactiveNotificationStore.shared.deliver(
                    title: String(localized: "Batch \(action.title) finished"),
                    body: String(localized: "\(collected.count - failed) of \(collected.count) file(s) succeeded."),
                    tier: .routine)
            }
        }
        return job
    }

    func cancel() {
        runner?.cancel()
        detail = String(localized: "Cancelling…")
    }
}
