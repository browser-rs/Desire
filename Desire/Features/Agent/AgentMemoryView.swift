import SwiftUI

/// Memory manager: inspect and edit the agent's layered memory — the L0
/// profile, L1 learned facts (pin / edit / delete), and L2 conversation
/// summaries. Memory must be a glass box, not a black box.
struct AgentMemoryView: View {
    var onBack: () -> Void

    @ObservedObject private var memory = AgentMemoryStore.shared
    @State private var newFact = ""
    @State private var editingFactID: UUID?
    @State private var editingText = ""
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    profileSection
                    factsSection
                    summariesSection
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            HoverIcon(systemName: "chevron.left", action: onBack, help: "Back")
            Image(systemName: "brain.head.profile")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("记忆")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("\(memory.archive.facts.count) 条 · \(memory.archive.summaries.count) 份摘要")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
            Button {
                showClearConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("清空已学习的记忆（保留个人资料）")
            .disabled(memory.archive.facts.isEmpty && memory.archive.summaries.isEmpty)
            .confirmationDialog(
                "清空已学习的记忆？",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("清空全部事实与摘要", role: .destructive) {
                    memory.clearLearnedMemory()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("所有 L1 事实和 L2 会话摘要会被删除。个人资料（L0）保留。此操作不可撤销。")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }

    // MARK: - Profile (L0)

    private var profileSection: some View {
        sectionCard(title: "用户画像", icon: "person.crop.circle") {
            VStack(spacing: 8) {
                memoryField("称呼", text: memory.archive.profile.name) { newValue in
                    memory.updateProfile { $0.name = newValue }
                }
                memoryField("回复语言", text: memory.archive.profile.language) { newValue in
                    memory.updateProfile { $0.language = newValue }
                }
                memoryField("回复风格", text: memory.archive.profile.style) { newValue in
                    memory.updateProfile { $0.style = newValue }
                }
                memoryField("自定义指令", text: memory.archive.profile.customInstructions) { newValue in
                    memory.updateProfile { $0.customInstructions = newValue }
                }
            }
        }
    }

    private func memoryField(_ label: String, text: String, commit: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            TextField("未设置", text: Binding(
                get: { text },
                set: { commit($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
        )
    }

    // MARK: - Facts (L1)

    private var factsSection: some View {
        sectionCard(title: "长期记忆 · \(memory.archive.facts.count)", icon: "brain") {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    TextField("手动添加一条记忆…", text: $newFact)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit(addFact)
                    Button {
                        addFact()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
                )
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)

                if memory.archive.facts.isEmpty {
                    Text("还没有学到任何长期记忆。正常使用几轮后，Agent 会自动记录你的偏好和习惯。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(Array(memory.archive.facts.sorted { a, b in
                    if a.pinned != b.pinned { return a.pinned }
                    return a.updatedAt > b.updatedAt
                }.enumerated()), id: \.element.id) { index, fact in
                    factRow(fact)
                    if index < memory.archive.facts.count - 1 {
                        SettingsRowDivider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func factRow(_ fact: MemoryFact) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                memory.togglePin(fact.id)
            } label: {
                Image(systemName: fact.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 10))
                    .foregroundStyle(fact.pinned ? Color.orange : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(fact.pinned ? "Unpin" : "Pin (always injected)")

            if editingFactID == fact.id {
                TextField("内容", text: $editingText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { memory.updateFactContent(fact.id, content: editingText); editingFactID = nil }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.content)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                    Text("(\(fact.category))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            if editingFactID == fact.id {
                Button("保存") {
                    memory.updateFactContent(fact.id, content: editingText)
                    editingFactID = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
            } else {
                Button {
                    editingFactID = fact.id
                    editingText = fact.content
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button {
                memory.removeFact(fact.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func addFact() {
        let content = newFact.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }
        memory.addFact(content: content, category: "fact")
        newFact = ""
    }

    // MARK: - Summaries (L2)

    @ViewBuilder
    private var summariesSection: some View {
        let summaries = memory.archive.summaries.sorted { $0.createdAt > $1.createdAt }
        sectionCard(title: "会话摘要 · \(summaries.count)", icon: "doc.plaintext") {
            if summaries.isEmpty {
                Text("长对话结束后会自动生成摘要，用于跨会话回忆。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(summaries) { summary in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.summary)
                            .font(.system(size: 11.5))
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(dateText(summary.createdAt))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    Button {
                        memory.removeSummary(summary.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
        }
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Shared card

    private func sectionCard<Content: View>(
        title: String, icon: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            )
        }
    }
}
