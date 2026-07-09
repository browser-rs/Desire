import AppKit
import SwiftUI

/// Renders a single message in the AI conversation, dispatching to a
/// role-specific bubble (user / assistant / tool).
struct AIMessageBubble: View {
    let message: AIMessage
    /// Whether this is the most recent assistant message that is still
    /// being streamed. Controls the trailing typing indicator.
    var isStreamingTail: Bool = false
    var streamingVersion: Int = 0

    var body: some View {
        switch message.role {
        case .user:
            UserBubble(text: message.content ?? "")
        case .assistant:
            AssistantBubble(
                message: message,
                isStreamingTail: isStreamingTail,
                streamingVersion: streamingVersion
            )
        case .tool:
            ToolBubble(content: message.content ?? "")
        case .system:
            EmptyView()
        }
    }
}

// MARK: - User bubble

private struct UserBubble: View {
    let text: String
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
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
                                        Color.accentColor,
                                        Color.accentColor.opacity(0.85),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .shadow(color: Color.accentColor.opacity(0.18), radius: 4, y: 1)

                if isHovering {
                    CopyChip(text: text)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        .padding(.horizontal, 12)
        .onHover { isHovering = $0 }
        .animation(.hoverFast, value: isHovering)
    }
}

// MARK: - Assistant bubble

private struct AssistantBubble: View {
    let message: AIMessage
    let isStreamingTail: Bool
    let streamingVersion: Int
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
                if isError {
                    ErrorBlock(text: message.content ?? "")
                } else if let text = message.content, !text.isEmpty {
                    MarkdownRendererView(text: text)
                }

                if let tcs = message.toolCalls, !tcs.isEmpty {
                    ToolCallList(toolCalls: tcs)
                }

                if !hasVisibleContent {
                    AITypingIndicator()
                        .padding(.vertical, 4)
                } else if isStreamingTail {
                    // Trailing caret pulse while the stream is still open
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                            .opacity(0.85)
                        Text("streaming")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 2)
                }

                if isHovering, let text = message.content, !text.isEmpty, !isError {
                    CopyChip(text: text)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
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
                            Color.accentColor,
                            Color.accentColor.opacity(0.65),
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

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "wrench.adjustable")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)
            Text(content)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
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
