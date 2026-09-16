import AppKit
import SwiftUI

@MainActor
class AgentFloatingPanel {
    private var window: NSWindow?
    private let store: AgentSessionStore
    private let conversationStore: ConversationStore

    init(store: AgentSessionStore, conversationStore: ConversationStore) {
        self.store = store
        self.conversationStore = conversationStore
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

        let hostingController = NSHostingController(
            rootView: GeometryReader { _ in
                AgentPanel(store: self.store, conversationStore: self.conversationStore)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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