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

    private var recentEvents: [String: Date] = [:]
    private let debounceInterval: TimeInterval = 3.0
    private let maxPerHost = 10
    private var hostEventCounts: [String: Int] = [:]

    private init() {}

    // MARK: - 模式

    static let modeKey = "dpp.eventMode."
    static let modeOff = "off"
    static let modeDraft = "draft"
    static let modeAuto = "auto"

    func setMode(_ mode: String, for host: String) {
        siteModes[host.lowercased()] = mode
        UserDefaults.standard.set(siteModes, forKey: "dpp.eventModes")
    }

    func mode(for host: String) -> String {
        siteModes[host.lowercased()]
            ?? UserDefaults.standard.string(forKey: Self.modeKey + host.lowercased())
            ?? Self.modeDraft
    }

    // MARK: - 事件接收

    /// 页面事件入口（desire-protocol.js 解析出 events 声明 →
    /// MutationObserver 监听 → postMessage → AgentSessionStore 转发到这里）。
    func handleEvent(host: String, eventName: String, detail: [String: String]) {
        let mode = mode(for: host)
        guard mode != Self.modeOff else { return }
        // 事件风暴防护
        let debounceKey = host + ":" + eventName
        if let last = recentEvents[debounceKey],
           Date().timeIntervalSince(last) < debounceInterval { return }
        recentEvents[debounceKey] = Date()
        hostEventCounts[host, default: 0] += 1
        guard hostEventCounts[host] ?? 0 <= maxPerHost else { return }

        let event = PendingEvent(host: host, eventName: eventName, detail: detail, timestamp: Date())
        pendingEvents.append(event)
        Self.log.info("DPP event: \(eventName, privacy: .public) on \(host, privacy: .public) (mode=\(mode, privacy: .public))")
        triggerAgentTurn(for: event)
    }

    /// 事件驱动回合：组装 DPP 上下文 + 策略 prompt → 发给 agent。
    private func triggerAgentTurn(for event: PendingEvent) {
        guard let session = AgentScheduler.shared.deliveryTarget else { return }
        let prompt = Self.buildEventPrompt(event: event, mode: mode(for: event.host))
        session.sendMessage(prompt, recordHistory: false)
    }

    static func buildEventPrompt(event: PendingEvent, mode: String) -> String {
        var lines = [
            "[DPP Event] Page event triggered on \(event.host):",
            "- Event: \(event.eventName)",
            "- Time: \(event.timestamp.formatted())"
        ]
        for (key, value) in event.detail.sorted(by: { $0.key < $1.key }) {
            lines.append("- \(key): \(value)")
        }
        switch mode {
        case Self.modeAuto:
            lines.append("Act on this event using the page's declared actions. Outbound actions are pre-approved for this site.")
        case Self.modeDraft:
            lines.append("Analyze this event and prepare a response using the page's declared actions. Show me what you would do before executing outbound actions.")
        default:
            break
        }
        return lines.joined(separator: "\n")
    }
}
