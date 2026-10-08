import AppKit
import Combine
import Foundation

/// 悬浮球状态（视觉在 `AgentBallOverlay`——**窗口内覆盖层**，不是独立面板：
/// 透明 NSPanel 上 `.glassEffect()` 与 NSVisualEffectView(behindWindow) 都
/// 采样不到跨进程背景，玻璃退化成实心灰（实拍两轮）。窗口内才有真液态
/// 玻璃；"窗口内任意拖动"本就是需求语义）。
@MainActor
final class AgentBallPanel: ObservableObject {
    static let shared = AgentBallPanel()

    @Published private(set) var isEnabled: Bool
    /// 全能力顺序表（v7：14 项，**前 4 = 主盘 2×2**，全览网格顺序跟随此表
    /// ——设置子页可整体排序，"我的常用排前面"）。旧档只存 4 值，解码按
    /// allCases 顺序补齐其余项。**初始值必须用全表 defaultOrder**：
    /// 无持久化档（键被删/全新安装）时走这里，若给 defaultSlots（4 项）
    /// 全览就只剩 4 个（用户实测"其他都不见了"）。
    @Published var slots: [BallCapability] = BallCapability.defaultOrder {
        didSet { persistSlots() }
    }
    /// 「自定义提示词」槽位发送的文本（设置页可编辑）。
    @Published var customPrompt: String {
        didSet { UserDefaults.standard.set(customPrompt, forKey: Self.customPromptKey) }
    }
    @Published var isExpanded = false {
        didSet {
            // "全部"是临时全览视图，不跨展开周期：每次收起触盘都复位回
            // 2×2 主盘——否则全览态收起后再次展开永远是全部（用户实测）。
            if !isExpanded, hubShowsAll { hubShowsAll = false }
        }
    }
    /// 活跃会话的 Agent 正在处理（球上进度环）。
    @Published private(set) var agentBusy = false
    /// Agent 回复完成提醒（busy 下降沿触发，数秒后自动消失）。
    @Published private(set) var replyFlash = false
    /// 回复预览（v5）：徽章在窗时悬停球出气泡——免开面板先睹答了什么。
    @Published private(set) var replyPreview: String?
    /// 触盘 2×2 ⇄ 全 8 能力（4×2）切换（长按球 / 盘上 ⌄ / 桥 POST /agentball）。
    @Published var hubShowsAll = false
    /// 拖拽投递的待决载荷（v5）：松手不直接发送，弹动作选择，点选才起回合。
    @Published var pendingDrop: String?
    /// v7 快捷动作的结果反馈（球旁玻璃胶囊，同语音已发送通道的样式）。
    @Published var actionToast: String?
    /// 清除定时器句柄：新 toast 必须取消上一个的定时——否则前一条的
    /// 3.2s 定时把刚发的新 toast 提前清掉（实测"下载全部"的反馈被
    /// 前一条"单视频"的定时吃掉，toast 永远空）。
    private var toastClearTask: Task<Void, Never>?

