import AppKit
import Combine
import os
import SwiftUI

/// 全局悬浮球：非激活透明子面板贴浏览器窗口边缘，可拖动、点击展开
/// 操作条（对话 / 语音 / 总结本页 / 白板），语音转写自动发给 Agent。
///
/// 面板尺寸 = 可见内容尺寸（收起 52pt 球、展开 操作条+球）——不做"大面板
/// 透明区 + hitTest 穿透"：SwiftUI 内容在 NSHostingView 里 hitTest 恒返回
/// hosting view 自身，按"命中自身=穿透"的写法会把球的手势一起穿透
/// （一期实测：点击没反应、无法拖动）。
@MainActor
final class AgentBallPanel: ObservableObject {
    static let shared = AgentBallPanel()

    private var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    private var parentObservers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    @Published var isExpanded = false {
        didSet {
            guard oldValue != isExpanded else { return }
            applyLayout(animated: true)
        }
    }
    @Published private(set) var isEnabled: Bool
    /// 活跃会话的 Agent 正在处理（球上进度环）。
    @Published private(set) var agentBusy = false
    /// 页面元素全屏（视频等）时球自动让位——退出后恢复。
    @Published private(set) var hiddenForFullscreen = false
    let voice = VoiceInputManager()
    @Published var voiceTranscriptSent: String?

    /// 宿主注入的动作（ContentView 提供——AI 会话与窗口绑定在那边）。
    var onOpenAgentPanel: (() -> Void)?
    var onAskAboutPage: (() -> Void)?
    var onPageURL: (() -> String?)?
    /// 当前标签是否处于元素全屏（视频等）——球自动让位。
    var onPageFullscreen: (() -> Bool)?

    static let enabledChangedNotification = Notification.Name("agentBall.enabledChanged")
    static let edgeKey = "agentBall.edge"
    static let offsetKey = "agentBall.offset"
    static let enabledKey = "agentBall.enabled"
    static let sizeKey = "agentBall.size"
    /// 无活跃 agent 会话时的兜底键（.board 导入/手动创作都落这里）。
    static let defaultKey = "__default"
    private weak var lastParent: NSWindow?
    private var pollTimer: Timer?

    private func resolved(_ id: String?) -> String { id ?? Self.defaultKey }

