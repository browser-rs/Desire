import SwiftUI

/// 轨迹页：把 `AgentTrace` 派生的内容**给人看**——上面是聚合（回合/工具/失败/被拒/平均耗时/
/// 未验证/用户评价 + 最慢与最易错的工具），下面逐回合展开 Thought → Action → Observation。
///
/// 数据全部来自会话本身（不额外埋点），所以这一页和历史消息永远对得上；同一份 `AgentTrace`
/// 也供桥的 `GET /agent/trace` 使用。
struct AgentTraceView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var conversationStore: ConversationStore
    var onBack: () -> Void

    @State private var selectedID: UUID?
    @State private var turns: [[String: Any]] = []
    @State private var stats: [String: Any] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    overviewSection
                    slowestSection
                    turnsSection
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            HoverIcon(systemName: "chevron.left", action: onBack, help: "Back")
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Trace")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 6)
            Menu {
                ForEach(conversationStore.conversations.prefix(15)) { conv in
                    Button {
                        selectedID = conv.id
                        reload()
                    } label: {
                        Label(conv.title, systemImage: conv.id == selectedConversationID ? "checkmark" : "bubble.left")
                    }
                }
            } label: {
                Text(selectedTitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .tint(.secondary)
            HoverIcon(systemName: "arrow.clockwise", action: reload, help: "Reload")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    // MARK: - Sections

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Overview")
            FlowRow(spacing: 6) {
                statChip("Turns", text("turns"))
                statChip("Tool calls", text("toolCalls"))
                statChip("Failed", "\(value("denied") + value("threwError"))",
                         tint: (value("denied") + value("threwError")) > 0 ? .orange : .secondary)
                statChip("Denied", text("denied"), tint: value("denied") > 0 ? .orange : .secondary)
                statChip("Avg tool", msText(double("avgToolMs")))
                statChip("Unverified", text("unverifiedTurns"),
                         tint: value("unverifiedTurns") > 0 ? .orange : .secondary)
                statChip("👍", text("votesUp"), tint: value("votesUp") > 0 ? appAccent : .secondary)
                statChip("👎", text("votesDown"), tint: value("votesDown") > 0 ? .orange : .secondary)
            }
        }
    }

    @ViewBuilder
    private var slowestSection: some View {
        let slowest = stats["slowestTools"] as? [[String: Any]] ?? []
        let flakiest = stats["flakiestTools"] as? [[String: Any]] ?? []
        if !slowest.isEmpty || !flakiest.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Tools")
                ForEach(Array(slowest.enumerated()), id: \.offset) { _, item in
                    toolStatRow(item, kind: "slow")
                }
                ForEach(Array(flakiest.enumerated()), id: \.offset) { _, item in
                    toolStatRow(item, kind: "flaky")
                }
            }
        }
    }

    private func toolStatRow(_ item: [String: Any], kind: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: kind == "slow" ? "tortoise" : "exclamationmark.triangle")
                .font(.system(size: 9))
                .foregroundStyle(kind == "slow" ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            Text(item["tool"] as? String ?? "?")
                .font(.system(size: 11, design: .monospaced))
            Spacer(minLength: 4)
            Text(verbatim: kind == "slow"
                 ? msText((item["avgMs"] as? Double) ?? 0) + " avg"
                 : "\(item["failed"] as? Int ?? 0)/\(item["calls"] as? Int ?? 0)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.06)))
    }

    private var turnsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Turns")
            if turns.isEmpty {
                Text("No trace yet — this conversation has no turns.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                TurnTraceCard(turn: turn)
            }
        }
    }

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func statChip(_ title: LocalizedStringKey, _ value: String, tint: Color = .secondary) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.08)))
    }

    // MARK: - Data

    private var selectedConversationID: UUID? {
        selectedID ?? AgentScheduler.shared.deliveryTarget?.conversationId ?? conversationStore.conversations.first?.id
    }

    private var selectedTitle: String {
        conversationStore.conversations.first { $0.id == selectedConversationID }?.title ?? "—"
    }

    private func reload() {
        guard let id = selectedConversationID,
              let conversation = conversationStore.conversations.first(where: { $0.id == id }) else {
            turns = []
            stats = [:]
            return
        }
        let derived = AgentTrace.turns(of: conversation)
        turns = derived
        stats = AgentTrace.stats(of: derived)
    }

    private func value(_ key: String) -> Int { (stats[key] as? Int) ?? 0 }
    private func text(_ key: String) -> String { "\(value(key))" }
    private func double(_ key: String) -> Double { (stats[key] as? Double) ?? 0 }
    private func msText(_ ms: Double) -> String {
        guard ms > 0 else { return "—" }
        return ms >= 1000 ? String(format: "%.1fs", ms / 1000) : String(format: "%.0fms", ms)
    }
}

/// 一个回合：折叠状态只显示目标与摘要，展开后是完整的 Step 列表。
private struct TurnTraceCard: View {
    let turn: [String: Any]
    @State private var expanded = false

    private var steps: [[String: Any]] { (turn["steps"] as? [[String: Any]]) ?? [] }

    private var summary: String {
        let ms = steps.compactMap { ($0["ms"] as? Double) }.reduce(0, +)
        var parts = ["\(steps.count) steps"]
        if ms > 0 { parts.append(ms >= 1000 ? String(format: "%.1fs", ms / 1000) : String(format: "%.0fms", ms)) }
        if let vote = turn["feedback"] as? String { parts.append(vote == "up" ? "👍" : "👎") }
        if let note = turn["verificationNote"] as? String, !note.isEmpty { parts.append("⚠") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.hoverFast) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: "#\(turn["turn"] as? Int ?? 0)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(turn["goal"] as? String ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        stepRow(step)
                    }
                    if let answer = turn["answer"] as? String, !answer.isEmpty {
                        labelled("Answer", answer)
                    }
                    if let critique = turn["critique"] as? String, !critique.isEmpty {
                        labelled("Self-review", critique)
                    }
                    if let note = turn["verificationNote"] as? String, !note.isEmpty {
                        labelled("Unverified", note, tint: .orange)
                    }
                }
                .padding(.leading, 8)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.06)))
    }

    private func stepRow(_ step: [String: Any]) -> some View {
        let denied = step["denied"] as? Bool ?? false
        let errored = step["threwError"] as? Bool ?? false
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: denied ? "hand.raised" : (errored ? "exclamationmark.triangle" : "arrow.turn.down.right"))
                    .font(.system(size: 9))
                    .foregroundStyle(denied || errored ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                Text(step["action"] as? String ?? "?")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                if let ms = step["ms"] as? Double, ms > 0 {
                    Text(verbatim: ms >= 1000 ? String(format: "%.1fs", ms / 1000) : String(format: "%.0fms", ms))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            if let observation = step["result"] as? String, !observation.isEmpty {
                Text(observation)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
    }

    private func labelled(_ title: LocalizedStringKey, _ text: String, tint: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
    }
}

/// 简易流式布局：stat chip 一行放不下就换行（避免手算宽度）。
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
