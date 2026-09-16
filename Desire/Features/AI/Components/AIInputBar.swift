import SwiftUI

/// Bottom input area for the AI panel. A single rounded capsule that
/// auto-grows with content, with an inline send button and a context
/// strip above (question prompt / quick action shortcut).
struct AIInputBar: View {
    @Binding var text: String
    let isProcessing: Bool
    let awaitingQuestion: Bool
    let canSubmit: Bool
    /// User-attached image data URIs awaiting send (vision input).
    var attachments: [String] = []
    var onAddAttachment: () -> Void = {}
    var onRemoveAttachment: (Int) -> Void = { _ in }
    var onSubmit: () -> Void
    var onCancelQuestion: () -> Void
    @FocusState.Binding var isFocused: Bool
    /// Voice input manager — nil hides the mic button.
    var voiceManager: VoiceInputManager? = nil
    /// Error message from voice input, shown below the bar.
    var voiceError: String? = nil

    @State private var isHoveringSend = false

    var body: some View {
        VStack(spacing: 6) {
            if awaitingQuestion {
                contextStrip
            }
            if !attachments.isEmpty {
                attachmentStrip
            }
            inputCapsule
            voiceStatusLine
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(inputBackground)
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
    }

    // MARK: - Context strip

    private var contextStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis.bubble.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Text("Asking about this page")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Cancel", action: onCancelQuestion)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Color.accentColor.opacity(0.10))
        )
        .overlay(
            Capsule().stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5)
        )
    }

    // MARK: - Attachments

    /// Thumbnails of pending image attachments with remove buttons.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments.indices, id: \.self) { idx in
                    attachmentThumb(uri: attachments[idx], index: idx)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func attachmentThumb(uri: String, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if let data = imageData(uri), let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    )
            }
            Button {
                onRemoveAttachment(index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white, .black.opacity(0.65))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("Remove")
        }
        .padding(.trailing, 5)
    }

    private func imageData(_ uri: String) -> Data? {
        guard uri.hasPrefix("data:image/"),
              let comma = uri.firstIndex(of: ","),
              let base64 = uri[uri.index(after: comma)...].removingPercentEncoding else { return nil }
        return Data(base64Encoded: String(base64))
    }

    // MARK: - Input capsule

    private var inputCapsule: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, 9)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(minHeight: 32, maxHeight: 120)
                    .onSubmit(onSubmit)
            }

            attachButton
                .padding(.leading, 6)
                .padding(.trailing, 6)
                .padding(.bottom, 6)
            micButton
                .padding(.trailing, 6)
                .padding(.bottom, 6)
            sendButton
                .padding(.trailing, 6)
                .padding(.bottom, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(borderColor, lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }

    /// Shows listening indicator or voice input errors.
    @ViewBuilder
    private var voiceStatusLine: some View {
        if let vm = voiceManager {
            if let err = vm.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text(err)
                        .font(.system(size: 11))
                        .lineLimit(2)
                }
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 2)
            } else if vm.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                    Text("正在聆听… 说话即可")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)
            }
        }
    }

    /// Opens the image picker (panel handled by the parent).
    private var attachButton: some View {
        Button(action: onAddAttachment) {
            Image(systemName: "paperclip")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .help("Attach image ( vision models)")
    }

    @ViewBuilder
    private var micButton: some View {
        if let vm = voiceManager {
            Button {
                vm.toggle()
            } label: {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: vm.isRecording ? "mic.fill" : "mic")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(vm.isRecording ? Color.red : Color.secondary)
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.8)
                    )
            }
            .buttonStyle(.plain)
            .help(vm.isRecording ? "Stop listening" : "Voice input")
        }
    }

    private var sendButton: some View {
        Button {
            if isProcessing { return }
            onSubmit()
        } label: {
            ZStack {
                Circle()
                    .fill(sendFill)
                    .frame(width: 28, height: 28)
                Image(systemName: isProcessing ? "stop.fill" : "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(sendForeground)
            }
        }
        .buttonStyle(.plain)
        .disabled(isProcessing || !canSubmit)
        .help(isProcessing ? "Stop" : "Send (⏎)")
        .onHover { isHoveringSend = $0 }
        .animation(.hoverFast, value: isHoveringSend)
    }

    // MARK: - Background

    private var inputBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color(nsColor: .controlBackgroundColor).opacity(0.0),
                    Color(nsColor: .controlBackgroundColor).opacity(0.5),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Computed

    private var placeholder: String {
        awaitingQuestion ? "Ask about this page…" : "Ask AI…"
    }

    private var borderColor: Color {
        isFocused
            ? Color.accentColor.opacity(0.55)
            : Color(nsColor: .separatorColor).opacity(0.6)
    }

    private var sendFill: Color {
        if isProcessing { return Color.red.opacity(0.85) }
        if !canSubmit { return Color(nsColor: .controlBackgroundColor) }
        if isHoveringSend { return Color.accentColor.opacity(0.85) }
        return Color.accentColor
    }

    private var sendForeground: Color {
        if isProcessing { return .white }
        if !canSubmit { return Color.secondary.opacity(0.4) }
        return .white
    }
}
