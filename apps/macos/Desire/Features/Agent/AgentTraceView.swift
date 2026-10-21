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
    /// 单价表在这里查（成本 = token × 单价）；没填单价的模型只显示 token，不显示 $0。
    @ObservedObject var preference: AgentPreferenceStore
    var onBack: () -> Void

    @State private var selectedID: UUID?
    @State private var turns: [[String: Any]] = []
    @State private var stats: [String: Any] = [:]
    /// 复盘卡 → 输出规则草稿的编辑文本（nil = sheet 关着）。
    @State private var ruleDraftText: String?
    /// 工作流提炼草稿（nil = sheet 关着）。
    @State private var workflowDraft: WorkflowDraftPayload?

    private struct WorkflowDraftPayload: Identifiable {
        let id = UUID()
        let draft: WorkflowDistill.Draft
    }
    /// 评估集导出回执（"已导出 N 回合"）。
    @State private var evalExportNote: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    overviewSection
                    slowestSection
                    if let evalExportNote {
                Text(evalExportNote)
                    .font(.system(size: 11))
                    .foregroundStyle(appAccent)
                    .padding(.horizontal, 12)
            }
            turnsSection
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { reload() }
        .sheet(isPresented: Binding(
            get: { ruleDraftText != nil },
            set: { if !$0 { ruleDraftText = nil } })) {
            ruleDraftSheet
        }
        .sheet(item: $workflowDraft) { payload in
            WorkflowSaveSheet(draft: payload.draft)
        }
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
            Menu {
                Button(String(localized: "Export 👍 turns as eval set")) { exportEvalSet() }
                let existing = Array(EvalExporter.listExports().prefix(5))
                if !existing.isEmpty {
                    Divider()
                    ForEach(existing, id: \.url) { entry in
                        Menu(entry.url.lastPathComponent) {
                            Button(String(localized: "Reveal in Finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                            }
                            Button(String(localized: "Register as eval fixture")) {
                                if let result = try? EvalExporter.registerAsFixture(from: entry.url) {
                                    NSWorkspace.shared.activateFileViewerSelecting([result.url])
                                }
                            }
                            Button(String(localized: "Delete"), role: .destructive) {
                                EvalExporter.delete(entry.url)
                            }
                        }
                    }
                }
                let fixtures = Array(EvalExporter.listFixtures().prefix(5))
                if !fixtures.isEmpty {
                    Divider()
                    ForEach(fixtures, id: \.url) { entry in
                        Menu("fixture: \(entry.url.lastPathComponent) · \(entry.count)") {
                            Button(String(localized: "Reveal in Finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                            }
                            Button(String(localized: "Delete"), role: .destructive) {
                                EvalExporter.deleteFixture(entry.url)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "checklist")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Eval set")
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
                // 用量与成本：只在有数据时出现。金额带 "≥" 前缀表示有调用没填单价
                // （那笔算不进去），绝不把下界当总额。
                let tokens = value("promptTokens") + value("completionTokens")
                if tokens > 0 {
                    statChip("Tokens", AgentUsage.formatTokens(tokens))
                }
                if let cost = costText {
                    statChip("Cost", cost)
                }
            }
        }
    }

    /// 会话成本文案：每笔都已定价 → `$0.031`；有没定价的 → `≥ $0.031`。
    private var costText: String? {
        guard let value = stats["cost"] as? Double else { return nil }
        let text = AgentUsage.formatUSD(value)
        return stats["costIncomplete"] as? Bool == true ? "≥ " + text : text
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
                TurnTraceCard(turn: turn,
                              onDraftRules: { drafts in
                                  ruleDraftText = drafts.map(TurnReview.ruleText(for:)).joined(separator: "\n")
                              },
                              onSaveWorkflow: { draft in
                                  workflowDraft = WorkflowDraftPayload(draft: draft)
                              })
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

    /// 规则草稿 sheet：可编辑，逐行追加进"输出规则"（去重、空行忽略）。
    private var ruleDraftSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Write failure patterns into Output Rules…"))
                .font(.system(size: 13, weight: .semibold))
            Text("These rules go into <output_rules> of every future turn. Edit or delete lines before adding.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { ruleDraftText ?? "" },
                set: { ruleDraftText = $0 }))
                .font(.system(size: 12))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { ruleDraftText = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button(String(localized: "Add to Output Rules")) {
                    let lines = (ruleDraftText ?? "")
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    for line in lines where !preference.outputRules.contains(line) {
                        preference.outputRules.append(line)
                    }
                    ruleDraftText = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    /// 导出 👍 回合为评估集（默认 ~/Documents/DesireAgent）。
    private func exportEvalSet() {
        do {
            let result = try EvalExporter.export(conversationStore: conversationStore,
                                                 price: preference.usagePrice(for:))
            evalExportNote = String(format: String(localized: "Exported %lld 👍 turn(s) → %@"),
                                    result.count, result.url.lastPathComponent)
        } catch {
            evalExportNote = String(localized: "Export failed: ") + error.localizedDescription
        }
    }

    private func reload() {
        guard let id = selectedConversationID,
              let conversation = conversationStore.conversations.first(where: { $0.id == id }) else {
            turns = []
            stats = [:]
            return
        }
        let derived = AgentTrace.turns(of: conversation, price: preference.usagePrice(for:))
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
    @Environment(\.appAccent) private var appAccent: Color
    let turn: [String: Any]
    /// 复盘卡（v0.7.22）：把本回合的失败/慢模式写成输出规则草稿（宿主弹 sheet）。
    var onDraftRules: (([TurnReview.RuleDraft]) -> Void)? = nil
    /// 工作流提炼（v0.7.29）：把本回合的 navigate/click/fill 存成可回放草稿。
    var onSaveWorkflow: ((WorkflowDistill.Draft) -> Void)? = nil
    @State private var expanded = false

    private var steps: [[String: Any]] { (turn["steps"] as? [[String: Any]]) ?? [] }

    private var workflowDraft: WorkflowDistill.Draft? {
        WorkflowDistill.draft(fromTurn: turn)
    }

    private var summary: String {
        let ms = steps.compactMap { ($0["ms"] as? Double) }.reduce(0, +)
        var parts = ["\(steps.count) steps"]
        if ms > 0 { parts.append(ms >= 1000 ? String(format: "%.1fs", ms / 1000) : String(format: "%.0fms", ms)) }
        // 用量与成本：没填单价的回合只显示 token（`≥` 表示金额只是下界）。
        if let tokens = turn["tokens"] as? [String: Any], let total = tokens["total"] as? Int, total > 0 {
            parts.append(AgentUsage.formatTokens(total) + " tok")
            if let cost = turn["cost"] as? Double {
                let text = AgentUsage.formatUSD(cost)
                parts.append(turn["costIncomplete"] != nil ? "≥ " + text : text)
            }
        }
        if let vote = turn["feedback"] as? String { parts.append(vote == "up" ? "👍" : "👎") }
        let retries = TurnReview.retryCount(from: TurnReview.stepFacts(fromTurn: turn))
        if retries > 0 { parts.append(String(format: String(localized: "%lld retries"), retries)) }
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
                    timeDistributionView
                    costSplitView
                    if let answer = turn["answer"] as? String, !answer.isEmpty {
                        labelled("Answer", answer)
                    }
                    if let model = turn["model"] as? String, !model.isEmpty {
                        labelled("Model", model)
                    }
                    if let route = turn["route"] as? String, !route.isEmpty {
                        labelled("Route", route)
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
            let drafts = TurnReview.drafts(from: TurnReview.stepFacts(fromTurn: turn))
            if !drafts.isEmpty, let onDraftRules {
                Button(String(localized: "Write failure patterns into Output Rules…")) {
                    onDraftRules(drafts)
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if let draft = workflowDraft, let onSaveWorkflow {
                Button(String(localized: "Save as workflow…")) {
                    onSaveWorkflow(draft)
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.06)))
    }

    /// 耗时分布条（v0.7.27）：按工具聚合的比例条 + 前三名文字。
    @ViewBuilder
    private var timeDistributionView: some View {
        let slices = TurnReview.timeDistribution(from: TurnReview.stepFacts(fromTurn: turn))
        if !slices.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Time")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(Array(slices.enumerated()), id: \.offset) { index, slice in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(sliceColor(index))
                                .frame(width: max(2, geo.size.width * slice.share))
                        }
                    }
                }
                .frame(height: 6)
                Text(slices.prefix(3).map {
                    "\($0.tool) \(Int(($0.share * 100).rounded()))%"
                }.joined(separator: " · "))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            .padding(.top, 1)
        }
    }

    private func sliceColor(_ index: Int) -> Color {
        let colors: [Color] = [appAccent, .orange, .teal, .purple, .secondary]
        return colors[index % colors.count]
    }

    /// 成本拆分（v0.7.27）：主回合 / 子代理 / 旁路逐组（未定价的组不显示 $）。
    @ViewBuilder
    private var costSplitView: some View {
        if let groups = turn["costGroups"] as? [[String: Any]], !groups.isEmpty {
            let text = groups.map { group -> String in
                let category = group["category"] as? String ?? "?"
                let kind = group["kind"] as? String
                let label = kind.map { "\(category)/\($0)" } ?? category
                var part = "\(label) \(AgentUsage.formatTokens(group["tokens"] as? Int ?? 0))"
                if let usd = group["usd"] as? Double {
                    part += " " + AgentUsage.formatUSD(usd)
                }
                return part
            }.joined(separator: " · ")
            labelled("Cost split", text)
        }
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

/// 保存轨迹提炼的工作流（v0.7.29）：命名后写入本地工作流库。
private struct WorkflowSaveSheet: View {
    let draft: WorkflowDistill.Draft
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(draft: WorkflowDistill.Draft) {
        self.draft = draft
        _name = State(initialValue: draft.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as workflow")
                .font(.headline)
            Text("\(draft.host) · \(draft.steps.count) step(s)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func save() {
        var copy = draft
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        WorkflowStore.shared.merge([WorkflowDistill.workflow(from: copy)])
        dismiss()
    }
}
