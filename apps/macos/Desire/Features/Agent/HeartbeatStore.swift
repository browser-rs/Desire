import Combine
import Foundation
import os

/// 心跳巡检（2026-10-09，设计取自 OpenClaw Heartbeat）：每 N 分钟一次轻量
/// 旁路调用，把「用户清单 + 机器自动信号」交给模型判断**要不要打扰用户**——
/// 回 `HEARTBEAT_OK` 就静默，否则以 routine 档系统通知说事（过免打扰/预算
/// 闸，与通知分级天然组合）。这是 Desire 第一条"模型自决的主动性"：定时
/// 任务/页面监视都是固定触发，只有心跳由模型决定说不说话。
///
/// 防噪音（对应 OpenClaw 的 busy deferral / active hours / empty skip）：
/// 回合进行中推迟到下个 tick；免打扰时段内跳过（省调用，摘要由通知侧照常
/// 补推）；清单与信号全空跳过。用量未记账（旁路调用发生在任何会话之外，
/// 无消息可挂——成本极小，已知边界）。
@MainActor
final class HeartbeatStore: ObservableObject {
    static let shared = HeartbeatStore()

    static let intervalChoices = [15, 30, 60, 120, 240]

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "agentHeartbeatEnabled") }
    }
    @Published var intervalMinutes: Int {
        didSet {
            let clamped = Self.intervalChoices.contains(intervalMinutes) ? intervalMinutes : 60
            if clamped != intervalMinutes { intervalMinutes = clamped }
            UserDefaults.standard.set(intervalMinutes, forKey: "agentHeartbeatMinutes")
        }
    }
    /// 巡检清单（HEARTBEAT.md 的对应物）：常驻指令，逐行自由文本。
    @Published var checklist: String {
        didSet {
            if checklist != oldValue {
                UserDefaults.standard.set(checklist, forKey: "agentHeartbeatChecklist")
            }
        }
    }
    /// **发现即处理**：心跳说出某事后，自动派一个真实 agent 回合去核实/处理
    /// （走 deliverScheduled，忙时排队）。关 = 只提醒不动手。
    @Published var autoHandle: Bool {
        didSet { UserDefaults.standard.set(autoHandle, forKey: "agentHeartbeatAutoHandle") }
    }
    @Published private(set) var lastBeatAt: Date?
    /// 上一次心跳的结论：静默 / 说的话（截断展示用）。
    @Published private(set) var lastResult: String?
    @Published private(set) var isBeating = false

    private var timer: Timer?
    private static let lastBeatKey = "agentHeartbeatLastBeat"

    init() {
        isEnabled = UserDefaults.standard.object(forKey: "agentHeartbeatEnabled") as? Bool ?? false
        let stored = UserDefaults.standard.object(forKey: "agentHeartbeatMinutes") as? Int ?? 60
        intervalMinutes = Self.intervalChoices.contains(stored) ? stored : 60
        checklist = UserDefaults.standard.string(forKey: "agentHeartbeatChecklist") ?? ""
        autoHandle = UserDefaults.standard.object(forKey: "agentHeartbeatAutoHandle") as? Bool ?? false
        lastBeatAt = UserDefaults.standard.object(forKey: Self.lastBeatKey) as? Date
        // 60s 粒度的 tick：到点才跑，忙时/免打扰自然推迟到下个 tick。
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.beatIfDue()
            }
        }
    }

    // MARK: - 调度

    func beatIfDue() {
        guard isEnabled, !isBeating else { return }
        if let last = lastBeatAt,
           Date().timeIntervalSince(last) < TimeInterval(intervalMinutes * 60) {
            return
        }
        // 忙时推迟（busy deferral）：不打断进行中的回合，下个 tick 再看。
        if AgentScheduler.shared.deliveryTarget?.isProcessing == true { return }
        // 免打扰时段跳过：省一次模型调用；真有事也推不出去（会被扣进摘要），
        // 等时段结束的下一个 tick 再说。
        if Self.isQuietNow() { return }
        Task { [weak self] in
            await self?.runBeat(force: false)
        }
    }

    /// 手动/E2E 立即心跳：绕过间隔与免打扰（绕不过清单+信号全空的省调用闸）。
    @discardableResult
    func beatNow() async -> (decision: String, message: String, notified: Bool, signals: [String]) {
        await runBeat(force: true)
    }

    // MARK: - 执行

    private func runBeat(force: Bool) async -> (decision: String, message: String, notified: Bool, signals: [String]) {
        guard !isBeating else { return ("skipped", "", false, []) }
        isBeating = true
        defer { isBeating = false }

        let signals = gatherSignals()
        let signalTitles = signals.map(\.title)
        let list = checklist.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空跳过（OpenClaw 的 empty-heartbeat-file 语义）：没有清单也没有信号
        // 时这一拍无事可判，省一次 API 调用。
        guard force || !list.isEmpty || !signals.isEmpty else {
            recordBeat(result: "（无清单无信号，跳过）")
            return ("skipped", "", false, signalTitles)
        }

        guard let preference = AppState.live?.aiPreference else {
            recordBeat(result: "（偏好不可用）")
            return ("skipped", "", false, signalTitles)
        }
        let prefs = preference.bypassPreferences() ?? preference
        let prompt = HeartbeatDecision.userPrompt(checklist: list, signals: signals)
        let text = await MemoryExtractor.collectText(
            preference: prefs,
            system: HeartbeatDecision.systemPrompt(),
            user: prompt)
        let outcome = HeartbeatDecision.parse(text)
        let decision: String
        let message: String
        var notified = false
        switch outcome {
        case .silent:
            decision = "silent"
            message = ""
            recordBeat(result: "静默")
        case .speak(let spoken):
            decision = "speak"
            message = spoken
            // routine 档：免打扰/超预算时会被扣进摘要，不绕过通知分级。
            ProactiveNotificationStore.shared.deliver(
                title: String(localized: "Agent Heartbeat"),
                body: spoken,
                tier: .routine)
            notified = true
            recordBeat(result: String(spoken.prefix(120)))
            // 会话备注：模型下一轮能知道心跳已经提醒过（防每个 beat 重复说同一件事）。
            AgentScheduler.shared.deliveryTarget?.appendExternalNote("心跳巡检提醒用户：\(spoken)")
            // 发现即处理：派一个真实回合去核实/处理（deliverScheduled 忙时排队，
            // 不打断进行中的回合）。prompt 给足上下文并要求一句话汇报。
            if autoHandle,
               let target = AgentScheduler.shared.deliveryTarget {
                let prompt = """
                心跳巡检发现以下情况，请核实并酌情处理：

                \(spoken)

                这是心跳巡检的自动委派（用户已开启"发现即处理"）。先核实情况是否属实，
                属实就处理到力所能及的程度（不做危险/不可逆操作），最后用一两句话向用户
                汇报结果。
                """
                target.deliverScheduled(prompt, from: "Heartbeat")
            }
        }
        return (decision, message, notified, signalTitles)
    }
}

