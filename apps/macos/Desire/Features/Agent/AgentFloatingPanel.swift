import AppKit
import SwiftUI

@MainActor
class AgentFloatingPanel {
    private var window: NSWindow?
    private let store: AgentSessionStore
    private let conversationStore: ConversationStore
    /// 独立窗口的强调色（见 AppAccent.swift）。
    let accentColor: Color

    init(store: AgentSessionStore, conversationStore: ConversationStore, accentColor: Color) {
        self.store = store
        self.conversationStore = conversationStore
        self.accentColor = accentColor
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() }
        else { show() }
    }

    func show() {
        // Same resume-on-open behavior as the sidebar panel: a fresh
        // session picks up the most recent conversation.
        store.resumeLatestConversation()
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Agent"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 两栏布局：侧栏展开态需要更宽的窗口下限（存档状态决定初始 minSize，
        // 必须在 frame 还原前设置——还原时按 minSize 钳制）。
        let sidebarExpanded = UserDefaults.standard.bool(forKey: AgentWindowRoot.sidebarKey)
        panel.minSize = NSSize(width: sidebarExpanded ? 560 : 320, height: 480)

        // Capture only the stores, not self — the window holds the content
        // closure forever, so a `self` capture would pin the whole panel
        // object (window → contentViewController → closure → self → window).
        let store = self.store
        let conversationStore = self.conversationStore
        let hostingController = NSHostingController(
            rootView: AgentWindowRoot(
                store: store,
                conversationStore: conversationStore,
                onToggleWhiteboard: { WhiteboardPanel.shared.toggle() },
                onToggleBall: { AgentBallPanel.shared.toggle() },
                onSidebarVisibilityChanged: { [weak panel] expanded in
                    guard let panel else { return }
                    Self.applySidebarWindowMetrics(panel, expanded: expanded)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 独立窗口：ContentView 的强调色注入不跨窗口（见 AppAccent.swift）。
            .appAccent(accentColor)
        )
        panel.contentViewController = hostingController

        panel.setFrameAutosaveName("AgentFloatingPanel")
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.window = panel
    }

    /// 两栏窗口的宽度闸：展开侧栏时窗口必须容得下（190 侧栏 + 可用聊天列
    /// ≈ 560）；收起时还原窄窗下限。展开瞬间窗口过窄则就地放宽（动画），
    /// 否则侧栏会把聊天列挤成一条缝。
    private static func applySidebarWindowMetrics(_ panel: NSPanel, expanded: Bool) {
        let minWidth: CGFloat = expanded ? 560 : 320
        panel.minSize = NSSize(width: minWidth, height: 480)
        if expanded, panel.frame.width < minWidth {
            var frame = panel.frame
            frame.size.width = minWidth
            panel.setFrame(frame, display: true, animate: true)
        }
    }

    func hide() {
        window?.orderOut(nil)
    }

    func cleanup() {
        window?.close()
        window = nil
    }
}