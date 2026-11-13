import Combine
import Foundation
import os

/// 链失败（Result 的 Error 侧——String 不符合 Error）。
struct ChainFailure: Error {
    let message: String
}

/// 作业链运行器（v0.8.57 批 2）：链模板（JobTemplate.chainSteps）按序推进。
/// 挂点 = `JobEventCenter.recordTerminal`（每步终态回调这里推进）。
/// 状态在内存——app 退出未完成链随 Job 标 interrupted（与 Job 同口径）；
/// 链本身不另落盘（Job 台账里每步都是普通 Job，`_chain` 日志可回溯）。
@MainActor
final class JobChainRunner: ObservableObject {
    static let shared = JobChainRunner()
    private let log = Logger(subsystem: "me.siwi.Desire", category: "jobs")

    private init() {}

    struct ChainRun: Identifiable {
        let id: UUID
        let name: String
        let steps: [JobChainCore.Step]
        /// 已启动步骤的 jobID（下标 = 步骤下标）。
        var startedJobIDs: [UUID]
        var state: State
        var conversationID: UUID?

        enum State: String {
            case running, finished, stopped
        }
    }

    @Published private(set) var runs: [ChainRun] = []

    /// 启动一条链：校验 → 起第一步。返回错误文案或链 id。
    @discardableResult
    func start(template: JobTemplate, conversationID: UUID?) async -> Result<UUID, ChainFailure> {
        let steps = template.chainSteps
        if let error = JobChainCore.validationError(steps: steps) {
            return .failure(ChainFailure(message: error))
        }
        let run = ChainRun(id: UUID(), name: template.name, steps: steps,
                           startedJobIDs: [], state: .running,
                           conversationID: conversationID)
        runs.append(run)
        log.info("chain '\(template.name, privacy: .public)': starting step 1/\(steps.count)")
        await launchStep(at: 0, of: run, artifactPath: nil)
        return .success(run.id)
    }

    /// 终态回调（JobEventCenter.recordTerminal 调）：找到持有该 jobID 的
    /// 链并推进。
    func jobDidFinish(jobID: UUID) {
        guard let runIndex = runs.firstIndex(where: {
            $0.state == .running && $0.startedJobIDs.contains(jobID)
        }) else { return }
        guard let stepIndex = runs[runIndex].startedJobIDs.firstIndex(of: jobID) else { return }
        let job = JobStore.shared.job(id: jobID)
        let state = job?.state.rawValue ?? "failed"
        let runName = runs[runIndex].name
        let total = runs[runIndex].steps.count
        switch JobChainCore.advance(stepCount: total,
                                    finishedStepIndex: stepIndex,
                                    state: state) {
        case .finished:
            runs[runIndex].state = .finished
            log.info("chain '\(runName, privacy: .public)': finished (\(total) steps)")
        case .stopped(let reason):
            runs[runIndex].state = .stopped
            log.error("chain '\(runName, privacy: .public)': stopped — \(reason, privacy: .public)")
        case .start(let next):
            let artifact = job?.artifactURL
            log.info("chain '\(runName, privacy: .public)': step \(stepIndex + 1)/\(total) done → starting \(next + 1)")
            let snapshot = runs[runIndex]
            Task { @MainActor [weak self] in
                await self?.launchStep(at: next, of: snapshot, artifactPath: artifact)
            }
        }
    }

    /// 启动第 `at` 步（占位符按上一步产物替换）。
    private func launchStep(at index: Int, of run: ChainRun, artifactPath: String?) async {
        let step = run.steps[index]
        let artifact = artifactPath ?? ""
        let (params, unresolved) = JobChainCore.substitute(step.params, artifactPath: artifact)
        if !unresolved.isEmpty {
            log.error("chain '\(run.name, privacy: .public)': unresolved placeholders \(unresolved.joined(separator: ","), privacy: .public) — stopping")
            markStopped(id: run.id)
            return
        }
        let result: Result<UUID, ChainFailure>
        switch step.kind {
        case .command:
            let tool = params["tool"] ?? ""
            let args = JobChainEncoding.decodeArray(params["args"] ?? "[]")
            let timeout = Double(params["timeoutMinutes"] ?? "") ?? 60
            let inner = await BackgroundCommandStore.shared.start(
                tool: tool, args: args, title: "\(run.name) · step \(index + 1)",
                cwd: (params["cwd"] ?? "").isEmpty ? nil : params["cwd"],
                timeoutMinutes: timeout, conversationID: run.conversationID,
                report: nil, after: [], maxAttempts: 1, retryOn: "nonZero",
                priority: "normal")
            switch inner {
            case .success(let id): result = .success(id)
            case .failure(let error): result = .failure(ChainFailure(message: error.message))
            }
        case .officeBatch:
            guard let folder = params["folder"], !folder.isEmpty else {
                markStopped(id: run.id)
                return
            }
            switch OfficeBatchStore.shared.start(
                folder: URL(fileURLWithPath: folder),
                format: params["format"] ?? "pdf",
                recursive: params["recursive"] != "false",
                conversationID: run.conversationID, report: nil) {
            case .success(let id): result = .success(id)
            case .failure(let error): result = .failure(ChainFailure(message: error.message))
            }
        case .imageBatch:
            guard let folder = params["folder"], !folder.isEmpty else {
                markStopped(id: run.id)
                return
            }
            let longEdge = Int(params["longEdge"] ?? "") ?? 0
            switch ImageBatchEditStore.shared.start(
                folder: URL(fileURLWithPath: folder),
                format: params["format"] ?? "jpeg",
                quality: Double(params["quality"] ?? "") ?? 0.9,
                longEdge: longEdge >= 16 ? longEdge : nil,
                recursive: params["recursive"] != "false",
                presetName: (params["preset"] ?? "").isEmpty ? nil : params["preset"],
                conversationID: run.conversationID) {
            case .success(let id): result = .success(id)
            case .failure(let error): result = .failure(ChainFailure(message: error.message))
            }
        }
        switch result {
        case .success(let jobID):
            if let runIndex = runs.firstIndex(where: { $0.id == run.id }) {
                while runs[runIndex].startedJobIDs.count <= index {
                    runs[runIndex].startedJobIDs.append(UUID())
                }
                runs[runIndex].startedJobIDs[index] = jobID
            }
        case .failure(let message):
            log.error("chain '\(run.name, privacy: .public)': step \(index + 1) failed to start — \(message, privacy: .public)")
            markStopped(id: run.id)
        }
    }

    private func markStopped(id: UUID) {
        if let idx = runs.firstIndex(where: { $0.id == id }) {
            runs[idx].state = .stopped
        }
    }
}
