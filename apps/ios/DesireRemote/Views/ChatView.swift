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
    /// Agent 状态弹窗（模型 / 上下文 / 权限 / 本回合控制）
    @State private var showStatus = false

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
                    // 内边距与底板都在 agentDock 内部（快捷动作行要留在底板外）
                    agentDock(proxy: proxy)
                }
        }
        .onChange(of: voice.transcribedText) { _, text in
            if voice.isRecording, !text.isEmpty { draft = text }
        }
        // 导航栏**留白但透明**：返回键用系统的（原生玻璃质感，左滑返回手势也
        // 一定可用），同时视觉上仍是全屏聊天——内容会滚到导航栏下面去。
        // 自绘的浮动圆键看着不像原生控件，已去掉。
        // TabBar 必须隐藏：对话是从会话列表 push 进来的。
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task {
            client.requestSessions()
            // 进对话强制要一帧快照：若之前漏了"回合结束"那一帧，状态会一直
            // 停在"工作中"，靠这次主动把 Mac 的当前状态拉回来。
            client.requestSync()
        }
        .sheet(isPresented: $showStatus) {
            AgentStatusSheet(
                busy: client.busy,
                paused: client.paused,
                model: client.agentModel,
                contextPercent: client.contextPercent,
                elapsed: client.elapsedSeconds,
                contextLabel: client.contextLabel,
                fullAccess: client.fullAccess,
                tokens: client.tokens,
                cost: client.cost,
                onPauseToggle: client.busy
                    ? { client.paused ? client.resumeTurn() : client.pauseTurn() } : nil,
                onStop: client.busy ? { client.sendCancel() } : nil)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(client.preferredColorScheme)
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
            .padding(.top, 8)
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

    /// 快捷动作（浮在最上，**不在底板里**）→ 底板内：计划 / 子代理 / 排队 /
    /// 提问 / 审批 / 输入胶囊。
    ///
    /// 快捷动作行属于"建议"，不是输入控件的一部分；把它留在底板里会把那条实色
    /// 底撑得很高（用户实测："黑色背景太高了"）。
    private func agentDock(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 8) {
            if showsQuickActions {
                QuickActionBarView(
                    actions: client.quickActions,
                    canRegenerate: client.canRegenerate,
                    disabled: client.busy,
                    onAction: { client.quickAction(key: $0) },
                    onRegenerate: { client.regenerate() })
                    .padding(.horizontal, 12)
            }

            VStack(spacing: 8) {
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
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
            // 不透明底板只包住需要遮住下方消息的交互区（输入胶囊原本是
            // `.ultraThinMaterial`，滚过来的消息会透过它显形）
            .background(Color(uiColor: .systemBackground))
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

    private var showsQuickActions: Bool {
        !client.messages.isEmpty
            && !client.busy
            && client.question == nil
            && client.approval == nil
            && (!client.quickActions.isEmpty || client.canRegenerate)
    }

    // MARK: - 漂浮输入胶囊

    private var floatingInputBar: some View {
        // 间距 8 → 6、左右内边距 16 → 12：左侧两个图标按钮不再占大块空间，
        // 打字区变宽（原来两个 38pt 圆按钮 + 大间距挤掉了不少宽度）。
        HStack(spacing: 6) {
            statusButton
            micButton
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($inputFocused)
                .disabled(awaitingApproval)
            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            // 实色而非 `.ultraThinMaterial`：半透明会让下方消息透上来
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: client.question?.id)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: client.approval?.id)
    }

    private var placeholder: String {
        if awaitingApproval { return "请先处理上方的工具审批…" }
        if answering { return "回答 Agent 的问题…" }
        return "Message…"
    }

    /// 状态入口：模型 / 上下文 / FULL ACCESS / 本回合控制的弹窗开关。
    /// 做成**无底色的纯图标**（原来是个 38pt 实心圆）：输入条左边原本挤着两个
    /// 同样大的圆按钮，把打字空间压掉一大截。右下小圆点仍表示"回合进行中"。
    private var statusButton: some View {
        Button {
            showStatus = true
        } label: {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(client.fullAccess ? .orange : .secondary)
                .frame(width: 30, height: 30)
                .overlay(alignment: .topTrailing) {
                    if client.busy {
                        Circle()
                            .fill(client.paused ? Color.orange : DesireUI.brand)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Color(.secondarySystemBackground), lineWidth: 1.5))
                            .offset(x: 2, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Agent 状态")
    }

    private var micButton: some View {
        Button {
            if voice.isRecording {
                voice.stop()
            } else {
                voice.start()
            }
        } label: {
            Image(systemName: voice.isRecording ? "mic.fill" : "mic")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(voice.isRecording ? .red : .secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
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
                    .frame(width: 34, height: 34)
                Image(systemName: sendMode == .stop ? "stop.fill" : "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
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
