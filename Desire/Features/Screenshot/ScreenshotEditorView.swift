import SwiftUI
import AppKit

/// 截图编辑窗口（独立 NSWindow）。只展示图片 + Copy/Save/Cancel。
enum ScreenshotEditorPresenter {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?
    private static var onClose: (() -> Void)?

    @MainActor
    static func show(store: ScreenshotStore, onClose callback: @escaping () -> Void = {}) {
        hide()

        let view = ScreenshotEditorView(store: store)
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Screenshot"
        win.setContentSize(NSSize(width: 900, height: 640))
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.center()
        win.isReleasedWhenClosed = false

        onClose = callback
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { _ in
            // 先把回调清掉再调，避免 hide() 里又走一遍
            let cb = ScreenshotEditorPresenter.onClose
            ScreenshotEditorPresenter.onClose = nil
            ScreenshotEditorPresenter.window = nil
            ScreenshotEditorPresenter.closeObserver = nil
            cb?()
        }

        window = win
        win.makeKeyAndOrderFront(nil)
    }

    @MainActor
    static func hide() {
        if let obs = closeObserver {
            NotificationCenter.default.removeObserver(obs)
            closeObserver = nil
        }
        window?.orderOut(nil)
        window = nil
        onClose = nil
    }
}

struct ScreenshotEditorView: View {
    @ObservedObject var store: ScreenshotStore

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            canvas
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Cancel") { store.cancelCapture() }
                .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Copy") { store.copyToClipboard() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!isEditing)

            Button("Save") { store.save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!isEditing)
        }
        .padding(12)
    }

    private var canvas: some View {
        ZStack {
            Color.black
            if case .editing(let image) = store.phase {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
    }

    private var isEditing: Bool {
        if case .editing = store.phase { return true }
        return false
    }
}
