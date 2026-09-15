import SwiftUI

/// Bottom input area for the AI panel. A single rounded capsule that
/// auto-grows with content, with an inline send button and a context
/// strip above (question prompt / quick action shortcut).
struct AIInputBar: View {
    @Binding var text: String
    let isProcessing: Bool
    let awaitingQuestion: Bool
    let canSubmit: Bool
    var onSubmit: () -> Void
    var onCancelQuestion: () -> Void
    @FocusState.Binding var isFocused: Bool
    /// Voice input manager — nil hides the mic button.
    var voiceManager: VoiceInputManager? = nil

    @State private var isHoveringSend = false

    var body: some View {
        VStack(spacing: 6) {
            if awaitingQuestion {
                contextStrip
            }
            inputCapsule
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

            micButton
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

    @ViewBuilder
    private var micButton: some View {
        if let vm = voiceManager {
            Button {
                vm.toggle()
            } label: {
                ZStack {
                    if vm.isListening {
                        Circle()
                            .fill(Color.red.opacity(0.15))
                            .frame(width: 34, height: 34)
                            .scaleEffect(vm.isListening ? 1.15 : 0.9)
                            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: vm.isListening)
                    }
                    Image(systemName: vm.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(vm.isListening ? Color.red : Color.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(vm.isListening ? "Stop listening" : "Voice input")
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
