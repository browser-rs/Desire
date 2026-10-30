import AppKit
import SwiftUI

/// 观察"本视图所在窗口即将关闭"（v0.8.24）：视图销毁不区分"切标签"与"关窗"，
/// 而模式降级只在真正关窗时发生。只转发，不拦截关闭。
struct WindowCloseObserver: NSViewRepresentable {
    let onClose: (NSWindow) -> Void

    final class Coordinator {
        var token: NSObjectProtocol?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.token = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main) { note in
                    guard let closed = note.object as? NSWindow else { return }
                    Task { @MainActor in onClose(closed) }
                }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let token = coordinator.token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
