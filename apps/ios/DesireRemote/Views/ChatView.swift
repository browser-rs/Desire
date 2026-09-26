import SwiftUI

/// 聊天页（主页面根内容）：消息流 + Agent 交互停靠区（状态 / 计划 /
/// 子代理 / 排队 / 快捷动作 / 提问 / 审批）+ 漂浮输入胶囊。
///
/// 交互契约（与桌面 AgentPanel 同序）：
/// - 审批 / 提问是**阻塞态**——Agent 挂起等你处置，输入条相应换模式；
/// - 回合进行中输入的文字不是"取消"，而是排队（桌面在回合结束后自动发出）；
/// - 仅在消息流贴底时自动跟随新消息（迟滞阈值防抖），否则给「最新」跳转键。
struct ChatView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    @StateObject private var voice = VoiceInputService()
    /// 消息流是否贴底（迟滞：贴到 60pt 内跟随，离开 160pt 停跟随）
    @State private var atBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            messageList(proxy: proxy)
                .overlay(alignment: .bottom) {
                    if voice.isRecording {
                        recordingBar
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    agentDock(proxy: proxy)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
        }
        .onChange(of: voice.transcribedText) { _, text in
            if voice.isRecording, !text.isEmpty { draft = text }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 标题即会话切换入口：免去为切会话来回切 Tab
            ToolbarItem(placement: .principal) { sessionMenu }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    client.newSession()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .medium))
                }
                .accessibilityLabel("新建对话")
            }
        }
        .task { client.requestSessions() }
    }

    // MARK: - 顶部会话切换

    private var currentTitle: String {
        client.sessions.first { $0.id == client.selectedSessionID }?.label
            ?? (client.desktopName ?? "Desire")
    }

    private var sessionMenu: some View {
        Menu {
            ForEach(client.sessions.prefix(12)) { session in
                Button {
                    if session.id != client.selectedSessionID { client.selectSession(session.id) }
                } label: {
                    Label(
                        session.label,
                        systemImage: session.id == client.selectedSessionID
                            ? "checkmark" : "bubble.left")
                }
            }
            if !client.sessions.isEmpty { Divider() }
            Button {
                client.newSession()
            } label: {
                Label("新建对话", systemImage: "plus.bubble")
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        }
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
                if client.messages.isEmpty {
                    chatEmptyState
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
        // 距底距离 → 迟滞判定：贴到 60pt 内跟随，离开 160pt 停跟随。
        // （单阈值会让"正在滚动"和"贴底"边界反复抖动）
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentSize.height + geo.contentInsets.bottom
                - geo.contentOffset.y - geo.containerSize.height
        } action: { _, distance in
            if distance < 60 {
                if !atBottom { atBottom = true }
            } else if distance > 160 {
                if atBottom { atBottom = false }
            }
        }
        .onChange(of: client.messages) { _, _ in
            guard atBottom else { return }
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        // 刚发出：必定跳到最新（本地回显不等快照）
        .onChange(of: client.pendingEcho) { _, echo in
            if echo != nil { jumpToBottom(proxy) }
        }
        // 审批 / 提问出现：焦点在这里，滚到底让用户看到
        .onChange(of: client.approval) { _, value in
            if value != nil { jumpToBottom(proxy) }
        }
        .onChange(of: client.question) { _, value in
            if value != nil { jumpToBottom(proxy) }
        }
    }

    private func jumpToBottom(_ proxy: ScrollViewProxy) {
        atBottom = true
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    /// 空对话引导：告诉用户手机能干什么，并给出可一键启动的快捷动作
    /// （与桌面 AgentEmptyStateView 同思路）。
    private var chatEmptyState: some View {
        VStack(spacing: 18) {
            DesireEmptyState(
                icon: "bubble.left.and.bubble.right",
                title: "开始对话",
                message: client.desktopOnline
                    ? "说一句话，Mac 上的 Agent 就开始干活。\n需要你批准的步骤会在这里弹出。"
                    : "Mac 当前离线。消息会先排队，它上线后自动送达。")
            if !client.quickActions.isEmpty {
                quickActionGrid
                    .padding(.horizontal, 4)
            }
        }
        .padding(.top, 20)
    }

    private var quickActionGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
            spacing: 8
        ) {
            ForEach(client.quickActions) { action in
                Button {
                    client.quickAction(key: action.key)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: action.icon)
                            .font(.system(size: 11, weight: .medium))
                        Text(action.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(DesireUI.cardFill)
                    )
                }
                .buttonStyle(.plain)
                .disabled(client.busy)
            }
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

    // MARK: - Agent 停靠区

    /// 状态 → 计划 → 子代理 → 排队 → 快捷动作 → 提问 → 审批 → 输入胶囊。
    private func agentDock(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 8) {
            if showsStatus {
                AgentStatusStripView(
                    busy: client.busy,
                    paused: client.paused,
                    model: client.agentModel,
                    contextPercent: client.contextPercent,
                    elapsed: client.elapsedSeconds,
                    contextLabel: client.contextLabel,
                    fullAccess: client.fullAccess,
                    onPauseToggle: client.busy
                        ? { client.paused ? client.resumeTurn() : client.pauseTurn() } : nil,
                    onStop: client.busy ? { client.sendCancel() } : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !client.plan.isEmpty {
                PlanStripView(steps: client.plan)
            }
            if !client.subagents.isEmpty {
                SubagentStripView(subagents: client.subagents)
            }
            if !client.queued.isEmpty {
                QueuedStripView(
                    queued: client.queued,
                    onRemove: { client.removeQueued(id: $0) },
                    onClearAll: { client.clearQueued() })
            }
            if showsQuickActions {
                QuickActionBarView(
                    actions: client.quickActions,
                    canRegenerate: client.canRegenerate,
                    disabled: client.busy,
                    onAction: { client.quickAction(key: $0) },
                    onRegenerate: { client.regenerate() })
            }
            if let question = client.question {
                RemoteQuestionCard(question: question) { text in
                    client.answer(id: question.id, text: text)
                }
            }
            if let approval = client.approval {
                RemoteApprovalBar(approval: approval) { decision in
                    client.approve(id: approval.id, decision: decision)
                }
            }
            floatingInputBar
        }
        // 「最新」键浮在停靠区上方（不占布局高度，免得滚动时整块跳一下）
        .overlay(alignment: .topTrailing) {
            if !atBottom {
                jumpPill(proxy)
                    .offset(y: -40)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: atBottom)
    }

    private func jumpPill(_ proxy: ScrollViewProxy) -> some View {
        Button {
            jumpToBottom(proxy)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text("最新")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
            )
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
            )
            .padding(.trailing, 8)
        }
        .buttonStyle(.plain)
    }

    private var showsStatus: Bool {
        client.busy || client.fullAccess || !(client.contextLabel ?? "").isEmpty
    }

    private var showsQuickActions: Bool {
        !client.messages.isEmpty
            && !client.busy
            && client.question == nil
            && client.approval == nil
            && (!client.quickActions.isEmpty || client.canRegenerate)
    }

    // MARK: - 漂浮输入胶囊

    private var floatingInputBar: some View {
        HStack(spacing: 8) {
            micButton
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($inputFocused)
                .disabled(awaitingApproval)
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
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: client.question?.id)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: client.approval?.id)
    }

    private var placeholder: String {
        if awaitingApproval { return "请先处理上方的工具审批…" }
        if answering { return "回答 Agent 的问题…" }
        return "Message…"
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
        .disabled(!voice.isAvailable || awaitingApproval)
    }

    private var sendButton: some View {
        Button {
            send()
        } label: {
            ZStack {
                Circle()
                    .fill(sendTint)
                    .frame(width: 38, height: 38)
                Image(systemName: sendMode == .stop ? "stop.fill" : "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(sendMode == .disabled ? Color.secondary : .white)
            }
        }
        .buttonStyle(.plain)
        .disabled(sendMode == .disabled)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: sendTint)
    }

    // MARK: - 输入条模式

    /// 输入条语义：作答 / 停止 / 发送 / 不可用。
    /// 关键修正：回合进行中输入文字**不再是取消整轮**（旧版一点发送就取消，
    /// 用户想追加一句话却把 Agent 打断了）——文字照常发出，桌面自动排队。
    private enum SendMode {
        case answering
        case stop
        case send
        case disabled
    }

    private var answering: Bool { client.question != nil }
    private var awaitingApproval: Bool { client.approval != nil }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sendMode: SendMode {
        if awaitingApproval { return .stop }
        if answering { return hasDraft ? .answering : .disabled }
        if hasDraft { return .send }
        return client.busy ? .stop : .disabled
    }

    private var sendTint: Color {
        switch sendMode {
        case .stop: .red
        case .answering, .send: RootView.brand
        case .disabled: Color(.secondarySystemBackground)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch sendMode {
        case .answering:
            guard let question = client.question else { return }
            client.answer(id: question.id, text: text)
            draft = ""
        case .send:
            atBottom = true
            client.sendPrompt(text)
            draft = ""
        case .stop:
            client.sendCancel()
        case .disabled:
            break
        }
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
