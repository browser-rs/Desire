import SwiftUI

/// 聊天页（主页面根内容）：消息流 + 漂浮输入胶囊。
/// 照 IrsClawApp ChatView：ScrollViewReader + "bottom" 锚点 +
/// safeAreaInset 输入条 + 录音浮条。
struct ChatView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    @StateObject private var voice = VoiceInputService()

    var body: some View {
        ScrollViewReader { proxy in
            messageList(proxy: proxy)
        }
        .overlay(alignment: .bottom) {
            if voice.isRecording {
                recordingBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            floatingInputBar
                .padding(.bottom, 8)
        }
        .onChange(of: voice.transcribedText) { _, text in
            if voice.isRecording, !text.isEmpty { draft = text }
        }
        .navigationTitle(client.sessions.first { $0.id == client.selectedSessionID }?.label
            ?? (client.desktopName ?? "Desire"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 消息流

    private func messageList(proxy: ScrollViewProxy) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 8) {
                if client.queuedOffline {
                    queuedBanner
                }
                if client.connectionState.contains("重连") || client.connectionState.contains("断开") {
                    reconnectBanner
                }
                ForEach(client.messages) { message in
                    MessageBubble(message: message).id(message.id)
                }
                Color.clear.frame(height: 1).id("bottom")
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .scrollDismissesKeyboard(.interactively)
        .onTapGesture { inputFocused = false }
        .onChange(of: client.messages) { _, _ in
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var queuedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full")
            Text("已排队，Mac 上线后自动送达")
        }
        .font(.caption2)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var reconnectBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text("连接断开 · 自动重连中")
        }
        .font(.caption2)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 漂浮输入胶囊

    private var floatingInputBar: some View {
        HStack(spacing: 8) {
            micButton
            TextField("Message…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($inputFocused)
            sendButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
    }

    private var micButton: some View {
        Button {
            if voice.isRecording {
                voice.stop()
            } else {
                voice.start()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 38, height: 38)
                Image(systemName: voice.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(voice.isRecording ? .red : .secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!voice.isAvailable || client.busy)
    }

    private var sendButton: some View {
        let hasContent = !draft.trimmingCharacters(in: .whitespaces).isEmpty
        return Button {
            send()
        } label: {
            ZStack {
                Circle()
                    .fill(client.busy ? Color.red : (hasContent ? RootView.brand : Color(.secondarySystemBackground)))
                    .frame(width: 38, height: 38)
                Image(systemName: client.busy ? "stop.fill" : "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(client.busy ? .white : (hasContent ? .white : .secondary))
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hasContent)
    }

    // MARK: - 录音浮条

    private var recordingBar: some View {
        HStack(spacing: 8) {
            PulsingDot()
            Text("听写中")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.red.opacity(0.8))
            if !voice.transcribedText.isEmpty {
                Text(voice.transcribedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("完成") {
                voice.stop()
                if !voice.transcribedText.isEmpty { draft = voice.transcribedText }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.red.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        if client.busy {
            client.sendCancel()
            return
        }
        client.sendPrompt(text)
    }
}

struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.red.opacity(0.2))
                .frame(width: 14, height: 14)
                .scaleEffect(isPulsing ? 1.4 : 1.0)
            Circle()
                .fill(.red)
                .frame(width: 6, height: 6)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}
