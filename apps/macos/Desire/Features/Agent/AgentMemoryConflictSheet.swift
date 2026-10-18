import SwiftUI

/// 记忆冲突复核向导（v0.7.22）：新增记忆与既有事实"可能相关"时不再静默
/// 并存——列出相关内容让用户裁一次。**口径 = 近似判定**（类别/作用域同桶
/// 且显著词重叠高），不是语义理解；文案照此写（"可能相关/建议复核"）。
///
/// 两个模态：手动添加（新文本尚未入库）/ 复核队列（事实已自动入库，来自
/// `AgentMemoryStore.pendingConflicts`）。四种决议：保留新的 / 保留旧的 /
/// 两条都保留 / 合并成一条（可手编合并文本）。
struct AgentMemoryConflictSheet: View {
    enum Mode {
        case manual(newText: String, category: String, scope: String)
        case review(AgentMemoryStore.PendingConflict)
    }

    @ObservedObject var memory: AgentMemoryStore
    let mode: Mode
    let onResolved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent: Color

    @State private var resolution: AgentMemoryStore.ConflictResolution = .keepNew
    @State private var mergeText = ""

    private var newText: String {
        switch mode {
        case .manual(let text, _, _): return text
        case .review(let pending):
            return memory.factsSnapshot.first { $0.id == pending.factID }?.content ?? ""
        }
    }

    private var relatedFacts: [MemoryFact] {
        let ids: [UUID]
        switch mode {
        case .manual(_, let category, let scope):
            ids = memory.conflictCandidates(for: currentManualText, category: category, scope: scope)
                .map(\.factID)
        case .review(let pending):
            ids = pending.relatedIDs
        }
        return ids.compactMap { id in memory.factsSnapshot.first { $0.id == id } }
    }

    /// 手动态的新文本（mode 关联值在 body 里取不到，用一次缓存的访问器）。
    private var currentManualText: String {
        if case .manual(let text, _, _) = mode { return text }
        return newText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(appAccent)
                Text(String(localized: "Related Memory — Review"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Text("The new memory below looks related to existing ones (approximate match — same subject bucket with high word overlap). Keep what you want; nothing is deleted silently.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "New memory"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(currentManualText)
                    .font(.system(size: 12))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(appAccent.opacity(0.08)))
            }

            if !relatedFacts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Related existing memories"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(relatedFacts) { fact in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(fact.content)
                                        .font(.system(size: 12))
                                        .lineLimit(3)
                                    Spacer()
                                    if fact.pinned {
                                        Image(systemName: "pin.fill")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.secondary.opacity(0.08)))
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }

            Picker(String(localized: "Resolution"), selection: $resolution) {
                Text("Keep the New One").tag(AgentMemoryStore.ConflictResolution.keepNew)
                Text("Keep the Old One(s)").tag(AgentMemoryStore.ConflictResolution.keepOld)
                Text("Keep Both").tag(AgentMemoryStore.ConflictResolution.keepBoth)
                Text("Merge into One").tag(AgentMemoryStore.ConflictResolution.merge)
            }
            .pickerStyle(.radioGroup)
            .onAppear {
                if mergeText.isEmpty {
                    mergeText = MemoryConflict.defaultMergedText(
                        new: currentManualText,
                        related: relatedFacts.map(\.content))
                }
            }

            if resolution == .merge {
                TextEditor(text: $mergeText)
                    .font(.system(size: 12))
                    .frame(height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }

            HStack {
                Spacer()
                Button(String(localized: "Apply")) { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(resolution == .merge
                              && mergeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func apply() {
        switch mode {
        case .manual(let text, let category, let scope):
            memory.resolveConflict(newText: text, category: category, scope: scope,
                                   resolution: resolution,
                                   relatedIDs: relatedFacts.map(\.id),
                                   mergedText: resolution == .merge ? mergeText : nil)
        case .review(let pending):
            memory.resolveReview(factID: pending.factID,
                                 relatedIDs: relatedFacts.map(\.id),
                                 resolution: resolution,
                                 mergedText: resolution == .merge ? mergeText : nil)
        }
        onResolved()
        dismiss()
    }
}
