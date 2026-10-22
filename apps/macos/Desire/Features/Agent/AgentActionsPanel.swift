import SwiftUI

/// Agent 操作审计面板（v0.8.1）：文件写入/编辑可撤销；工作流/下载等不可逆
/// 动作只记录并明确标记。
struct AgentActionsPanel: View {
    @ObservedObject private var store = AgentActionStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent Actions")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Every side effect the agent made. File writes and edits can be undone.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") { store.clear() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(store.records.isEmpty)
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            if store.records.isEmpty {
                Text("No actions yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.records) { record in
                            row(record)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 680, height: 540)
    }

    private func row(_ record: AgentActionRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(record.kind))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.summary)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(record.tool)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let host = record.host, !host.isEmpty {
                        Text(verbatim: "· \(host)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Text(record.createdAt, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if record.isUndone {
                Text("Undone")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if record.canUndo {
                Button("Undo") {
                    do {
                        note = try store.undo(record.id)
                    } catch {
                        note = error.localizedDescription
                    }
                }
                .controlSize(.small)
            } else {
                Text("Not reversible")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
    }

    private func icon(_ kind: AgentActionRecord.Kind) -> String {
        switch kind {
        case .fileWrite: "doc.badge.plus"
        case .fileEdit: "pencil.line"
        case .workflowRun: "wand.and.stars"
        case .download: "arrow.down.circle"
        case .approval: "checkmark.shield"
        case .other: "ellipsis.circle"
        }
    }
}
