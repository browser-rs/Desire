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
            // 截图类结果：Mac 发来降采样预览（content 为 nil），直接渲染成图
            if message.imagePreview != nil || (message.imageKB ?? 0) > 0 {
                ScreenshotResultBubble(message: message)
            } else if isBoardResult(message) {
                BoardResultChip()
            } else
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



/// 截图工具结果（快照带降采样预览；旧 Mac 无预览 → 只报大小的 chip）。
struct ScreenshotResultBubble: View {
    let message: ChatMessage
    @State private var image: UIImage?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RemoteAvatar(icon: "camera.fill", colors: [.gray, .secondary])
            VStack(alignment: .leading, spacing: 5) {
                if let dataURI = message.imagePreview,
                   let comma = dataURI.firstIndex(of: ","),
                   let data = Data(base64Encoded: String(dataURI[dataURI.index(after: comma)...])),
                   let decoded = UIImage(data: data) {
                    Image(uiImage: decoded)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator).opacity(0.4)))
                        .onAppear { image = decoded }
                }
                Text(message.imagePreview != nil
                     ? "屏幕截图 · \(message.imageKB ?? 0) KB"
                     : "屏幕截图 · \(message.imageKB ?? 0) KB（预览需新版 Mac 端）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// whiteboard 工具结果收敛为轻提示——板内容在上方白板条里实时跟随。
func isBoardResult(_ message: ChatMessage) -> Bool {
    let c = message.content ?? ""
    return c.contains("Whiteboard") && (c.contains("updated") || c.contains("cleared") || c.contains("appended") || c.contains("inserted") || c.contains("edited") || c.contains("moved") || c.contains("deleted"))
}

struct BoardResultChip: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RemoteAvatar(icon: "rectangle.dashed", colors: [.blue, .indigo])
            HStack(spacing: 5) {
                Image(systemName: "rectangle.dashed")
                Text("白板已更新（见上方白板条）")
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemBackground))
            .clipShape(Capsule())
        }
    }
}