extension HeartbeatStore {
    /// 距上次心跳以来的自动信号：页面监视变化（带 AI 分析结论）、失败的定时
    /// 任务、被打断的回合、最近没人回复的会话（Dots 式"未完成事务收件箱"）。
    fileprivate func gatherSignals() -> [HeartbeatDecision.Signal] {
        var signals: [HeartbeatDecision.Signal] = []
        let since = lastBeatAt ?? Date().addingTimeInterval(-TimeInterval(intervalMinutes * 60))
        for watch in PageWatchStore.shared.watches where watch.isEnabled {
            guard let changed = watch.lastChangedAt, changed > since else { continue }
            var detail = "内容发生变化（共 \(watch.changeCount) 次）"
            if let analysis = watch.lastAnalysis?.trimmingCharacters(in: .whitespacesAndNewlines),
               !analysis.isEmpty {
                detail += "；AI 分析：\(String(analysis.suffix(160)))"
            }
            signals.append(HeartbeatDecision.Signal(title: "页面监视「\(watch.name)」", detail: detail))
        }
        for run in AgentScheduler.shared.runs {
            guard run.status == "failed", let finished = run.finishedAt, finished > since else { continue }
            signals.append(HeartbeatDecision.Signal(
                title: "定时任务「\(run.taskName)」失败",
                detail: String((run.error ?? "unknown error").prefix(160))))
        }
        // 未完成事务收件箱：被打断的回合（面板有"继续/放弃"入口）。
        if let session = AgentScheduler.shared.deliveryTarget, session.hasInterruptedTurn {
            signals.append(HeartbeatDecision.Signal(
                title: "当前会话有被打断的回合",
                detail: "上一回合没有正常收尾，可在面板里继续或放弃"))
        }
        // 最近 48h 内、最后一条消息是用户且没有回复的会话（上限 4 条防吵）。
        // 活会话的"回合进行中"不算——那不是遗留，是正在发生。
        let store = AppState.live?.conversationStore ?? ConversationStore()
        var pendingConversations = 0
        for conv in store.conversations where pendingConversations < 4 {
            guard let last = conv.messages.last, last.role == .user,
                  !(conv.turnActive ?? false),
                  Date().timeIntervalSince(conv.updatedAt) < 48 * 3600 else { continue }
            let excerpt = (last.content ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            signals.append(HeartbeatDecision.Signal(
                title: "会话「\(conv.title)」有待回复的消息",
                detail: String(excerpt.prefix(120))))
            pendingConversations += 1
        }
        return signals
    }

    private func recordBeat(result: String) {
        lastBeatAt = Date()
        lastResult = result
        UserDefaults.standard.set(lastBeatAt, forKey: Self.lastBeatKey)
    }

    fileprivate static func isQuietNow() -> Bool {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return ProactiveNotificationStore.shared.policy.isQuietTime(minutesSinceMidnight: minutes)
    }
}
