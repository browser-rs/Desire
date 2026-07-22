import AppKit
import SwiftUI

/// Renders a single message in the AI conversation, dispatching to a
/// role-specific bubble (user / assistant / tool).
struct AIMessageBubble: View {
    let message: AIMessage
    /// Whether this is the most recent assistant message that is still
    /// being streamed. Controls the trailing typing indicator.
    var isStreamingTail: Bool = false

    var body: some View {
        switch message.role {
        case .user:
            UserBubble(text: message.content ?? "")
        case .assistant:
            AssistantBubble(
                message: message,
                isStreamingTail: isStreamingTail
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

    /// Detect if content looks like a base64-encoded PNG (from screenshot tool).
    /// PNG files start with the signature bytes iVBORw0KGgo when base64-encoded.
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

            if let image = decodedImage {
                // Screenshot result: display the image with click-to-copy
                ScreenshotView(image: image)
            } else {
                // Regular tool result: display as text
                Text(content)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 40)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Screenshot view

private struct ScreenshotView: View {
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
                        .foregroundStyle(Color.accentColor)
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
