import SwiftUI
import AppKit

@MainActor
class AIFloatingPanel {
    private var window: NSWindow?
    private let store: AISessionStore

    init(store: AISessionStore) {
        self.store = store
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() }
        else { show() }
    }

    func show() {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 500),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "AI Assistant"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: AIPanel(store: store))
        panel.setFrameAutosaveName("AIFloatingPanel")
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
