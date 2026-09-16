import SwiftUI
import UniformTypeIdentifiers

/// Composition root for the AI Assistant side panel. Renders the
/// header, message list / empty state, quick-action strip, and input
/// bar. The history view takes over the body when toggled.
///
/// This view always fills its container's available height — the host
/// (sidebar GeometryReader or floating NSPanel) controls the overall
/// height, and AIPanel fills that space.
struct AIPanel: View {
    @ObservedObject var store: AISessionStore
    @ObservedObject var conversationStore: ConversationStore

    @State private var inputText = ""
    @State private var showHistory = false
    @State private var showCapabilities = false
    /// Image attachments (JPEG data URIs) awaiting the next send.
    @State private var pendingImages: [String] = []
    @State private var isDroppingImage = false
    @StateObject private var voiceManager = VoiceInputManager()
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showHistory {
                AIHistoryListView(
                    conversationStore: conversationStore,
                    sessionStore: store,
                    onSelect: { id in
                        store.loadConversation(id)
                        showHistory = false
                    },
                    onBack: { showHistory = false }
                )
            } else if showCapabilities {
                AICapabilitiesView(onBack: { showCapabilities = false })
            } else {
                mainContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            AIHeaderView(
                store: store,
                hasHistory: !conversationStore.conversations.isEmpty,
                onShowHistory: { showHistory = true },
                onShowCapabilities: { showCapabilities = true },
                onNewChat: { store.clear() }
            )

            // "via Cloud / via On-device" indicator, shown only when the
            // router is active (lastProviderUsed is set by activeProvider).
            if let via = store.lastProviderUsed {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text("via \(via)")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 12)
                .padding(.top, 2)
            }

            // The page the agent will actually act on — always the real tool
            // target, so multi-window mismatches are visible at a glance.
            if let context = store.contextLabel {
                HStack(spacing: 4) {
                    Image(systemName: "scope")
                        .font(.system(size: 9))
                    Text(context)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.08))
            }

            if store.messages.isEmpty {
                AIEmptyStateView { action in
                    store.performQuickAction(action)
                }
            } else {
                messageScrollView
            }

            if !store.messages.isEmpty && !store.awaitingQuestion && !store.isProcessing {
                AIQuickActionBar(isProcessing: store.isProcessing) { action in
                    store.performQuickAction(action)
                }
            }

            if let approval = store.pendingApproval {
                ToolApprovalBar(
                    approval: approval,
                    onAllowOnce: { store.resolveApproval(.allowOnce) },
                    onAlwaysAllow: { store.resolveApproval(.alwaysAllow) },
                    onDeny: { store.resolveApproval(.deny) }
                )
            }

            AIInputBar(
                text: $inputText,
                isProcessing: store.isProcessing,
                awaitingQuestion: store.awaitingQuestion,
                canSubmit: canSubmit,
                attachments: pendingImages,
                onAddAttachment: pickImages,
                onRemoveAttachment: { idx in
                    guard pendingImages.indices.contains(idx) else { return }
                    pendingImages.remove(at: idx)
                },
                onSubmit: submit,
                onCancelQuestion: {
                    store.awaitingQuestion = false
                    store.cancel()
                },
                isFocused: $isInputFocused,
                voiceManager: voiceManager
            )
            .onChange(of: voiceManager.transcribedText) { _, newText in
                inputText = newText
            }
            .onChange(of: voiceManager.isRecording) { _, recording in
                // Voice recording stopped (silence detection) — auto-send.
                if !recording, !inputText.trimmingCharacters(in: .whitespaces).isEmpty {
                    let text = inputText
                    inputText = ""
                    store.sendMessage(text)
                }
            }
            .onDrop(of: ["public.image"], isTargeted: $isDroppingImage) { providers in
                Task { await dropImages(providers) }
                return true
            }
            .overlay {
                if isDroppingImage {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 22))
                                .foregroundStyle(Color.accentColor)
                        )
                        .allowsHitTesting(false)
                }
            }
        }
        .onKeyPress { press in
            if press.key == .return && press.modifiers.contains(.command) { submit(); return .handled }
            if press.key == .escape && store.isProcessing { store.cancel(); return .handled }
            return .ignored
        }
        .contextMenu {
            Button("Copy Conversation as Text") {
                let text = store.messages.map { msg in
                    let role = msg.role.rawValue.capitalized
                    let body = msg.content ?? msg.toolCalls?.map { "[\($0.function.name)]" }.joined(separator: " ") ?? ""
                    return "**\(role)**: \(body)"
                }.joined(separator: "\n\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    // MARK: - Message list

    private var messageScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.messages) { msg in
                        AIMessageBubble(
                            message: msg,
                            isStreamingTail: isStreamingTail(msg)
                        )
                        .id(msg.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("__bottom__")
                }
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: store.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: store.streamingVersion) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func isStreamingTail(_ msg: AIMessage) -> Bool {
        guard store.isProcessing, msg.role == .assistant else { return false }
        return store.messages.last?.id == msg.id
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("__bottom__", anchor: .bottom)
        }
    }

    // MARK: - Submit

    private var canSubmit: Bool {
        (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty)
            && !store.isProcessing
    }

    private func submit() {
        let text = inputText
        let images = pendingImages.isEmpty ? nil : pendingImages
        inputText = ""
        pendingImages = []
        if store.awaitingQuestion {
            store.sendFollowUp(text)
        } else {
            store.sendMessage(text, images: images)
        }
    }

    // MARK: - Image attachments

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Attach Images")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        let uris = panel.urls.compactMap { url -> String? in
            guard let image = NSImage(contentsOf: url) else { return nil }
            return ImageAttachment.dataURI(from: image)
        }
        pendingImages.append(contentsOf: uris)
    }

    private func dropImages(_ providers: [NSItemProvider]) async {
        let uris = await ImageAttachment.dataURIs(from: providers)
        guard !uris.isEmpty else { return }
        pendingImages.append(contentsOf: uris)
    }
}

#Preview {
    let preference = AIPreferenceStore()
    preference.model = "gpt-4o"
    let conversationStore = ConversationStore()
    let store = AISessionStore(preference: preference, conversationStore: conversationStore)
    return AIPanel(store: store, conversationStore: conversationStore)
        .frame(width: 360, height: 560)
}