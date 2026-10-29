import Combine
import Foundation

/// Agent 记录的**能力缺口**（v0.8.22）：它自己说"这里我需要的能力/工具不存在"。
///
/// 与 `AgentWorkReport`（客观事实，派生）互补：这是唯一来自 Agent 的主观反馈，
/// 由 `reportCapabilityGap` 工具写入，按能力名归一化去重累计。编程工具通过
/// 桥/MCP 拉取并按 `count` 排序，决定先补什么。
nonisolated struct AgentGap: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    /// 缺的能力（显示用原文；匹配用归一化）。
    var capability: String
    /// 当时卡在哪（具体页面/操作）。
    var blocked: String
    /// 用的什么替代方案。
    var workaround: String
    /// blocker | friction | nice-to-have
    var severity: String
    /// 触发时的上下文（当前页面 URL / 目标）。
    var context: String
    var firstSeen: Date
    var lastSeen: Date
    var count: Int
    var conversationID: UUID?
}

@MainActor
final class AgentGapStore: ObservableObject {
    static let shared = AgentGapStore()

    @Published private(set) var gaps: [AgentGap] = []

    private static let key = "agent-gaps"
    private static let cap = 200

    private init() {
        gaps = DiskStore.load([AgentGap].self, key: Self.key) ?? []
    }

    /// 按出现次数降序（同次数看最近出现）——编程工具的直接消费口径。
    var ranked: [AgentGap] {
        gaps.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.lastSeen > $1.lastSeen
        }
    }

    @discardableResult
    func add(capability: String,
             blocked: String = "",
             workaround: String = "",
             severity: String = "friction",
             context: String = "",
             conversationID: UUID? = nil) -> AgentGap? {
        let display = capability.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty else { return nil }
        let matchKey = Self.normalize(display)
        let now = Date()
        let level = Self.severityRank(severity)

        if let index = gaps.firstIndex(where: { Self.normalize($0.capability) == matchKey }) {
            gaps[index].count += 1
            gaps[index].lastSeen = now
            if !blocked.isEmpty { gaps[index].blocked = Self.clip(blocked, 400) }
            if !workaround.isEmpty { gaps[index].workaround = Self.clip(workaround, 400) }
            if level > Self.severityRank(gaps[index].severity) {
                gaps[index].severity = Self.canonicalSeverity(severity)
            }
            if !context.isEmpty { gaps[index].context = Self.clip(context, 300) }
            if let conversationID { gaps[index].conversationID = conversationID }
            trim()
            persist()
            return gaps[index]
        }

        let gap = AgentGap(
            id: UUID(),
            capability: Self.clip(display, 200),
            blocked: Self.clip(blocked, 400),
            workaround: Self.clip(workaround, 400),
            severity: Self.canonicalSeverity(severity),
            context: Self.clip(context, 300),
            firstSeen: now,
            lastSeen: now,
            count: 1,
            conversationID: conversationID)
        gaps.append(gap)
        trim()
        persist()
        return gap
    }

    func remove(id: UUID) {
        gaps.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        gaps.removeAll()
        persist()
    }

    /// 桥 `GET /agent/gaps` / MCP `getAgentGaps` 的载荷。
    func payload() -> [String: Any] {
        [
            "count": gaps.count,
            "totalReports": gaps.reduce(0) { $0 + $1.count },
            "gaps": ranked.map { gap -> [String: Any] in
                var item: [String: Any] = [
                    "id": gap.id.uuidString,
                    "capability": gap.capability,
                    "severity": gap.severity,
                    "count": gap.count,
                    "blocked": gap.blocked,
                    "workaround": gap.workaround,
                    "context": gap.context,
                    "firstSeen": gap.firstSeen.timeIntervalSince1970,
                    "lastSeen": gap.lastSeen.timeIntervalSince1970,
                ]
                if let conversationID = gap.conversationID {
                    item["conversationId"] = conversationID.uuidString
                }
                return item
            },
        ]
    }

    // MARK: - 归一化

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func severityRank(_ value: String) -> Int {
        switch value.lowercased() {
        case "blocker": return 3
        case "friction": return 2
        default: return 1
        }
    }

    static func canonicalSeverity(_ value: String) -> String {
        switch severityRank(value) {
        case 3: return "blocker"
        case 2: return "friction"
        default: return "nice-to-have"
        }
    }

    private static func clip(_ text: String, _ max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max))
    }

    private func trim() {
        guard gaps.count > Self.cap else { return }
        gaps = Array(gaps.sorted { $0.lastSeen > $1.lastSeen }.prefix(Self.cap))
    }

    private func persist() {
        DiskStore.save(gaps, key: Self.key)
    }
}
