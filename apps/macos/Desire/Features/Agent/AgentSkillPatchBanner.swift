import SwiftUI

/// **技能修正建议条**（v0.8.76 批 4 补）：用户纠正了上一轮按某技能执行的做法 →
/// 旁路起草的定点补丁落进收件箱时，聊天面板当场给一条可见提示。此前只有技能页
/// 的收件箱里有卡片，用户纠正完根本看不见。条上直接应用 / 忽略，不用跳页。
///
/// 数据齐备才渲染（补丁内容就在候选里），离屏快照拍得出来；应用走与技能页
/// 按钮同一个 Store 方法（重新校验 + 原文件定点覆盖 + 旧版备份）。
struct AgentSkillPatchBanner: View {
    let patches: [SkillCandidateCore.Candidate]
    /// 内容列限宽（与面板其余内容行同宽）；nil = 通栏。
    let contentMaxWidth: CGFloat?
    let onAdopt: (SkillCandidateCore.Candidate) -> Void
    let onDiscard: (SkillCandidateCore.Candidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(patches) { candidate in
                if let patch = candidate.patch {
                    card(candidate, patch: patch)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.10)))
        .contentColumnWidth(contentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private func card(_ candidate: SkillCandidateCore.Candidate,
                      patch: SkillCorrectionCore.Patch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(String(localized: "Skill correction proposed for \(candidate.name)"))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(String(localized: "Apply to Skill")) { onAdopt(candidate) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(String(localized: "Ignore")) { onDiscard(candidate) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Text(patch.reason)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            diffRow(label: String(localized: "Before"), text: patch.find)
            diffRow(label: String(localized: "After"), text: patch.replace)
        }
    }

    /// 改前/改后各至多两行（整段原文在技能页的补丁卡上看）。改后为空串 = 删掉这一段。
    private func diffRow(label: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Text(text.isEmpty ? String(localized: "(removed)") : text)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2)
        }
    }
}
