import AppKit
import Combine
import os
import SwiftUI

/// 全局悬浮球（一期）：跟随浏览器窗口的小圆球，可拖动、自动吸附窗口
/// 左右边缘，点击展开常用 Agent 操作（对话 / 语音 / 总结本页 / 白板）。
/// 语音 = 球上直接说话，转写完成后自动发给当前会话的 Agent。
@MainActor
final class AgentBallPanel: ObservableObject {
    static let shared = AgentBallPanel()

    private var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    private var parentObservers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    @Published var isExpanded = false
    let voice = VoiceInputManager()
    @Published var voiceTranscriptSent: String?

    /// 宿主注入的动作（ContentView 提供——AI 会话与窗口绑定在那边）。
    var onOpenAgentPanel: (() -> Void)?
    var onAskAboutPage: (() -> Void)?
    var onPageURL: (() -> String?)?

    static let edgeKey = "agentBall.edge"
    static let offsetKey = "agentBall.offset"
    static let enabledKey = "agentBall.enabled"

    var conversationID: String? {
        AgentScheduler.shared.deliveryTarget?.conversationId?.uuidString
    }

    private init() {
        // 语音：录音停止且转写非空 → 自动发给 Agent 并打开面板
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
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 挂到浏览器窗口（child window：随父窗口移动、置顶于父）。
    func attach(to parent: NSWindow) {
        if panel == nil {
            makePanel()
        }
        if parentWindow !== parent {
            parentWindow?.removeChildWindow(panel!)
            parent.addChildWindow(panel!, ordered: .above)
            parentWindow = parent
        }
        positionAtSavedEdge()
        panel?.orderFront(nil)
        observeParentFrame()
    }

    func detach() {
        parentWindow?.removeChildWindow(panel!)
        panel?.orderOut(nil)
        parentObservers.forEach { NotificationCenter.default.removeObserver($0) }
        parentObservers.removeAll()
    }

    func toggle(in parent: NSWindow) {
        let wasVisible = isVisible
        let sameParent = parentWindow === parent
        Log.agent.info("AgentBall toggle: visible=\(wasVisible, privacy: .public) sameParent=\(sameParent, privacy: .public)")
        if wasVisible, sameParent {
            detach()
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
        } else {
            attach(to: parent)
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        }
    }

    /// 白板面板 / 编辑等场景把内容控制器换成新的时复用。
    private func makePanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 52, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        let hosting = AgentBallHostingView(rootView: AgentBallView(panel: self, voice: voice))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
    }

    // MARK: - 位置（吸附左右边缘 + 纵向偏移比例持久化）

    func positionAtSavedEdge() {
        guard let panel, let parent = parentWindow else { return }
        let edge = UserDefaults.standard.string(forKey: Self.edgeKey) ?? "left"
        let fraction = UserDefaults.standard.double(forKey: Self.offsetKey)
        let ballSize: CGFloat = 52
        let x: CGFloat = (edge == "left")
            ? parent.frame.minX + 6
            : parent.frame.maxX - ballSize - 6
        let travel = max(0, parent.frame.height - ballSize - 20)
        let y = parent.frame.minY + 10 + travel * min(max(fraction, 0), 1)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// 拖动中：跟随手指（限制在父窗口范围内）。
    func moveBy(dx: CGFloat, dy: CGFloat) {
        guard let panel, let parent = parentWindow else { return }
        var origin = panel.frame.origin
        origin.x = min(max(origin.x + dx, parent.frame.minX + 4), parent.frame.maxX - panel.frame.width - 4)
        origin.y = min(max(origin.y + dy, parent.frame.minY + 4), parent.frame.maxY - panel.frame.height - 4)
        panel.setFrameOrigin(origin)
    }

    /// 松手：吸附到最近的左右边缘（缓出动画），记录纵向偏移比例。
    func snapToEdge() {
        guard let panel, let parent = parentWindow else { return }
        let toLeft = panel.frame.midX < parent.frame.midX
        let ballSize: CGFloat = 52
        let targetX = toLeft ? parent.frame.minX + 6 : parent.frame.maxX - ballSize - 6
        let targetY = panel.frame.origin.y

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(NSRect(origin: NSPoint(x: targetX, y: targetY),
                                             size: panel.frame.size), display: true)
        }, completionHandler: nil)

        UserDefaults.standard.set(toLeft ? "left" : "right", forKey: Self.edgeKey)
        let travel = max(1, parent.frame.height - ballSize - 20)
        UserDefaults.standard.set((targetY - parent.frame.minY - 10) / travel, forKey: Self.offsetKey)
    }

    /// 父窗口缩放后把球夹回范围内（child window 只跟随移动）。
    func clampToParent() {
        guard let panel, let parent = parentWindow, panel.isVisible else { return }
        var origin = panel.frame.origin
        origin.x = min(max(origin.x, parent.frame.minX + 4), parent.frame.maxX - panel.frame.width - 4)
        origin.y = min(max(origin.y, parent.frame.minY + 4), parent.frame.maxY - panel.frame.height - 4)
        panel.setFrameOrigin(origin)
    }

    private func observeParentFrame() {
        guard let parent = parentWindow else { return }
        parentObservers.forEach { NotificationCenter.default.removeObserver($0) }
        parentObservers.removeAll()
        parentObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: parent, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.clampToParent() }
        })
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
