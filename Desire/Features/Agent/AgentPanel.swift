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
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var crewStore = AgentCrewStore.shared
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

    /// 会话内容的统一宽度上限（消息、快捷按钮、输入框同一列，居中）。
    /// 面板可拖到 1200 宽，不给上限时满行文字很难扫读——但**所有内容行必须用同一个
    /// 值**，否则会出现"上面一列窄、下面输入框通栏"的错位感（用户实测反馈）。
    static let contentMaxWidth: CGFloat = 960

    /// Memo box for the per-render derived collections (tool result lookup
    /// + tool-call chip ids). Rebuilt only when the message count, the tail
    /// message id, or the tail's tool-call count changes — streaming text
    /// deltas mutate none of them, so the full-list scans are skipped on
    /// every token flush. Class box on purpose: mutating its fields inside
    /// `body` is not a @State write, so it can't trip SwiftUI's
    /// "modifying state during view update".
    private final class DerivedBox {
        var count = -1
        var tailID: UUID?
        var tailCalls = -1
        var results: [String: String] = [:]
        var chips: Set<String> = []
    }
    @State private var derived = DerivedBox()

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

            // Live progress of delegated subagents (spawnSubagent).
            if !store.runningSubagents.isEmpty {
                VStack(spacing: 4) {
                    ForEach(store.runningSubagents) { run in
                        HStack(spacing: 6) {
                            Image(systemName: "person.2")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(appAccent)
                            Text(run.label)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let tool = run.currentTool {
                                Text(tool)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(appAccent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(appAccent.opacity(0.12)))
                            }
                            Spacer(minLength: 0)
                            Text("\(run.step)/\(run.maxSteps)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.secondary.opacity(0.07))
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            }

            // Tab Crew 进度条（0.3.1）：作业组活跃/最近落定时显示子任务瓦片。
            if let crew = crewStore.crew {
                CrewProgressStrip(crew: crew, onCancelAll: { crewStore.cancelAll() })
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
                AgentQuickActionBar(
                    isProcessing: store.isProcessing,
                    onAction: { action in store.performQuickAction(action) },
                    // 与快捷动作同一行（此前是独立的一行，看着像两组无关按钮）。
                    onRegenerate: canRegenerate ? { store.regenerate() } : nil
                )
                .frame(maxWidth: Self.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }

            if let question = promptCenter.pending {
                AgentQuestionCard(question: question.question) { answer in
                    promptCenter.answer(answer)
                }
                .frame(maxWidth: Self.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }

            if let approval = store.pendingApproval {
                ToolApprovalBar(
                    approval: approval,
                    onAllowOnce: { store.resolveApproval(.allowOnce) },
                    onAlwaysAllow: { store.resolveApproval(.alwaysAllow) },
                    onDeny: { store.resolveApproval(.deny) }
                )
                .frame(maxWidth: Self.contentMaxWidth)
                .frame(maxWidth: .infinity)
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
                .frame(maxWidth: Self.contentMaxWidth)
                .frame(maxWidth: .infinity)
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
                voiceManager: voiceManager,
                modelMenu: AnyView(AgentModelMenu(store: store, preference: store.preference)),
                fullAccessPill: AnyView(AgentFullAccessPill(store: store))
            )
            .frame(maxWidth: Self.contentMaxWidth)
            .frame(maxWidth: .infinity)
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
                        .fill(appAccent.opacity(0.12))
                        .overlay(
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 22))
                                .foregroundStyle(appAccent)
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
                    let derivedData = refreshDerivedCache()
                    let toolResults = derivedData.results
                    let chipToolIds = derivedData.chips
                    ForEach(store.messages) { msg in
                        if msg.role == .tool,
                           let id = msg.toolCallId,
                           chipToolIds.contains(id) {
                            EmptyView()
                        } else {
                            AgentMessageBubble(
                                message: msg,
                                toolResults: toolResults,
                                isStreamingTail: isStreamingTail(msg)
                            )
                            .id(msg.id)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("__bottom__")
                }
                .padding(.vertical, 12)
                // 可读性上限：面板能拖很宽，满行的文字不好扫读。
                .frame(maxWidth: Self.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            // 锚点**固定为 .top**：内容增长本身绝不移动视口。
            //  - `.bottom`（最初写法）会在每次内容长高时把视口拽回底部——流式期间
            //    用户没法上滑看历史（实测反馈）。
            //  - 跟着 `isPinnedToBottom` 在两个锚点之间切（中间版本）会在流式时
            //    **反复切换**，每次切换都是一次跳动——用户看到的是"上下抖动得厉害"。
            // 跟随改成显式的 `scrollTo`（只在贴底时触发，见下方 onChange），
            // 初始位置由 onAppear 的那次滚动兜底。
            .defaultScrollAnchor(.top)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                // Mainstream pattern: jump back to the live tail after
                // scrolling up to read.
                if !isPinnedToBottom, !store.messages.isEmpty {
                    Button {
                        scrollToBottom(proxy, force: true)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 26, height: 26)
                            .background(
                                Circle().fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    }
                    .buttonStyle(.plain)
                    .help("Jump to latest")
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // "贴底"判定带**迟滞**：进入 60pt 内才算贴上、离开 160pt 才算脱离。
                // 单一阈值在流式（内容每 80ms 长一截）时会来回翻转，翻一次跳一次
                // ——实测就是"上下抖动"。迟滞把这种抖动挡在外面。
                let distance = geometry.contentSize.height
                    - (geometry.contentOffset.y + geometry.containerSize.height)
                if isPinnedToBottom {
                    return distance < 160
                }
                return distance < 60
            } action: { _, pinned in
                guard pinned != isPinnedToBottom else { return }
                withAnimation(.hoverFast) { isPinnedToBottom = pinned }
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
        // 弹性尺寸必须挂在 **ScrollViewReader**（VStack 的直接子视图）上：
        // 挂在里面的 ScrollView 上时，VStack 的剩余空间会漏给下面那条横向
        // ScrollView（快捷按钮行），把按钮行撑成一大块空白（实测）。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isStreamingTail(_ msg: AgentMessage) -> Bool {
        guard store.isProcessing, msg.role == .assistant else { return false }
        return store.messages.last?.id == msg.id
    }

    /// Memoized derived collections (see `DerivedBox`). Rebuilt only when
    /// the message count, tail id, or tail tool-call count changed.
    private func refreshDerivedCache() -> (results: [String: String], chips: Set<String>) {
        let tail = store.messages.last
        if derived.count != store.messages.count
            || derived.tailID != tail?.id
            || derived.tailCalls != (tail?.toolCalls?.count ?? -1) {
            derived.results = Dictionary(
                store.messages.compactMap { m in
                    m.toolCallId.map { ($0, m.content ?? "") }
                },
                uniquingKeysWith: { current, _ in current }
            )
            derived.chips = Set(store.messages.flatMap { m in
                m.role == .assistant ? (m.toolCalls?.map(\.id) ?? []) : []
            })
            derived.count = store.messages.count
            derived.tailID = tail?.id
            derived.tailCalls = tail?.toolCalls?.count ?? -1
        }
        return (derived.results, derived.chips)
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
/// Tab Crew 进度条（0.3.1）：每子任务一枚瓦片（状态色），点击对应标签；
/// 全部落定后可一键关闭条子。UI 占位最简 v1。
struct CrewProgressStrip: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let crew: AgentCrewStore.Crew
    let onCancelAll: () -> Void

    private func tint(_ state: AgentCrewStore.WorkerTask.State) -> Color {
        switch state {
        case .pending: .secondary.opacity(0.4)
        case .running: .accentColor
        case .done: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.3.sequence")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(crew.objective)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 4) {
                ForEach(crew.tasks) { t in
                    Circle()
                        .fill(tint(t.state))
                        .frame(width: 8, height: 8)
                        .help("[\(t.index)] \(t.state.rawValue): \(t.instruction)")
                }
            }
            Spacer(minLength: 8)
            if !crew.isSettled {
                Button("Cancel", action: onCancelAll)
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(appAccent.opacity(0.08))
        .animation(.overlaySpring, value: crew.tasks.map { $0.state.rawValue })
    }
}
