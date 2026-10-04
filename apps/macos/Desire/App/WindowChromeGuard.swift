import AppKit
import SwiftUI

struct WindowChromeGuard: NSViewRepresentable {
    /// Fired on the host window's every `didBecomeKey`. Used to re-bind
    /// per-window state (the AI tool surface's TabManager) so the agent and
    /// window-scoped tools always target the ACTIVE window.
    /// Fired once the host window resolves — lets the view scope app-wide
    /// command broadcasts to the KEY window only.
    var onWindow: ((NSWindow) -> Void)? = nil
    var onBecomeKey: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            onWindow?(window)
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
        private weak var protectedWindow: NSWindow?
        /// True while a fullscreen enter/exit ANIMATION is running. macOS
        /// intentionally strips .fullSizeContentView mid-transition; our
        /// styleMask observer must NOT put it back during that window or
        /// the layout jumps mid-animation (visible tearing).
        private var inFullscreenTransition = false
        private var fullscreenObservers: [NSObjectProtocol] = []

        func protect(window: NSWindow, onBecomeKey: (() -> Void)?) {
            protectedWindow = window
            let center = NotificationCenter.default
            fullscreenObservers.append(center.addObserver(
                forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main
            ) { [weak self] _ in self?.inFullscreenTransition = true })
            fullscreenObservers.append(center.addObserver(
                forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main
            ) { [weak self] _ in self?.inFullscreenTransition = true })
            fullscreenObservers.append(center.addObserver(
                forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
            ) { [weak self] _ in self?.inFullscreenTransition = false })
            fullscreenObservers.append(center.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.inFullscreenTransition = false
                if let w = self?.protectedWindow { self?.applyChrome(w) }
            })

            applyChrome(window)

            observations.append(
                window.observe(\.titlebarAppearsTransparent, options: [.new]) { [weak self] wv, _ in
                    DispatchQueue.main.async { self?.applyChrome(wv) }
                }
            )
            observations.append(
                window.observe(\.styleMask, options: [.new]) { [weak self] wv, _ in
                    DispatchQueue.main.async {
                        guard self?.inFullscreenTransition != true else { return }
                        self?.applyChrome(wv)
                    }
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
            fullscreenObservers.forEach { NotificationCenter.default.removeObserver($0) }
            fullscreenObservers.removeAll()
            observations.removeAll()
        }

        private func applyChrome(_ window: NSWindow) {
            // Mid-transition the mask is the SYSTEM's business; re-applying
            // here is what caused the fullscreen tearing. The didExit
            // handler re-runs this once the animation has settled.
            if inFullscreenTransition || window.styleMask.contains(.fullScreen) {
                return
            }
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