    func flashToast(_ text: String) {
        actionToast = text
        toastClearTask?.cancel()
        toastClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            self?.actionToast = nil
        }
    }

    /// 页面上下文（触盘菜单头）：宿主窗口注入（每窗一个覆盖层）。
    struct PageContext {
        let title: String
        let urlString: String
    }
    var pageContextProvider: (() -> PageContext?)?
    /// 页面元素全屏（视频等）时球让位——覆盖层会压在全屏内容上。
    @Published private(set) var hiddenForFullscreen = false
    let voice = VoiceInputManager()
    @Published var voiceTranscriptSent: String?

    /// 宿主注入的动作（ContentView 提供——AI 会话与窗口绑定在那边）。
    var onOpenAgentPanel: (() -> Void)?
    var onAskAboutPage: (() -> Void)?
    /// 通用发话口（v4：翻译本页 / 自定义提示词 / 拖拽投递共用）。
    var onSendPrompt: ((String) -> Void)?
    /// 触发系统截图（v4 触盘「截图」槽位）。
    var onScreenshot: (() -> Void)?
    /// 当前标签是否处于元素全屏（视频等）——球自动让位。
    var onPageFullscreen: (() -> Bool)?
    /// v7 特色快捷动作的操作对象：当前选中标签（去广告/视频下载都以它为
    /// 目标页）。宿主（ContentView）注入。
    var pageTabProvider: (() -> Tab?)?

    static let enabledChangedNotification = Notification.Name("agentBall.enabledChanged")
    static let edgeKey = "agentBall.edge"
    static let offsetKey = "agentBall.offset"
    static let enabledKey = "agentBall.enabled"
    static let sizeKey = "agentBall.size"
    static let slotsKey = "agentBall.slots"
    static let customPromptKey = "agentBall.customPrompt"
    // v6 个性化（设置页「悬浮球」子页）。
    static let opacityKey = "agentBall.opacity"
    static let idleStyleKey = "agentBall.idleStyle"
    static let hubScaleKey = "agentBall.hubScale"
    static let hubAnimationKey = "agentBall.hubAnimation"
    static let doubleClickVoiceKey = "agentBall.doubleClickVoice"

    var conversationID: String? {
        AgentScheduler.shared.deliveryTarget?.conversationId?.uuidString
    }

    private var cancellables: Set<AnyCancellable> = []
    private var pollTimer: Timer?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if let raw = UserDefaults.standard.string(forKey: Self.customPromptKey),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            customPrompt = raw
        } else {
            customPrompt = "总结本页并给出三点建议"
        }
        if let raw = UserDefaults.standard.stringArray(forKey: Self.slotsKey) {
            slots = BallCapability.decodeSlots(raw)
        }
        // 语音：开始录音 → 展开操作条显示实时转写；停止且非空 → 自动发给 Agent
        voice.$isRecording
            .sink { [weak self] recording in
                guard let self else { return }
                if recording { isExpanded = true }
            }
            .store(in: &cancellables)
        voice.$isRecording
            .combineLatest(voice.$transcribedText)
            .map { recording, text in (!recording, text) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] stopped, text in
                guard let self, stopped else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self.onOpenAgentPanel?()
                AgentScheduler.shared.deliveryTarget?.sendMessage(trimmed)
                self.voiceTranscriptSent = trimmed
                self.isExpanded = false
            }
            .store(in: &cancellables)

        // 感知轮询（2s）：Agent 忙碌（进度环）+ 回复完成（徽章）+ 全屏让位
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.poll() }
        }
    }

    private func poll() {
        guard isEnabled else { return }
        let busy = AgentScheduler.shared.deliveryTarget?.isProcessing ?? false
        if busy != agentBusy {
            agentBusy = busy
            if !busy {
                // busy 下降沿 = 回合刚结束 → 徽章 + 回复预览。
                //（此前写成 `if agentBusy, !busy`——agentBusy 上方刚赋成 busy，
                // 条件永假，徽章从未亮过；v5 顺手修掉。）
                replyFlash = true
                replyPreview = AgentScheduler.shared.deliveryTarget?.messages
                    .last(where: { $0.role == .assistant })?
                    .content.map { String($0.prefix(120)) }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(6))
                    guard !Task.isCancelled else { return }
                    self.replyFlash = false
                    self.replyPreview = nil
                }
            }
        }
        let inFS = onPageFullscreen?() ?? false
        if inFS != hiddenForFullscreen { hiddenForFullscreen = inFS }
    }

    /// 桥端点的兼容字段：开启即视为可见。
    var isVisible: Bool { isEnabled }

    /// 设置页/菜单的全局开关（各窗口的覆盖层直接观察 isEnabled）。
    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if !on { isExpanded = false }
        NotificationCenter.default.post(name: Self.enabledChangedNotification, object: nil)
    }

    func toggle() {
        setEnabled(!isEnabled)
    }

    // MARK: - 动作

    func openAgentPanel() {
        onOpenAgentPanel?()
        isExpanded = false
    }

    func askAboutPage() {
        onAskAboutPage?()
        isExpanded = false
    }

    func openWhiteboard() {
        WhiteboardPanel.shared.show()
        isExpanded = false
    }
}

extension AgentBallPanel {
    var encodedSlots: [String] { slots.map(\.rawValue) }

    private func persistSlots() {
        UserDefaults.standard.set(encodedSlots, forKey: Self.slotsKey)
    }

    /// 设置页换槽：把槽位 i 换成新能力；若该能力已在其他槽位，两槽互换
    /// （四枚各不相同，拖乱顺序不丢能力）。
    /// 设置子页排序（v7 顺序表模型）：把 index 项移动到目标位。destination
    /// 是"移除后"语义的插入位（与 SwiftUI onMove 一致：向下移动传 index+2）。
    /// 自实现而非 Array.move——那个扩展定义在 SwiftUI，本文件不引 UI 框架。
    func moveCapability(from index: Int, to destination: Int) {
        guard slots.indices.contains(index),
              destination >= 0, destination <= slots.count, destination != index else { return }
        let item = slots.remove(at: index)
        slots.insert(item, at: destination > index ? destination - 1 : destination)
    }

