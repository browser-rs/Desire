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
    @State private var showCostDetails = false

    /// 成本 chip 文案：token 常显；金额只在全部可定价时显示（`AgentUsage` 口径）。
    private var costChipText: String {
        let usage = store.conversationUsage
        let tokens = AgentUsage.formatTokens(usage.totalTokens)
        return usage.formattedUSD.map { "\(tokens) · \($0)" } ?? tokens
    }
    @State private var showStats = false
    /// 输入历史翻阅位置（nil = 不在翻阅）。历史本身在 store 里、按对话保存。
    @State private var historyIndex: Int?
    /// 上一次的文本变化来自历史回填（据此区分"用户手打" → 退出翻阅）。
    @State private var recalledFromHistory = false
    @State private var showHistory = false
    // 从会话提炼技能（v0.7.22 旗舰）：跑一次旁路调用 → 编辑器预填草稿。
    @State private var distillRunning = false
    @State private var distillDraft: SkillDistill.Draft?
    @State private var showDistillEditor = false
    @State private var distillError: String?

    // 会话内查找（v0.7.21）：⌘F 打开；命中消息高亮 + 滚动定位。
    @State private var showFind = false
    @State private var findText = ""
    @State private var findMatches: [UUID] = []
    @State private var findIndex = 0
    /// 集中搜索的"跳到命中轮"（v0.8.6）：载入会话后滚动到该消息并开查找框。
    @State private var pendingJumpMessageID: UUID?
    @State private var scrollProxy: ScrollViewProxy?
    @FocusState private var isFindFieldFocused: Bool
    @State private var showCapabilities = false
    @State private var showMemory = false
    /// 白板开关（由宿主窗口注入——面板不持有窗口对象）。
    var onToggleWhiteboard: (() -> Void)? = nil
    /// 悬浮球开关（同上）。
    var onToggleBall: (() -> Void)? = nil
    /// 两栏布局（独立 Agent 窗口）：侧栏开关回调与显隐状态。浏览器内嵌的
    /// 窄栏宿主不传（nil = 单栏，头部不出现开关）。
    var onToggleSidebar: (() -> Void)? = nil
    var isSidebarExpanded: Bool = false
    /// 独立窗口两栏模式：历史/能力/轨迹/统计/记忆的导航入口已上移到侧栏
    /// 的"智能体"区，头部不再重复这排按钮（白板/悬浮球/新对话/清空保留——
    /// 它们是动作不是导航）。浏览器内嵌面板不受影响（默认 false）。
    var hidesHeaderNavigation: Bool = false
    @ObservedObject private var memory = AgentMemoryStore.shared
    /// Image attachments (JPEG data URIs) awaiting the next send.
    @State private var pendingImages: [String] = []
    @State private var isDroppingImage = false
    @ObservedObject private var planStore = AgentPlanStore.shared
    @ObservedObject private var recorder = WindowRecorder.shared
    @ObservedObject var promptCenter: UserPromptCenter
    /// 全局提问中心（askUser 已 per-session 化，但**系统命令协商、桥 /agent/prompt、
    /// 远程提问卡**仍走 shared 单例——面板双通道渲染，任何一条提问都可可见）。
    @ObservedObject var sharedPromptCenter = UserPromptCenter.shared
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
                // 三步首启引导（0.6.7）：模型/拦截/同步+个性化（取代旧单屏）。
                OnboardingFlowView(onFinish: {})
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
        .sheet(isPresented: $showDistillEditor) {
            AgentSkillEditorSheet(editing: nil, draftPrelude: distillDraft) {
                SkillStore.shared.reload()
            }
        }
        .alert(String(localized: "Skill distillation failed"),
               isPresented: Binding(
                    get: { distillError != nil },
                    set: { if !$0 { distillError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(distillError ?? "")
        }
        .onAppear {
            // 面板出现（打开/从子页回来）时把焦点交给输入框 —— 否则必须先用鼠标
            // 点一下输入框才能打字（用户反馈过的 UX 缺陷）。@FocusState 在 onAppear
            // 的事务里直接置真**不生效**（走不进 AppKit 的 first responder），
            // 要跳一帧并给足时间（~400ms，实测能成的值，AGENTS 记录在案）。
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                let onSubpage = showMemory || showStats || showTrace || showCapabilities || showHistory
                if !onSubpage { isInputFocused = true }
            }
        }
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            AgentHeaderView(
                store: store,
                preference: store.preference,
                hasHistory: !conversationStore.conversations.isEmpty,
                onShowHistory: hidesHeaderNavigation ? nil : { showHistory = true },
                onShowCapabilities: hidesHeaderNavigation ? nil : { showCapabilities = true },
                onDistillSkill: { distillCurrentConversation() },
                onShowTrace: hidesHeaderNavigation ? nil : { showTrace = true },
                onShowStats: hidesHeaderNavigation ? nil : { showStats = true },
                onShowMemory: hidesHeaderNavigation ? nil : { showMemory = true },
                onShowWhiteboard: onToggleWhiteboard,
                onToggleBall: onToggleBall,
                onToggleSidebar: onToggleSidebar,
                isSidebarExpanded: isSidebarExpanded,
                onNewChat: { store.clear() }
            )

            if distillRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Distilling a skill draft from this conversation…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.bar)
            }

            if showFind {
                findBar
            }

            // 本对话成本（v0.7.26）：token 常有、金额按"有单价才显示"的口径；
            // 点开按 模型×类型（主回合/子代理/旁路）拆明细。
            if !store.conversationUsage.isEmpty {
                Button {
                    showCostDetails.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "dollarsign.circle")
                            .font(.system(size: 9))
                        Text(costChipText)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .popover(isPresented: $showCostDetails, arrowEdge: .bottom) {
                    CostBreakdownPopover(
                        breakdown: CostBreakdown.derive(store.messages,
                                                        price: store.preference.usagePrice(for:)))
                }
                .help("本对话成本明细")
            }

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

            // Live task checklist from the updatePlan tool（按本面板会话读取，
            // 切换对话跟随显示对应计划）。
            let activePlan = planStore.steps(for: store.conversationId?.uuidString)
            if !activePlan.isEmpty {
                AgentPlanView(steps: activePlan)
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
                CrewProgressStrip(crew: crew,
                                  price: store.preference.usagePrice(for:),
                                  onCancelAll: { crewStore.cancelAll() })
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
                    customTemplates: store.preference.customTemplates.filter { !$0.isEmpty },
                    onCustomTemplate: { template in
                        // 与固定动作同语义：整条 prompt 发送、不进输入历史。
                        store.sendMessage(template.prompt, recordHistory: false)
                    },
                    // 与快捷动作同一行（此前是独立的一行，看着像两组无关按钮）。
                    onRegenerate: canRegenerate ? { store.regenerate() } : nil
                )
                .frame(maxWidth: Self.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }

            if let question = promptCenter.pending {
                AgentQuestionCard(question: question.question, quickOptions: question.quickOptions) { answer in
                    promptCenter.answer(answer)
                }
                .frame(maxWidth: Self.contentMaxWidth)
                .frame(maxWidth: .infinity)
            } else if let question = sharedPromptCenter.pending {
                // 系统命令协商 / 桥 / 远程的全局提问（同一张卡片样式）。
                AgentQuestionCard(question: question.question, quickOptions: question.quickOptions) { answer in
                    sharedPromptCenter.answer(answer)
                }
                .frame(maxWidth: Self.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }

            if let approval = store.pendingApproval {
                ToolApprovalBar(
                    approval: approval,
                    onAllowOnce: { store.resolveApproval(.allowOnce) },
                    onAlwaysAllow: { store.resolveApproval(.alwaysAllow) },
                    onDeny: { store.resolveApproval(.deny) },
                    onAlwaysAllowOnSite: { _ in
                        // 站点级放行（0.8.1）：通用工具落成「工具 × 站点」规则；
                        // DPP pageAction 仍走 store 里的「站点 × 动作」授权。
                        store.resolveApproval(.alwaysAllow, siteGrant: true)
                    },
                    onDenyOnSite: { _ in
                        store.resolveApproval(.deny, siteGrant: true)
                    },
                    siteHost: store.pendingApprovalSiteHost,
                    sourceFrameHost: store.pendingApprovalSourceFrameHost
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
                                store.runQueuedNow(id: item.id)
                            } label: {
                                Image(systemName: "play.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                            .help("立即执行（取消当前回合并优先运行这条）")
                            .disabled(!store.isProcessing)
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

            if store.hasUnansweredPrompt && !store.isProcessing {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("上一条提问还没有收到回答")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button {
                        store.resumeLastPrompt()
                    } label: {
                        Text("继续回答")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(appAccent)
                    }
                    .buttonStyle(.plain)
                    .help("Resume the unanswered prompt")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(appAccent.opacity(0.06))
                )
                .frame(maxWidth: Self.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
            }

            // 检查点恢复：上回合被打断（崩溃/强杀残留标志）→ 继续/放弃。
            if store.hasInterruptedTurn && !store.isProcessing {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("上一次的回合被中断")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button {
                        store.resumeInterruptedTurn()
                    } label: {
                        Text("继续回合")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(appAccent)
                    }
                    .buttonStyle(.plain)
                    Button {
                        store.discardInterruptedTurn()
                    } label: {
                        Text("放弃")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(appAccent.opacity(0.06))
                )
                .frame(maxWidth: Self.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
            }

            sessionDirectiveBar
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
                onCancel: {
                    // 多 store 结构：流的主人未必是这个面板的 store（另一窗口/
                    // 浮窗的回合在跑时，这里只有空闲 store）——单 cancel 自己
                    // 是空操作（用户实测"开关窗口后打断无效"）。先记状态再停，
                    // 自己在跑就只停自己，空闲则把其余还在跑的一并停掉。
                    let wasProcessing = store.isProcessing
                    store.cancel()
                    if !wasProcessing {
                        AgentScheduler.shared.cancelStreamingSessions(except: nil)
                    }
                },
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
                thinkingMenu: AnyView(AgentThinkingMenu(preference: store.preference)),
                contextChip: AnyView(AgentContextChip(store: store)),
                fullAccessPill: AnyView(AgentFullAccessPill(store: store)),
                onSessionDirective: {
                    directiveDraft = store.activeDirective ?? ""
                    directiveEditing = true
                },
                isSessionDirectiveActive: store.activeDirective != nil
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
                // 换对话时停掉上一段的回复朗读（v0.7.28）。
                ReaderSpeechService.shared.stop()
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
            if press.key == KeyEquivalent("f") && press.modifiers.contains(.command) {
                Task { @MainActor in openFind() }
                return .handled
            }
            if press.key == .escape && showFind {
                Task { @MainActor in showFind = false }
                return .handled
            }
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

    /// 点踩原因 → feedback 记忆（学习开关关了不沉淀）。拆出方法——闭包内
    /// 联 String(localized:) 插值曾让 SwiftUI 表达式 type-check 超时。
    private func learnFromDislike(_ messageID: UUID, _ reason: String) {
        guard store.preference.memoryLearning else { return }
        let trimmed = reason.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        AgentMemoryStore.shared.addFact(
            content: String(localized: "User dislikes: \(trimmed)"),
            category: "feedback")
    }

    /// 会话级临时指令条（输入框上方）：活跃时显示，点文案编辑、✕ 清除。
    @State private var directiveEditing = false
    @State private var directiveDraft = ""
    @ViewBuilder
    private var sessionDirectiveBar: some View {
        if let directive = store.activeDirective {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(appAccent)
                Text(directive)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .onTapGesture {
                        directiveDraft = directive
                        directiveEditing = true
                    }
                Spacer(minLength: 0)
                Button {
                    store.setSessionDirective(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear session instruction"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(appAccent.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(appAccent.opacity(0.25), lineWidth: 0.5)
            )
            .popover(isPresented: $directiveEditing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Session instruction"))
                        .font(.system(size: 12, weight: .medium))
                    TextField(String(localized: "e.g. Answer in English for this conversation"),
                              text: $directiveDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(width: 260)
                        .onSubmit { store.setSessionDirective(directiveDraft); directiveEditing = false }
                    HStack {
                        Button(String(localized: "Apply")) {
                            store.setSessionDirective(directiveDraft)
                            directiveEditing = false
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(directiveDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button(String(localized: "Cancel")) { directiveEditing = false }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    Text(String(localized: "Applies to this conversation only — never saved to memory."))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
    }

    /// 单条消息行（拆出方法——原来内联在 ForEach 里的表达式加了 onLearnReason
    /// 闭包后 type-check 超时）。
    @ViewBuilder
    private func messageRow(
        _ msg: AgentMessage,
        toolResults: [String: String],
        chipToolIds: Set<String>,
        toolDurations: [String: Double],
        latestBoardCardID: UUID?
    ) -> some View {
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
                onLearnReason: { learnFromDislike(msg.id, $0) },
                toolDurations: toolDurations,
                conversationID: store.conversationId?.uuidString,
                isLatestBoardCard: msg.id == latestBoardCardID
            )
            .id(msg.id)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(appAccent.opacity(0.65), lineWidth: 1.5)
                    .opacity(isCurrentFindMatch(msg.id) ? 1 : 0)
                    .allowsHitTesting(false)
            )
        }
    }

    // MARK: - 会话内查找

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(String(localized: "Find in conversation"), text: $findText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 200)
                .focused($isFindFieldFocused)
                .onChange(of: findText) { _, _ in recomputeFind(reset: true) }
                .onSubmit { advanceFind(1) }
                .onKeyPress(.upArrow) { advanceFind(-1); return .handled }
                .onKeyPress(.downArrow) { advanceFind(1); return .handled }
                .onKeyPress(.escape) { Task { @MainActor in showFind = false }; return .handled }
            if !findText.isEmpty {
                Text(findMatches.isEmpty
                     ? String(localized: "No matches")
                     : "\(findIndex + 1) / \(findMatches.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("Previous", systemImage: "chevron.up") { advanceFind(-1) }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(findMatches.isEmpty)
            Button("Next", systemImage: "chevron.down") { advanceFind(1) }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(findMatches.isEmpty)
            Button("Done", systemImage: "xmark") { showFind = false }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    /// 「提炼为技能」：当前会话 → 旁路模型 → 草稿 → 编辑器预填（用户在编辑器里
    /// 剪裁后保存；这里**不落盘**——草稿是建议，保存动作归用户）。
    private func distillCurrentConversation() {
        guard !distillRunning else { return }
        distillRunning = true
        let messages = store.messages
        let preference = store.preference
        Task { @MainActor in
            let draft = await SkillDistiller.draft(from: messages, preference: preference)
            distillRunning = false
            if let draft {
                distillDraft = draft
                showDistillEditor = true
            } else {
                distillError = String(localized: "Could not distill a skill from this conversation — the run may be too short, or the model did not return a parsable draft.")
            }
        }
    }

    private func openFind() {
        showFind = true
        recomputeFind(reset: true)
        // 聚焦晚一帧（焦点在更新事务内同步置位会被字段编辑器吃掉，见既有惯例）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            isFindFieldFocused = true
        }
    }

    private func recomputeFind(reset: Bool) {
        findMatches = AgentMessageSearch.matches(messages: store.messages, query: findText)
        if reset { findIndex = 0 }
        findIndex = min(max(0, findIndex), max(0, findMatches.count - 1))
        jumpToCurrentMatch()
    }

    private func advanceFind(_ delta: Int) {
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex + delta + findMatches.count) % findMatches.count
        jumpToCurrentMatch()
    }

    private func jumpToCurrentMatch() {
        guard findMatches.indices.contains(findIndex) else { return }
        scrollProxy?.scrollTo(findMatches[findIndex], anchor: .center)
    }

    private func isCurrentFindMatch(_ id: UUID) -> Bool {
        showFind && findMatches.indices.contains(findIndex) && findMatches[findIndex] == id
    }

    private var messageScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    let derivedData = refreshDerivedCache()
                    let toolResults = derivedData.results
                    let chipToolIds = derivedData.chips
                    let toolDurations = derivedData.durations
                    // 最新一张"可见"白板卡拿实时预览，其余折叠（见 WhiteboardToolCard）。
                    let latestBoardCardID = store.messages.last { msg in
                        guard msg.isWhiteboardToolResult else { return false }
                        if let id = msg.toolCallId { return !chipToolIds.contains(id) }
                        return true
                    }?.id
                    ForEach(store.messages) { msg in
                        messageRow(
                            msg,
                            toolResults: toolResults,
                            chipToolIds: chipToolIds,
                            toolDurations: toolDurations,
                            latestBoardCardID: latestBoardCardID
                        )
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("__bottom__")
                        .onAppear { scrollProxy = proxy }
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
            // 集中搜索跳转（v0.8.6）：收到通知时若正在展示该会话，滚动到
            // 命中消息并开查找框预填查询词。跳一帧（Task）——通知可能
            // 恰在 loadConversation 的状态写入事务里到达。
            .onReceive(NotificationCenter.default.publisher(for: .agentJumpToMessage)) { note in
                guard let info = note.userInfo,
                      let convID = info["conversationID"] as? String,
                      convID == (store.conversationId?.uuidString ?? ""),
                      let messageID = info["messageID"] as? String,
                      let target = UUID(uuidString: messageID) else { return }
                let query = info["query"] as? String ?? ""
                Task { @MainActor in
                    if !query.isEmpty {
                        findText = query
                        showFind = true
                        recomputeFind(reset: true)
                        if let idx = findMatches.firstIndex(of: target) { findIndex = idx }
                    }
                    if store.messages.contains(where: { $0.id == target }) {
                        // 命中的就是当前会话：消息已在列表里，直接滚（onChange
                        // 只覆盖"切换会话后"的路径——同会话时它不触发）。
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        scrollProxy?.scrollTo(target, anchor: .center)
                    } else {
                        // 切换会话中：等 onChange(conversationId) 布局完成后滚。
                        pendingJumpMessageID = target
                    }
                }
            }
            // 载入新会话（集中搜索先 loadConversation 再发通知）后，滚动
            // 到跳转目标：消息列表此时已换血，须等本轮 body 完成布局。
            .onChange(of: store.conversationId) { _, _ in
                guard let target = pendingJumpMessageID else { return }
                pendingJumpMessageID = nil
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    scrollProxy?.scrollTo(target, anchor: .center)
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
            derived.chips = Set(store.messages.flatMap { m -> [String] in
                guard m.role == .assistant else { return [] }
                // whiteboard 的结果消息由 WhiteboardToolCard 渲染（聊天内嵌
                // 实时板）——不 chip 化，否则消息行被 EmptyView 吞掉、白板卡
                // 永远不出现（2026-10-04 用户实测抓到）。
                return (m.toolCalls ?? []).compactMap { call in
                    call.function.name == "whiteboard" ? nil : call.id
                }
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
        // 渲染收口在 AgentConversationExport（slash /export 与这里共用一份）。
        let lines = AgentConversationExport.markdown(store.messages)

        let panel = NSSavePanel()
        panel.title = "Export Conversation"
        panel.nameFieldStringValue = "\(store.conversationTitle ?? "conversation").md"
        panel.allowedContentTypes = [.plainText]
        // 非阻塞（PERF-6）：runModal 冻结整个 app。
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? lines.write(to: url, atomically: true, encoding: .utf8)
        }
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
            store.sendFollowUp(text, images: images)
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
        // 非阻塞（PERF-6）。
        panel.begin { response in
            guard response == .OK else { return }
            let uris = panel.urls.compactMap { url -> String? in
                guard let image = NSImage(contentsOf: url) else { return nil }
                return ImageAttachment.dataURI(from: image)
            }
            self.pendingImages.append(contentsOf: uris)
        }
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
    return AgentPanel(store: store, conversationStore: conversationStore, promptCenter: store.promptCenter)
        .frame(width: 360, height: 560)
}
/// Tab Crew 进度条（0.3.1 起；v0.7.22 运行观察面；v0.7.27 补逐 worker 成本）：
/// 概要行（状态点 + 目标 + 取消/关闭）+ 每个 worker 的详情（当前步骤 / 已用时 /
/// 工具调用数 / token 与金额）。终态 worker 保留在条子里（悬停看结果），
/// 否则"跑完就消失"，看不到每个子任务花了多少。WorkerTask 是引用类型，进度靠
/// store 侧节流 objectWillChange 推动重绘；运行中的已用时用 TimelineView 自走。
struct CrewProgressStrip: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let crew: AgentCrewStore.Crew
    /// 单价查询（与全 app 成本口径同源：未定价返回 nil → 只显示 token）。
    let price: (String?) -> ModelPrice?
    let onCancelAll: () -> Void

    private func tint(_ state: AgentCrewStore.WorkerTask.State) -> Color {
        switch state {
        case .pending: return Color.secondary.opacity(0.4)
        case .running: return appAccent
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    /// dispatch 上限就是 6 个；终态也保留。
    private var observedTasks: [AgentCrewStore.WorkerTask] {
        Array(crew.tasks.prefix(6))
    }

    private func costText(_ task: AgentCrewStore.WorkerTask) -> String? {
        guard let model = price(task.model),
              let usd = model.cost(promptTokens: task.promptTokens,
                                   completionTokens: task.completionTokens) else { return nil }
        return AgentUsage.formatUSD(usd)
    }

    private func elapsedText(_ task: AgentCrewStore.WorkerTask) -> String? {
        guard let start = task.startedAt else { return nil }
        return msText((task.finishedAt ?? Date()).timeIntervalSince(start))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
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
                } else {
                    Button {
                        AgentCrewStore.shared.clear()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
            }
            ForEach(observedTasks) { t in
                HStack(spacing: 6) {
                    Text("#\(t.index)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(t.instruction)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .foregroundStyle(t.state == .cancelled ? .secondary : .primary)
                    if t.state == .running, let step = t.currentStep {
                        Text(step)
                            .font(.system(size: 10))
                            .foregroundStyle(appAccent)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if t.totalTokens > 0 {
                        Text(AgentUsage.formatTokens(t.totalTokens))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .help(t.model.map {
                                "\($0) · \(t.promptTokens) prompt / \(t.completionTokens) completion"
                            } ?? "\(t.promptTokens) prompt / \(t.completionTokens) completion")
                    }
                    if let cost = costText(t) {
                        Text(cost)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if t.toolCallCount > 0 {
                        Text("\(t.toolCallCount)×")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    if t.state == .running, let started = t.startedAt {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text(msText(context.date.timeIntervalSince(started)))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    } else if let elapsed = elapsedText(t) {
                        Text(elapsed)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 18)
                .help(t.result.map { String($0.prefix(400)) } ?? "")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(appAccent.opacity(0.08))
        .animation(.overlaySpring, value: crew.tasks.map { $0.state.rawValue })
    }

    private func msText(_ seconds: TimeInterval) -> String {
        seconds >= 60
            ? String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
            : String(format: "%.0fs", seconds)
    }
}


extension Notification.Name {
    /// 集中搜索命中会话正文后请求跳转：userInfo 带 conversationID/messageID/query。
    /// 面板已展示该会话才响应（多窗口各面板按会话 id 认领）。
    static let agentJumpToMessage = Notification.Name("desire.agent.jumpToMessage")
}