    /// 设置页/菜单的全局开关（各窗口经 enabledChanged 通知跟随）。
    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on, let parent = activeParent() {
            attach(to: parent)
        } else if !on {
            detach()
        }
        NotificationCenter.default.post(name: Self.enabledChangedNotification, object: nil)
    }

    var conversationID: String? {
        AgentScheduler.shared.deliveryTarget?.conversationId?.uuidString
    }

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

        // 感知轮询（2s）：Agent 忙碌（进度环）+ 页面全屏（球让位）。
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// 供设置页/挂载使用的目标父窗口：最后挂载的浏览器窗口 → key window
    /// → 任一可见的浏览器主窗。
    func activeParent() -> NSWindow? {
        if let p = lastParent, p.isVisible { return p }
        if let key = NSApp.keyWindow, key.isVisible { return key }
        return NSApp.windows.first(where: {
            $0.isVisible && ($0.styleMask.contains(.titled) || $0.styleMask.contains(.fullSizeContentView))
        })
    }

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
        lastParent = parent
        positionAtSavedEdge()
        panel?.orderFront(nil)
        observeParentFrame()
        poll()
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
        if wasVisible, sameParent {
            detach()
            isEnabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
        } else {
            attach(to: parent)
            isEnabled = true
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        }
    }

    func refreshContent() {
        guard let panel else { return }
        panel.contentView = AgentBallHostingView(rootView: AgentBallView(panel: self, voice: voice))
    }

    private func makePanel() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.collapsedSize),
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

    private func poll() {
        guard isVisible else { return }
        let busy = AgentScheduler.shared.deliveryTarget?.isProcessing ?? false
        if busy != agentBusy { agentBusy = busy }

        let inFS = onPageFullscreen?() ?? false
        if inFS, !hiddenForFullscreen, isVisible {
            hiddenForFullscreen = true
            panel?.orderOut(nil)
        } else if !inFS, hiddenForFullscreen {
            hiddenForFullscreen = false
            if isEnabled { panel?.orderFront(nil) }
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - 尺寸与布局

    static let ballSize: CGFloat = 52
    static var collapsedSize: NSSize {
        NSSize(width: ballDiameter, height: ballDiameter)
    }
    /// 球径（设置页档位 44/52/60）。
    static var ballDiameter: CGFloat {
        let v = UserDefaults.standard.double(forKey: sizeKey)
        return (44...60).contains(v) ? v : 52
    }
    /// 展开态：操作条卡（约 170pt 高）叠在球上方，左右各留 6pt。
    static var expandedSize: NSSize {
        NSSize(width: max(236, ballDiameter + 184),
               height: ballDiameter + 190)
    }

    /// 面板 frame 随展开/收起重排，**球的外缘保持不动**（贴边侧固定，
    /// 向非贴边方向与上方伸缩）。
    func applyLayout(animated: Bool) {
        guard let panel, let parent = parentWindow else { return }
        let edge = UserDefaults.standard.string(forKey: Self.edgeKey) ?? "left"
        let newSize = isExpanded ? Self.expandedSize : Self.collapsedSize
        let oldFrame = panel.frame
        var newOrigin = oldFrame.origin
        if edge == "right" {
            newOrigin.x = oldFrame.maxX - newSize.width
        }
        let target = NSRect(origin: newOrigin, size: newSize)
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(target, display: true)
            })
        } else {
            panel.setFrame(target, display: false)
        }
        clampToParent()
    }

    // MARK: - 位置（吸附左右边缘 + 纵向偏移比例持久化）

    func positionAtSavedEdge() {
        guard let panel, let parent = parentWindow else { return }
        let edge = UserDefaults.standard.string(forKey: Self.edgeKey) ?? "left"
        let fraction = UserDefaults.standard.double(forKey: Self.offsetKey)
        let width = panel.frame.width
        let x: CGFloat = (edge == "left")
            ? parent.frame.minX + 6
            : parent.frame.maxX - width - 6
        let travel = max(0, parent.frame.height - panel.frame.height - 20)
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
        if isExpanded { isExpanded = false }  // 收起 → 面板回到球尺寸再吸附
        let toLeft = panel.frame.midX < parent.frame.midX
        let targetX = toLeft ? parent.frame.minX + 6 : parent.frame.maxX - panel.frame.width - 6
        let targetY = panel.frame.origin.y

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(NSRect(origin: NSPoint(x: targetX, y: targetY),
                                             size: panel.frame.size), display: true)
        }, completionHandler: nil)

        UserDefaults.standard.set(toLeft ? "left" : "right", forKey: Self.edgeKey)
        let travel = max(1, parent.frame.height - panel.frame.height - 20)
        UserDefaults.standard.set((targetY - parent.frame.minY - 10) / travel, forKey: Self.offsetKey)
    }

    /// 重置位置：左缘中点（默认位）。
    func resetPosition() {
        UserDefaults.standard.set("left", forKey: Self.edgeKey)
        UserDefaults.standard.set(0.5, forKey: Self.offsetKey)
        positionAtSavedEdge()
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
        applyLayout(animated: true)
    }

    func askAboutPage() {
        onAskAboutPage?()
        isExpanded = false
        applyLayout(animated: true)
    }

    func openWhiteboard() {
        WhiteboardPanel.shared.show()
        isExpanded = false
        applyLayout(animated: true)
    }
}

/// 透明面板命中穿透：球/操作条以外的区域让点击落到下层网页。
/// SwiftUI 内容的 hitTest 恒返回 hosting view 自身（无 AppKit 子视图），
/// 所以用 **鼠标点位的几何判断**（球圆 + 展开卡片矩形）而不是子视图比对。
final class AgentBallHostingView: NSHostingView<AgentBallView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let w = bounds.width
        // 球：贴边侧的底部圆（收起态整个面板就是球）
        let ballRadius = AgentBallPanel.ballDiameter / 2 + 4
        let ballCenter = NSPoint(x: AgentBallPanel.ballDiameter / 2, y: AgentBallPanel.ballDiameter / 2)
        let dx = point.x - ballCenter.x
        let dy = point.y - ballCenter.y
        if dx * dx + dy * dy <= ballRadius * ballRadius { return super.hitTest(point) }
        // 展开卡片区域（球上方，宽 = 面板宽 - 24）
        let cardLeft: CGFloat = 12
        let cardRight = w - 12
        let cardTop = bounds.height - 6
        let cardBottom = AgentBallPanel.ballDiameter + 4
        if point.x >= cardLeft, point.x <= cardRight, point.y >= cardBottom, point.y <= cardTop {
            return super.hitTest(point)
        }
        return nil  // 透明区穿透
    }
}
