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
    @Published var isExpanded = false
    /// 活跃会话的 Agent 正在处理（球上进度环）。
    @Published private(set) var agentBusy = false
    /// Agent 回复完成提醒（busy 下降沿触发，数秒后自动消失）。
    @Published private(set) var replyFlash = false
    /// 页面元素全屏（视频等）时球让位——覆盖层会压在全屏内容上。
    @Published private(set) var hiddenForFullscreen = false
    let voice = VoiceInputManager()
    @Published var voiceTranscriptSent: String?

    /// 宿主注入的动作（ContentView 提供——AI 会话与窗口绑定在那边）。
    var onOpenAgentPanel: (() -> Void)?
    var onAskAboutPage: (() -> Void)?
    /// 当前标签是否处于元素全屏（视频等）——球自动让位。
    var onPageFullscreen: (() -> Bool)?

    static let enabledChangedNotification = Notification.Name("agentBall.enabledChanged")
    static let edgeKey = "agentBall.edge"
    static let offsetKey = "agentBall.offset"
    static let enabledKey = "agentBall.enabled"
    static let sizeKey = "agentBall.size"

    var conversationID: String? {
        AgentScheduler.shared.deliveryTarget?.conversationId?.uuidString
    }

    private var cancellables: Set<AnyCancellable> = []
    private var pollTimer: Timer?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
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
        if busy != agentBusy { agentBusy = busy }
        if agentBusy, !busy {
            replyFlash = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self.replyFlash = false
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
