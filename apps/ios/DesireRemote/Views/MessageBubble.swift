import MarkdownUI
import SwiftUI
import VisionKit

private struct RemoteAvatar: View {
    let icon: String
    let colors: [Color]

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 28, height: 28)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @State private var reasoningExpanded = false
    @State private var toolExpanded = false
    @State private var callArgsExpanded = false

    var body: some View {
        switch message.role {
        case "user":
            if (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyView()
            } else {
            HStack(alignment: .top, spacing: 8) {
                Spacer(minLength: 40)
                Text(message.content ?? "")
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(RootView.brand)
                    )
                    .foregroundStyle(.white)
                RemoteAvatar(icon: "person.fill", colors: [.blue, .cyan])
            }
            }
        case "tool":
            // 快照里 tool 消息只有结果 content（调用名在 assistant 帧上），
            // 结果常驻显示、默认 4 行折叠，点标签或卡片展开全文
            if (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyView()
            } else {
            HStack(alignment: .top, spacing: 8) {
                RemoteAvatar(icon: "wrench.and.screwdriver.fill", colors: [.gray, .secondary])
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { toolExpanded.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "wrench.and.screwdriver")
                            Text("工具结果")
                            Image(systemName: toolExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    if let content = message.content,
                       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(content)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Color.primary.opacity(0.78))
                            .lineLimit(toolExpanded ? nil : 4)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.tertiarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) { toolExpanded.toggle() }
                            }
                    }
                }
                Spacer(minLength: 20)
            }
            }
        default:
            HStack(alignment: .top, spacing: 8) {
                RemoteAvatar(icon: "sparkles", colors: [.purple, .pink])
                VStack(alignment: .leading, spacing: 6) {
                    if let reasoning = message.reasoning, !reasoning.isEmpty {
                        DisclosureGroup(isExpanded: $reasoningExpanded) {
                            Text(reasoning)
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.top, 2)
                        } label: {
                            Label("思考过程", systemImage: "brain")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color(.tertiarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    if let calls = message.toolCalls, !calls.isEmpty {
                        ToolCallRow(calls: calls, args: message.toolArgs)
                    }
                    if let content = message.content,
                       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        MarkdownTextView(text: content)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(.tertiarySystemBackground))
                            )
                    }
                }
                Spacer(minLength: 20)
            }
        }
    }
}


// MARK: - 工具调用行（assistant 帧：调用名；点击展开参数摘要）

struct ToolCallRow: View {
    let calls: [String]
    let args: [String]?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text(calls.joined(separator: " · "))
                        .lineLimit(1)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded, let args, !args.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(args.enumerated()), id: \.offset) { index, arg in
                        Text("\(calls.indices.contains(index) ? calls[index] : "?")(\(arg))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

