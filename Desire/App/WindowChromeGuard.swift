import AppKit
import SwiftUI

struct WindowChromeGuard: NSViewRepresentable {
    /// Fired on the host window's every `didBecomeKey`. Used to re-bind
    /// per-window state (the AI tool surface's TabManager) so the agent and
    /// window-scoped tools always target the ACTIVE window.
    var onBecomeKey: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.protect(window: window, onBecomeKey: onBecomeKey)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private var observations: [NSKeyValueObservation] = []
        private var keyObserver: NSObjectProtocol?

        func protect(window: NSWindow, onBecomeKey: (() -> Void)?) {
            applyChrome(window)

            observations.append(
                window.observe(\.titlebarAppearsTransparent, options: [.new]) { [weak self] wv, _ in
                    DispatchQueue.main.async { self?.applyChrome(wv) }
                }
            )
            observations.append(
                window.observe(\.styleMask, options: [.new]) { [weak self] wv, _ in
                    DispatchQueue.main.async { self?.applyChrome(wv) }
                }
            )
            observations.append(
                window.observe(\.titleVisibility, options: [.new]) { [weak self] wv, _ in
                    DispatchQueue.main.async { self?.applyChrome(wv) }
                }
            )

            if let onBecomeKey {
                keyObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    onBecomeKey()
                }
            }
        }

        func teardown() {
            if let observer = keyObserver {
                NotificationCenter.default.removeObserver(observer)
                keyObserver = nil
            }
            observations.removeAll()
        }

        private func applyChrome(_ window: NSWindow) {
            if !window.titlebarAppearsTransparent {
                window.titlebarAppearsTransparent = true
            }
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            if window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
            }
            if !window.title.isEmpty {
                window.title = ""
            }
        }
    }
}
