import SwiftUI

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
                onShowHistory: { showHistory = true }
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
                onSubmit: submit,
                onCancelQuestion: {
                    store.awaitingQuestion = false
                    store.cancel()
                },
                isFocused: $isInputFocused
            )
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
                            isStreamingTail: isStreamingTail(msg),
                            streamingVersion: store.streamingVersion
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
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let text = inputText
        inputText = ""
        if store.awaitingQuestion {
            store.sendFollowUp(text)
        } else {
            store.sendMessage(text)
        }
    }
}

#Preview {
    let store = AISessionStore()
    store.preference.model = "gpt-4o"
    let conversationStore = ConversationStore()
    return AIPanel(store: store, conversationStore: conversationStore)
        .frame(width: 360, height: 560)
}