    /// 设置页「重置槽位」：回默认全能力顺序（V3 四枚在前）。
    func resetSlots() {
        slots = BallCapability.defaultOrder
    }

    /// 设置页「重置位置」：回默认左缘中点。Overlay 用 @AppStorage 读这两键，
    /// 写入即触发吸附弹簧动画。
    func resetPosition() {
        UserDefaults.standard.set("left", forKey: Self.edgeKey)
        UserDefaults.standard.set(0.5, forKey: Self.offsetKey)
    }

    /// 槽位触发入口（触盘按钮 + 拖拽投递共用）。动作收口一处。
    func perform(_ capability: BallCapability) {
        isExpanded = false
        switch capability {
        case .conversation:
            openAgentPanel()
        case .voice:
            voice.toggle()
        case .summarize:
            askAboutPage()
        case .whiteboard:
            openWhiteboard()
        case .screenshot:
            onScreenshot?()
        case .translate:
            onSendPrompt?("请阅读当前页面并把内容翻译成中文（若原文已是中文则译成英文），保留标题与结构。")
        case .plan:
            // 计划卡在 Agent 面板里——打开面板即达（面板会显示当前会话的计划）。
            openAgentPanel()
        case .customPrompt:
            let prompt = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { openAgentPanel(); return }
            onSendPrompt?(prompt)
        case .adClean:
            // AI 去广告：与 didFinish 自动清理/agent blockElements 同引擎。
            guard let tab = pageTabProvider?() else { flashToast("请先打开一个网页"); return }
            Task { @MainActor in
                let blocked = await BallQuickActions.cleanAds(on: tab)
                flashToast(blocked > 0
                           ? "AI 去广告：已拦截 \(blocked) 处"
                           : blocked == 0 ? "AI 去广告：没发现广告" : "AI 去广告：请先打开一个网页")
            }
        case .downloadPageVideo:
            guard let tab = pageTabProvider?() else { flashToast("请先打开一个网页"); return }
            flashToast(BallQuickActions.downloadPageVideo(on: tab))
        case .downloadAllVideos:
            guard let tab = pageTabProvider?() else { flashToast("请先打开一个网页"); return }
            Task { @MainActor in
                flashToast(await BallQuickActions.downloadAllVideos(on: tab))
            }
        case .readerMode:
            CommandBus.shared.send(.toggleReader)
        case .findInPage:
            CommandBus.shared.send(.toggleFind)
        case .bookmarkPage:
            CommandBus.shared.send(.bookmarkPage)
        }
    }

    /// 拖拽投递（v5）：松手先存待决载荷并弹动作选择——投递语义从
    /// "固定动作"升级为"带意图"。点选后才起回合；点外即弃。
    func deliverDrop(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isExpanded = false
        pendingDrop = trimmed
    }

    enum DropAction {
        case summarize, translate, ask
    }

    /// 待决载荷是不是 http(s) 链接（动作选择菜单的文案分叉）。
    var pendingDropIsURL: Bool {
        guard let raw = pendingDrop else { return false }
        return URL(string: raw)?.scheme?.hasPrefix("http") == true
    }

    func resolveDrop(_ action: DropAction) {
        guard let raw = pendingDrop else { return }
        pendingDrop = nil
        let isURL = URL(string: raw)?.scheme?.hasPrefix("http") == true
        let subject = isURL ? "这个链接（\(raw)）" : "下面这段选区内容：\n\(String(raw.prefix(2000)))"
        let prompt: String
        switch action {
        case .summarize:
            prompt = "请阅读并总结\(subject)的要点。"
        case .translate:
            prompt = "请阅读\(subject)并把内容翻译成中文（若原文已是中文则译成英文），保留标题与结构。"
        case .ask:
            prompt = isURL
                ? "请打开这个链接（\(raw)），读完后向我汇报页面上有什么。"
                : "请基于\(subject)回答我的问题。"
        }
        openAgentPanel()
        onSendPrompt?(prompt)
    }

    func cancelDrop() {
        pendingDrop = nil
    }

}
