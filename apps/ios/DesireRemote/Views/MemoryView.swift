import SwiftUI

/// Agent 记忆（Agent Tab → Agent 记忆）：用户画像 / 长期事实 / 对话摘要。
/// 左滑删除单条（与桌面记忆页同一存放在 Mac 上）。
struct MemoryView: View {
    @EnvironmentObject var client: RemoteClient

    var body: some View {
        Group {
            if let memory = client.memory {
                if isEmpty(memory) {
                    ScrollView {
                        DesireEmptyState(
                            icon: "brain.head.profile",
                            title: "还没有记忆",
                            message: "Mac 上的 Agent 会在对话中逐步记住关于你的事实，长对话结束后还会生成摘要。")
                    }
                } else {
                    list(memory)
                }
            } else {
                ScrollView {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取 Mac 上的记忆…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
        }
        .background(DesireUI.pageFill.ignoresSafeArea())
        .navigationTitle("Agent 记忆")
        .navigationBarTitleDisplayMode(.inline)
        .task { client.requestMemory() }
    }

    private func isEmpty(_ memory: AgentMemory) -> Bool {
        !memory.profileNonEmpty && memory.facts.isEmpty && memory.summaries.isEmpty
    }

    private func list(_ memory: AgentMemory) -> some View {
        List {
            if memory.profileNonEmpty {
                Section {
                    VStack(spacing: 10) {
                        if !memory.profileName.isEmpty {
                            DesireValueRow(title: "称呼", value: memory.profileName)
                        }
                        if !memory.profileLanguage.isEmpty {
                            DesireValueRow(title: "语言", value: memory.profileLanguage)
                        }
                        if !memory.profileStyle.isEmpty {
                            DesireValueRow(title: "风格", value: memory.profileStyle)
                        }
                    }
                    if !memory.profileCustom.isEmpty {
                        Text(memory.profileCustom)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    DesireSectionHeader(title: "用户画像")
                }
            }

            Section {
                if memory.facts.isEmpty {
                    Text("还没有记住关于你的事实")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                ForEach(memory.facts) { fact in
                    factRow(fact)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                client.deleteMemory(rid: "fact:\(fact.id)")
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            } header: {
                DesireSectionHeader(
                    title: "长期事实 · \(memory.facts.count)",
                    subtitle: "Agent 跨对话记住的稳定信息")
            }

            Section {
                if memory.summaries.isEmpty {
                    Text("长对话结束后会自动生成摘要")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                ForEach(memory.summaries) { summary in
                    Text(summary.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                client.deleteMemory(rid: "summary:\(summary.id)")
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            } header: {
                DesireSectionHeader(
                    title: "对话摘要 · \(memory.summaries.count)",
                    subtitle: "每段对话结束后沉淀的要点")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { client.requestMemory() }
    }

    private func factRow(_ fact: MemoryFactInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: fact.pinned ? "pin.fill" : "text.quote")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(fact.pinned ? .orange : DesireUI.brand)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(fact.content)
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(fact.category)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesireUI.brand)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DesireUI.brand.opacity(0.12)))
                    if fact.scope != "global" {
                        Text("@\(fact.scope)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
