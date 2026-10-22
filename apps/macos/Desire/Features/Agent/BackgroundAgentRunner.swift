import Combine
import Foundation

/// 后台 Agent Runner（v0.8.2）：没有活窗口时，定时/Playbook 等 Agent 任务
/// 不再直接记 "missed"，而是在一个**隐藏的无头标签**里跑完整工具循环。
///
/// 边界（刻意收窄）：
/// - 同一时刻只跑一个后台作业（避免多个 headless webview 抢资源）；
/// - 强制 `.confirmChanges` 访问等级，后台不允许静默 fullAccess；
/// - 需要审批时作业停在 `needsApproval`（Jobs 面板可批准/拒绝），
///   超过 `agent.background.approvalSeconds`（默认 120s）自动拒绝；
/// - 整个作业有 wall-clock 上限（`agent.background.timeoutSeconds`，默认 600s）；
/// - 无头 TabManager 不注册、不落盘、不参与窗口会话。
@MainActor
final class BackgroundAgentRunner: ObservableObject {
    static let shared = BackgroundAgentRunner()

    struct Outcome {
        let ok: Bool
        let error: String?
        let jobID: UUID?
    }

    private final class Run {
        let jobID: UUID
        let session: AgentSessionStore
        let manager: TabManager
        var approvalWatch: AnyCancellable?
        var approvalTimeoutTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var continuation: CheckedContinuation<AgentSessionStore.TurnOutcome, Never>?
        private var settled = false

        init(jobID: UUID, session: AgentSessionStore, manager: TabManager) {
            self.jobID = jobID
            self.session = session
            self.manager = manager
        }

        func settle(_ outcome: AgentSessionStore.TurnOutcome) {
            guard !settled else { return }
            settled = true
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    @Published private(set) var isBusy = false
    private var runs: [UUID: Run] = [:]
    private var currentJobID: UUID?

    private init() {}

    // MARK: - 配置

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "agent.background.enabled") as? Bool ?? true
    }

    var wallClockTimeout: TimeInterval {
        let raw = UserDefaults.standard.double(forKey: "agent.background.timeoutSeconds")
        return raw > 0 ? raw : 600
    }

    var approvalTimeout: TimeInterval {
        let raw = UserDefaults.standard.double(forKey: "agent.background.approvalSeconds")
        return raw > 0 ? raw : 120
    }

    // MARK: - 运行

    func run(prompt: String, taskName: String) async -> Outcome {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Outcome(ok: false, error: "empty prompt", jobID: nil)
        }
        guard isEnabled else {
            return Outcome(ok: false, error: "background runner disabled", jobID: nil)
        }
        guard currentJobID == nil else {
            return Outcome(ok: false, error: "another background job is running", jobID: nil)
        }
        guard let app = AppState.live else {
            return Outcome(ok: false, error: "app state not ready", jobID: nil)
        }

        let jobID = JobStore.shared.start(
            title: "Background: \(taskName)",
            kind: .scheduled,
            detail: String(trimmed.prefix(140)),
            source: "background")
        currentJobID = jobID
        isBusy = true

        let manager = TabManager(headless: true)
        manager.addTab(url: "about:blank")
        let surface = WindowToolSurface(app: app, tabManager: manager)
        let session = AgentSessionStore(preference: app.aiPreference,
                                        conversationStore: app.conversationStore,
                                        registerAsWindow: false)
        session.configure(with: surface)
        // 后台永远从"变更前确认"开始；用户的全权档不适用于无人值守。
        session.accessLevel = .confirmChanges

        let run = Run(jobID: jobID, session: session, manager: manager)
        runs[jobID] = run

        run.approvalWatch = session.$pendingApproval.sink { [weak self] pending in
            Task { @MainActor [weak self] in
                self?.handleApprovalChange(jobID: jobID, pending: pending)
            }
        }
        run.timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.wallClockTimeout ?? 600))
            guard !Task.isCancelled, let self, let run = self.runs[jobID] else { return }
            run.session.cancel()
            run.settle(AgentSessionStore.TurnOutcome(success: false,
                                   error: "background run timed out"))
        }

        let outcome: AgentSessionStore.TurnOutcome = await withCheckedContinuation { continuation in
            run.continuation = continuation
            session.deliverScheduled(trimmed, from: taskName) { [weak run] turnOutcome in
                run?.settle(turnOutcome)
            }
        }
        cleanup(jobID, outcome: outcome)
        return Outcome(ok: outcome.success, error: outcome.error, jobID: jobID)
    }

    /// Jobs 面板/桥批准或拒绝后台作业的审批。
    @discardableResult
    func resolveApproval(jobID: UUID, decision: ApprovalDecision) -> Bool {
        guard let run = runs[jobID], run.session.pendingApproval != nil else { return false }
        run.approvalTimeoutTask?.cancel()
        run.approvalTimeoutTask = nil
        run.session.resolveApproval(decision)
        JobStore.shared.update(jobID, state: .running,
                               detail: "approval \(decision == .deny ? "denied" : "granted") — continuing")
        return true
    }

    var pendingApprovalJobIDs: [UUID] {
        runs.compactMap { $0.value.session.pendingApproval != nil ? $0.key : nil }
    }

    // MARK: - 内部

    private func handleApprovalChange(jobID: UUID, pending: PendingToolApproval?) {
        guard let run = runs[jobID] else { return }
        guard let pending else {
            run.approvalTimeoutTask?.cancel()
            run.approvalTimeoutTask = nil
            return
        }
        JobStore.shared.update(
            jobID, state: .needsApproval,
            detail: "waiting for approval: \(pending.toolCall.function.name) — approve in Jobs or it is denied in \(Int(approvalTimeout))s")
        run.approvalTimeoutTask?.cancel()
        run.approvalTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.approvalTimeout ?? 120))
            guard !Task.isCancelled, let self, let run = self.runs[jobID],
                  run.session.pendingApproval != nil else { return }
            run.session.resolveApproval(.deny)
            JobStore.shared.update(jobID, state: .running,
                                   detail: "approval timed out — denied, continuing without it")
        }
    }

    private func cleanup(_ jobID: UUID, outcome: AgentSessionStore.TurnOutcome) {
        guard let run = runs.removeValue(forKey: jobID) else { return }
        run.approvalWatch?.cancel()
        run.approvalTimeoutTask?.cancel()
        run.timeoutTask?.cancel()
        if currentJobID == jobID {
            currentJobID = nil
            isBusy = false
        }
        if outcome.success {
            JobStore.shared.finish(jobID, state: .done,
                                   receipt: "Background run finished.")
        } else {
            JobStore.shared.finish(jobID, state: .failed,
                                   error: outcome.error ?? "background run failed")
        }
        run.session.clear(summarizeMemory: false)
    }
}
