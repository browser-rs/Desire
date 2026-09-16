import SwiftUI
import UniformTypeIdentifiers

/// Composition root for the AI Assistant side panel. Renders the
/// header, message list / empty state, quick-action strip, and input
/// bar. The history view takes over the body when toggled.
///
/// This view always fills its container's available height — the host
/// (sidebar GeometryReader or floating NSPanel) controls the overall
/// height, and AgentPanel fills that space.
struct AgentPanel: View {
    @ObservedObject var store: AgentSessionStore
    @ObservedObject var conversationStore: ConversationStore

    @State private var inputText = ""
    @State private var showHistory = false
    @State private var showCapabilities = false
    @State private var showMemory = false
    @ObservedObject private var memory = AgentMemoryStore.shared
    /// Image attachments (JPEG data URIs) awaiting the next send.
    @State private var pendingImages: [String] = []
    @State private var isDroppingImage = false
    @ObservedObject private var planStore = AgentPlanStore.shared
    @ObservedObject private var recorder = WindowRecorder.shared
    @ObservedObject private var promptCenter = UserPromptCenter.shared
    /// True while the message list viewport sits at the bottom — gates the
    /// streaming auto-follow so reading older messages isn't interrupted.
    @State private var isPinnedToBottom = true
    @StateObject private var voiceManager = VoiceInputManager()
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !memory.onboardingCompleted {
                AgentOnboardingView()
            } else if showMemory {
                AgentMemoryView(onBack: { showMemory = false })
            } else if showHistory {
                AgentHistoryListView(
                    conversationStore: conversationStore,
                    sessionStore: store,
                    onSelect: { id in
                        store.loadConversation(id)
                        showHistory = false
                    },
                    onBack: { showHistory = false }
                )
            } else if showCapabilities {
                AgentCapabilitiesView(onBack: { showCapabilities = false })
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
            AgentHeaderView(
                store: store,
                hasHistory: !conversationStore.conversations.isEmpty,
                onShowHistory: { showHistory = true },
                onShowCapabilities: { showCapabilities = true },
                onShowMemory: { showMemory = true },
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
            // Recording indicator (started via the startRecording tool).
            if recorder.isRecording {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                    Text("REC")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .background(Color.red.opacity(0.08))
            }

            // Live task checklist from the updatePlan tool.
            if !planStore.steps.isEmpty {
                AgentPlanView(steps: planStore.steps)
            }

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
                AgentEmptyStateView { action in
                    store.performQuickAction(action)
                }
            } else {
                messageScrollView
            }

            if !store.messages.isEmpty && !store.awaitingQuestion && !store.isProcessing {
                AgentQuickActionBar(isProcessing: store.isProcessing) { action in
                    store.performQuickAction(action)
                }
            }

            if canRegenerate {
                HStack {
                    Button {
                        store.regenerate()
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Re-run the last message")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
            }

            if let question = promptCenter.pending {
                AgentQuestionCard(question: question.question) { answer in
                    promptCenter.answer(answer)
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

            // Input typed mid-turn, sent automatically when the running
            // turn finishes.
            if let first = store.queuedMessages.first {
                HStack(spacing: 6) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(first.text)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if store.queuedMessages.count > 1 {
                        Text("+\(store.queuedMessages.count - 1)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        store.clearQueuedMessages()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear queued messages")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(Color.secondary.opacity(0.10))
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
            }

            AgentInputBar(
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
                onCancel: { store.cancel() },
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
            Button("Export as Markdown…") {
                exportMarkdown()
            }
        }
    }

    // MARK: - Message list

    private var messageScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    let toolResults = Dictionary(
                        store.messages.compactMap { m in
                            m.toolCallId.map { ($0, m.content ?? "") }
                        },
                        uniquingKeysWith: { current, _ in current }
                    )
                    ForEach(store.messages) { msg in
                        AgentMessageBubble(
                            message: msg,
                            toolResults: toolResults,
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
            // Start (and reopen) at the latest message, not the top.
            .defaultScrollAnchor(.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // "Pinned" = the viewport bottom sits within 80pt of the
                // content bottom. While pinned, streaming output auto-
                // scrolls; scrolling up to read pauses the following.
                let distance = geometry.contentSize.height
                    - (geometry.contentOffset.y + geometry.containerSize.height)
                return distance < 80
            } action: { _, pinned in
                isPinnedToBottom = pinned
            }
            .onAppear {
                // An immediate scrollTo is a no-op before the first layout
                // pass — defer it one tick.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                }
            }
            .onChange(of: store.messages.count) { _, _ in
                // Force-follow when the USER sent something; otherwise only
                // while pinned (tool results streaming in shouldn't yank a
                // reader who scrolled up).
                let lastIsUser = store.messages.last?.role == .user
                scrollToBottom(proxy, force: lastIsUser)
            }
            .onChange(of: store.streamingVersion) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func isStreamingTail(_ msg: AgentMessage) -> Bool {
        guard store.isProcessing, msg.role == .assistant else { return false }
        return store.messages.last?.id == msg.id
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard force || isPinnedToBottom else { return }
        // Instant reposition: per-token animated scrolls fight the user and
        // can desync under LazyVStack.
        proxy.scrollTo("__bottom__", anchor: .bottom)
    }

    private func exportMarkdown() {
        let lines = store.messages.map { message -> String in
            switch message.role {
            case .user: return "## 🧑 User\n\n\(message.content ?? "")"
            case .assistant:
                let calls = (message.toolCalls ?? []).map { "`\($0.function.name)`" }.joined(separator: ", ")
                var body = "## 🤖 Agent\n\n"
                if !calls.isEmpty { body += "_tools: \(calls)_\n\n" }
                if let content = message.content, !content.isEmpty { body += content }
                return body
            case .tool:
                return "> tool result: \((message.content ?? "").prefix(600))"
            case .system:
                return ""
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n---\n\n")

        let panel = NSSavePanel()
        panel.title = "Export Conversation"
        panel.nameFieldStringValue = "\(store.conversationTitle ?? "conversation").md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? lines.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Submit

    private var canSubmit: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty
    }

    /// A finished assistant turn is on top — offer a re-run.
    private var canRegenerate: Bool {
        !store.isProcessing && !store.awaitingQuestion && store.messages.last?.role == .assistant
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
    let preference = AgentPreferenceStore()
    preference.model = "gpt-4o"
    let conversationStore = ConversationStore()
    let store = AgentSessionStore(preference: preference, conversationStore: conversationStore)
    return AgentPanel(store: store, conversationStore: conversationStore)
        .frame(width: 360, height: 560)
}