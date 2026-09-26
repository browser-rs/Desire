import SwiftUI

/// 记忆页（Menu 磁贴「记忆」push）：画像 / 事实 / 摘要，左滑删除。
struct MemoryView: View {
    @EnvironmentObject var client: RemoteClient

    var body: some View {
        Group {
            if let memory = client.memory {
                memoryList(memory)
            } else {
                ProgressView("正在读取记忆…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .refreshable { client.requestMemory() }
        .onAppear { client.requestMemory() }
    }

    private func memoryList(_ memory: AgentMemory) -> some View {
        List {
            if memory.profileNonEmpty {
                Section("用户画像") {
                    if !memory.profileName.isEmpty { LabeledContent("称呼", value: memory.profileName) }
                    if !memory.profileLanguage.isEmpty { LabeledContent("语言", value: memory.profileLanguage) }
                    if !memory.profileStyle.isEmpty { LabeledContent("风格", value: memory.profileStyle) }
                    if !memory.profileCustom.isEmpty {
                        Text(memory.profileCustom).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section("事实 · \(memory.facts.count)") {
                if memory.facts.isEmpty {
                    Text("还没有记住关于你的事实").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(memory.facts) { fact in
                    HStack(alignment: .top, spacing: 8) {
                        if fact.pinned {
                            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fact.content).font(.subheadline)
                            HStack(spacing: 6) {
                                Text(fact.category).font(.caption2).foregroundStyle(.tint)
                                if fact.scope != "global" {
                                    Text("@\(fact.scope)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            client.deleteMemory(rid: "fact:\(fact.id)")
                        } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
            Section("对话摘要 · \(memory.summaries.count)") {
                if memory.summaries.isEmpty {
                    Text("长对话结束后会自动生成摘要").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(memory.summaries) { summary in
                    Text(summary.summary)
                        .font(.footnote).foregroundStyle(.secondary)
                        .lineLimit(3)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                client.deleteMemory(rid: "summary:\(summary.id)")
                            } label: { Label("删除", systemImage: "trash") }
                        }
                }
            }
        }
    }
}
