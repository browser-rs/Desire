import AppKit
import SwiftUI

struct WindowChromeGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.protect(window: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private var observations: [NSKeyValueObservation] = []

        func protect(window: NSWindow) {
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
