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
        panel.minSize = NSSize(width: 320, height: 480)

        // Capture only the stores, not self — the window holds the content
        // closure forever, so a `self` capture would pin the whole panel
        // object (window → contentViewController → closure → self → window).
        let store = self.store
        let conversationStore = self.conversationStore
        let hostingController = NSHostingController(
            rootView: AgentPanel(store: store, conversationStore: conversationStore)
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

    func hide() {
        window?.orderOut(nil)
    }

    func cleanup() {
        window?.close()
        window = nil
    }
}