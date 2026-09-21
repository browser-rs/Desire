import AppKit
import SwiftUI

/// Renders a single message in the AI conversation, dispatching to a
/// role-specific bubble (user / assistant / tool).
struct AgentMessageBubble: View {
    let message: AgentMessage
    /// toolCallId -> result content, for showing what a call returned.
    var toolResults: [String: String] = [:]
    /// Whether this is the most recent assistant message that is still
    /// being streamed. Controls the trailing typing indicator.
    var isStreamingTail: Bool = false

    var body: some View {
        switch message.role {
        case .user:
            UserBubble(
                text: message.content ?? "",
                imageDataURIs: message.imageDataURIs ?? []
            )
        case .assistant:
            AssistantBubble(
                message: message,
                isStreamingTail: isStreamingTail,
                toolResults: toolResults
            )
        case .tool:
            ToolBubble(content: message.content ?? "", toolName: message.toolName)
        case .system:
            EmptyView()
        }
    }
}

// MARK: - User bubble

private struct UserBubble: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let text: String
    var imageDataURIs: [String] = []
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                if !imageDataURIs.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(imageDataURIs, id: \.self) { uri in
                            attachmentPreview(uri)
                        }
                    }
                }
                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            appAccent,
                                            appAccent.opacity(0.85),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .shadow(color: appAccent.opacity(0.18), radius: 4, y: 1)
                }

            }
        }
        .overlay(alignment: .topTrailing) {
            // Hover affordance must NOT participate in layout — a
            // conditionally inserted chip reflows the bubble (jitter).
            if isHovering {
                CopyChip(text: text)
                    .offset(x: 6, y: -6)
            }
        }
        .padding(.horizontal, 12)
        .onHover { isHovering = $0 }
        .animation(.hoverFast, value: isHovering)
    }

    /// Decodes a data URI back to a thumbnail. Old conversations persist
    /// without image data, so a missing payload renders nothing.
    @ViewBuilder
    private func attachmentPreview(_ uri: String) -> some View {
        if let comma = uri.firstIndex(of: ","),
           let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])),
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 96, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                )
        }
    }
}

// MARK: - Assistant bubble

private struct AssistantBubble: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let message: AgentMessage
    let isStreamingTail: Bool
    var toolResults: [String: String] = [:]
    @State private var isHovering = false

    private var isError: Bool {
        message.content?.hasPrefix("Error:") == true
    }

    private var hasVisibleContent: Bool {
        if let t = message.content, !t.isEmpty { return true }
        if let tcs = message.toolCalls, !tcs.isEmpty { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            roleAvatar
            VStack(alignment: .leading, spacing: 6) {
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    ReasoningBlock(
                        text: reasoning,
                        // 只在"还在思考、正文尚未开始"时自动展开；正文一来就自动收起
                        // （用户手动点过之后不再自动切换）。
                        isLive: isStreamingTail && (message.content?.isEmpty ?? true)
                    )
                }
                if isError {
                    ErrorBlock(text: message.content ?? "")
                } else if let text = message.content, !text.isEmpty {
                    // 流式中的那条把 isLive 传下去：超长回答会退化成纯文本渲染，
                    // 避免每次刷新重建上千个子视图把主线程卡住（见渲染器注释）。
                    MarkdownRendererView(text: text, isLive: isStreamingTail)
                }

                if let tcs = message.toolCalls, !tcs.isEmpty {
                    ToolCallList(toolCalls: tcs, results: toolResults)
                }

                if !hasVisibleContent {
                    AgentTypingIndicator()
                        .padding(.vertical, 4)
                } else if isStreamingTail {
                    // Trailing caret pulse while the stream is still open
                    HStack(spacing: 4) {
                        Circle()
                            .fill(appAccent)
                            .frame(width: 5, height: 5)
                            .opacity(0.85)
                        Text("streaming")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 2)
                }

            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(bubbleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(borderColor, lineWidth: 0.5)
            )
            .overlay(alignment: .topTrailing) {
                if isHovering, let text = message.content, !text.isEmpty, !isError {
                    CopyChip(text: text)
                        .offset(x: 6, y: -6)
                }
            }
            .textSelection(.enabled)

            Spacer(minLength: 40)
        }
        .padding(.horizontal, 12)
        .onHover { isHovering = $0 }
        .animation(.hoverFast, value: isHovering)
    }

    private var roleAvatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            appAccent,
                            appAccent.opacity(0.65),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 22, height: 22)
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.top, 2)
    }

    private var bubbleFill: Color {
        if isError {
            return Color.red.opacity(0.08)
        }
        return Color(nsColor: .controlBackgroundColor).opacity(0.6)
    }

    private var borderColor: Color {
        if isError {
            return Color.red.opacity(0.3)
        }
        return Color(nsColor: .separatorColor).opacity(0.3)
    }
}

// MARK: - Tool bubble

private struct ToolBubble: View {
    let content: String
    let toolName: String?

    private var isBase64Image: Bool {
        content.count > 100 && content.hasPrefix("iVBORw0KGgo")
    }

    private var decodedImage: NSImage? {
        guard isBase64Image,
              let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { return nil }
        return NSImage(data: data)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "wrench.adjustable")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                if let name = toolName {
                    Text(name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if let image = decodedImage {
                    ScreenshotView(image: image)
                } else {
                    Text(content)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Screenshot view

private struct ScreenshotView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let image: NSImage
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 280)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                )

            if isHovering {
                HStack(spacing: 8) {
                    Label("Screenshot", systemImage: "photo")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    Button {
                        copyImageToPasteboard()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9))
                            Text("Copy")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(appAccent)
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onHover { isHovering = $0 }
        .animation(.hoverFast, value: isHovering)
    }

    private func copyImageToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }
}

// MARK: - Error block

private struct ErrorBlock: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Copy chip

private struct CopyChip: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9))
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(copied ? Color.green : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
            )
            .overlay(
                Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Copy message")
    }
}

// MARK: - Reasoning block

/// 推理模型的思考过程：默认折叠、点标题展开；流式思考时自动展开，正文一开始
/// 就自动收起（用户手动点过之后不再自动切换）。
private struct ReasoningBlock: View {
    @Environment(\.appAccent) private var appAccent: Color
    let text: String
    let isLive: Bool

    @State private var expanded = false
    @State private var userToggled = false

    private var reasoningText: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.07))
            )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                userToggled = true
                withAnimation(.hoverFast) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 10))
                        .foregroundStyle(isLive ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
                    Text(isLive ? String(localized: "Thinking…") : String(localized: "Thinking"))
                        .font(.system(size: 11, weight: .medium))
                    Text("\(text.count)")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Show the model's thinking"))

            if expanded {
                if isLive {
                    // 流式思考时**固定高度 + 内部滚动**：否则每来一段文字都会推着
                    // 整条会话重新排版，叠上自动跟随就是用户看到的"上下抖动得厉害"。
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            reasoningText
                                .id("reasoning-tail")
                        }
                        .frame(height: 150)
                        .onChange(of: text) { _, _ in
                            proxy.scrollTo("reasoning-tail", anchor: .bottom)
                        }
                    }
                } else {
                    reasoningText
                }
            }
        }
        .onAppear {
            if isLive, !userToggled { expanded = true }
        }
        .onChange(of: isLive) { _, live in
            guard !userToggled else { return }
            withAnimation(.hoverFast) { expanded = live }
        }
    }
}
