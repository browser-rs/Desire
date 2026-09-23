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
    /// 每个对话的输入草稿：切走再切回不丢正在打的字（放在内存里，会话级）。
    @State private var drafts: [UUID: String] = [:]
    @State private var showTrace = false
    @State private var showStats = false
    /// 输入历史翻阅位置（nil = 不在翻阅）。历史本身在 store 里、按对话保存。
    @State private var historyIndex: Int?
    /// 上一次的文本变化来自历史回填（据此区分"用户手打" → 退出翻阅）。
    @State private var recalledFromHistory = false
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
    /// 用户此刻是否在**自己滚动**（拖拽/惯性）。贴底状态只在它为真时才由几何变化
    /// 改写：内容增长同样会触发 `onScrollGeometryChange`，把它当成"用户上滑了"
    /// 会在输出到一半时停掉跟随（见下面两处的注释）。
    @State private var isUserScrolling = false
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
        /// toolCallId → 耗时（毫秒），工具卡片上直接显示。
        var durations: [String: Double] = [:]
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
            } else if showStats {
                AgentStatsView(conversationStore: conversationStore, preference: store.preference,
                               onBack: { showStats = false })
            } else if showTrace {
                AgentTraceView(conversationStore: conversationStore, preference: store.preference,
                               onBack: { showTrace = false })
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
                preference: store.preference,
                hasHistory: !conversationStore.conversations.isEmpty,
                onShowHistory: { showHistory = true },
                onShowCapabilities: { showCapabilities = true },
                onShowTrace: { showTrace = true },
                onShowStats: { showStats = true },
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
            if !store.queuedMessages.isEmpty {
                // 排队中的消息**逐条列出**（此前只显示第一条 +N，想退掉第二条只能全清）。
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text("\(store.queuedMessages.count) queued")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button {
                            store.clearQueuedMessages()
                        } label: {
                            Text("Clear all")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear queued messages")
                    }
                    ForEach(store.queuedMessages.prefix(4)) { item in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text(item.text)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            Button {
                                store.removeQueued(id: item.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove from queue")
                        }
                    }
                    if store.queuedMessages.count > 4 {
                        Text("+\(store.queuedMessages.count - 4) more")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
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
                onHistoryUp: {
                    let history = store.inputHistory
                    guard !history.isEmpty else { return nil }
                    let next = historyIndex.map { max(0, $0 - 1) } ?? (history.count - 1)
                    historyIndex = next
                    recalledFromHistory = true
                    return history[next]
                },
                onHistoryDown: {
                    guard let index = historyIndex else { return nil }
                    guard index + 1 < store.inputHistory.count else {
                        historyIndex = nil
                        recalledFromHistory = true
                        return ""          // 翻过最新一条 → 回到空白草稿
                    }
                    historyIndex = index + 1
                    recalledFromHistory = true
                    return store.inputHistory[index + 1]
                },
                isBrowsingHistory: historyIndex != nil,
                voiceManager: voiceManager,
                modelMenu: AnyView(AgentModelMenu(store: store, preference: store.preference)),
                fullAccessPill: AnyView(AgentFullAccessPill(store: store))
            )
            .frame(maxWidth: Self.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .onChange(of: inputText) { _, _ in
                // 历史回填的那次变化不算"手打"；其余任何输入都退出翻阅状态。
                if recalledFromHistory {
                    recalledFromHistory = false
                } else {
                    historyIndex = nil
                }
            }
            .onChange(of: store.conversationId) { old, new in
                historyIndex = nil      // 换了对话：历史也跟着换
                // 草稿按对话存取：切走时存下、切回时取回（以前切一次就丢）。
                if let old { drafts[old] = inputText }
                inputText = new.flatMap { drafts[$0] } ?? ""
            }
            .onChange(of: voiceManager.transcribedText) { _, newText in
                inputText = newText
            }
            .onChange(of: voiceManager.isRecording) { _, recording in
                // Voice recording stopped (silence detection) — auto-send.
                if !recording, !inputText.trimmingCharacters(in: .whitespaces).isEmpty {
                    let text = inputText
                    inputText = ""
                    // 同一个坑：onChange 回调可能在 SwiftUI 更新事务里执行，直接发
                    // 会让 store 在更新中发布（见 AgentInputBar 回车那段的注释）。
                    Task { @MainActor in store.sendMessage(text) }
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
            // `.onKeyPress` 的处理器在 SwiftUI 更新事务里跑：凡是会写 `@Published`
            // 的动作都要跳一帧（见 AgentInputBar 回车那段的注释，用户实测一次提交
            // 刷 59 条 "Publishing changes from within view updates"）。
            if press.key == .return && press.modifiers.contains(.command) {
                Task { @MainActor in submit() }
                return .handled
            }
            if press.key == .escape && store.isProcessing {
                Task { @MainActor in store.cancel() }
                return .handled
            }
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
                    let toolDurations = derivedData.durations
                    ForEach(store.messages) { msg in
                        if msg.role == .tool,
                           let id = msg.toolCallId,
                           chipToolIds.contains(id) {
                            EmptyView()
                        } else {
                            AgentMessageBubble(
                                message: msg,
                                toolResults: toolResults,
                                isStreamingTail: isStreamingTail(msg),
                                onFeedback: { vote in store.setFeedback(vote, for: msg.id) },
                                toolDurations: toolDurations
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
            .onScrollPhaseChange { _, phase, _ in
                // **只有用户在自己滚**时才允许几何变化改贴底状态。
                // 内容增长（流式每 80ms 长一截、工具卡片/代码块一次长出一大块）
                // 同样会触发下面的 geometry 回调；单次增长超过 160pt 的迟滞阈值时，
                // 旧写法会把它判成"用户上滑了"→ 跟随从此停住 → 用户看到的就是
                // "消息输出到一半被输入框挡住"（尾部留在可视区外）。
                isUserScrolling = phase != .idle
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // 视口没动、是内容长高了 —— 保持跟随，不改状态。
                guard isUserScrolling else { return isPinnedToBottom }
                let distance = geometry.contentSize.height
                    - (geometry.contentOffset.y + geometry.containerSize.height)
                // "贴底"判定带**迟滞**：进入 60pt 内才算贴上、离开 160pt 才算脱离。
                // 单一阈值在流式时会来回翻转，翻一次跳一次——实测就是"上下抖动"。
                // （判定只在用户自己滚动时发生，所以迟滞只需挡住手抖，不必再挡内容增长。）
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
    private func refreshDerivedCache() -> (results: [String: String], chips: Set<String>, durations: [String: Double]) {
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
            derived.durations = Dictionary(
                store.messages.compactMap { m in
                    guard let id = m.toolCallId, let ms = m.toolDurationMs else { return nil }
                    return (id, ms)
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
        return (derived.results, derived.chips, derived.durations)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard force || isPinnedToBottom else { return }
        // Instant reposition: per-token animated scrolls fight the user and
        // can desync under LazyVStack.
        proxy.scrollTo("__bottom__", anchor: .bottom)
        // 强制跟随（用户刚发消息 / 点"回到最新"）顺手恢复贴底状态：状态现在只由
        // 用户滚动改，程序化滚动得自己认领，否则"回到最新"按钮会一直挂着。
        if force { isPinnedToBottom = true }
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
        historyIndex = nil            // 输入历史由 sendMessage 记录（按对话）
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
