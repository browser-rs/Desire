import Combine
import Foundation
import os

/// DPP 页面事件驱动回合（2026-10-02 二期）：
/// 页面按 DPP events 声明触发事件（MutationObserver → postMessage → 此处），
/// 事件驱动 Agent 自动开回合（复用 AgentScheduler.deliveryTarget）。
///
/// 三档自动化模式（per-site，UserDefaults 持久化）：
/// - off：事件只记日志，不触发回合
/// - draft：触发回合但 outbound 动作走审批（默认）
/// - auto：全自动（含 outbound，用户显式开启才可用）
///
/// 事件风暴防护：同 host + 同事件名 debounce 聚合、单 host 频率上限。
@MainActor
final class PageEventHub {
    static let shared = PageEventHub()
    static let log = Log.agent

    struct PendingEvent: Identifiable {
        let id = UUID()
        let host: String
        let eventName: String
        let detail: [String: String]
        let timestamp: Date
    }

    /// 事件队列（去重后待处理）。
    @Published private(set) var pendingEvents: [PendingEvent] = []
    /// per-site 自动化模式。
    @Published private(set) var siteModes: [String: String] = [:]

    /// 事件风暴防护：**滑动窗口**内同 host 事件数上限（此前是进程生命周期
    /// 累计 ≤10 且永不归零——每 host 累计 10 次后事件永久静默）。
    /// 策略常量/纯逻辑在 PageEventPolicy（进纯逻辑单测）。
    private var hostEventTimes: [String: [Date]] = [:]
    private var recentEvents: [String: Date] = [:]

    private init() {
        siteModes = UserDefaults.standard.dictionary(forKey: "dpp.eventModes") as? [String: String] ?? [:]
    }

    // MARK: - 模式

    static let modeOff = PageEventPolicy.modeOff
    static let modeDraft = PageEventPolicy.modeDraft
    static let modeAuto = PageEventPolicy.modeAuto

    func setMode(_ mode: String, for host: String) {
        let key = host.lowercased()
        siteModes[key] = mode
        UserDefaults.standard.set(siteModes, forKey: "dpp.eventModes")
    }

    func mode(for host: String) -> String {
        siteModes[host.lowercased()] ?? Self.modeDraft
    }

    // MARK: - 事件接收

    /// 页面事件入口（desire-protocol.js 解析出 events 声明 →
    /// MutationObserver 只在匹配数 0→正 跳变时上报 → 这里防抖 + 限频）。
    func handleEvent(host: String, eventName: String, detail: [String: String]) {
        let mode = mode(for: host)
        guard mode != Self.modeOff else { return }
        // 事件风暴防护 ①：同 host + 同事件名 3s 防抖
        let debounceKey = host + ":" + eventName
        let now = Date()
        if let last = recentEvents[debounceKey],
           now.timeIntervalSince(last) < PageEventPolicy.debounceInterval { return }
        recentEvents[debounceKey] = now
        // 事件风暴防护 ②：单 host 滑动窗口限频（60s 内 ≤10 条）
        guard var times = PageEventPolicy.filterRateWindow(hostEventTimes[host] ?? [], now: now) else {
            Self.log.info("DPP event dropped (rate window): \(host, privacy: .public)")
            return
        }
        times.append(now)
        hostEventTimes[host] = times

        let event = PendingEvent(host: host, eventName: eventName, detail: detail, timestamp: now)
        pendingEvents.append(event)
        // 环形上限：无 UI 消费者，纯诊断队列——长会话不无限增长。
        if pendingEvents.count > 100 {
            pendingEvents.removeFirst(pendingEvents.count - 100)
        }
        Self.log.info("DPP event: \(eventName, privacy: .public) on \(host, privacy: .public) (mode=\(mode, privacy: .public))")
        triggerAgentTurn(for: event)
    }

    /// 事件驱动回合：组装 DPP 上下文 + 策略 prompt → 发给 agent。
    private func triggerAgentTurn(for event: PendingEvent) {
        guard let session = AgentScheduler.shared.deliveryTarget else {
            Self.log.info("DPP event trigger: no delivery target")
            return
        }
        Self.log.info("DPP event trigger: sending prompt to agent")
        let prompt = Self.buildEventPrompt(event: event, mode: mode(for: event.host),
                                           summary: Self.protocolSummary(for: session))
        session.sendMessage(prompt, recordHistory: false)
    }

    /// 事件触发时把页面声明的视图/动作名带上——模型不必先探索就知道用
    /// 哪些工具响应（如 views [thread] → pageExtract("thread") 取新数据）。
    static func protocolSummary(for session: AgentSessionStore) -> String? {
        guard let dpp = session.boundTabManager?.selectedTab?.browser.effectiveProtocol else { return nil }
        var parts: [String] = []
        if !dpp.views.isEmpty {
            parts.append("views [\(dpp.views.keys.sorted().joined(separator: ", "))]")
        }
        if !dpp.actions.isEmpty {
            parts.append("actions [\(dpp.actions.map(\.name).joined(separator: ", "))]")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ") + " — use pageExtract/pageAction to respond"
    }

    static func buildEventPrompt(event: PendingEvent, mode: String, summary: String? = nil) -> String {
        PageEventPolicy.eventPrompt(host: event.host, eventName: event.eventName,
                                    detail: event.detail, timestamp: event.timestamp, mode: mode,
                                    protocolSummary: summary)
    }
}
