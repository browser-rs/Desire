import AppKit
import SwiftUI
import WebKit

/// 混合模式的 Peek 浮层（v0.8.24）：**非激活面板** + 定时页面快照。
///
/// 目的：Agent 需要人（登录/验证码/确认现场）时，让用户"看一眼再决定"，
/// 但默认不把焦点从用户手里抢走——面板 `.nonactivatingPanel` 不成为 key，
/// 只有"去处理"才激活 Agent 窗口。
///
/// 快照是 `takeSnapshot`（静态帧），**不是**把 webview 搬进面板——跨窗口
/// reparent 会出帧问题（设计稿硬约束）。
@MainActor
final class PeekOverlayController {
    static let shared = PeekOverlayController()

    private var panel: NSPanel?
    private var host: NSHostingView<PeekOverlayContent>?
    private var timer: Timer?
    private var snapshot: NSImage?

    private init() {}

    func show() {
        guard let manager = PeekCenter.shared.targetManager else { return }
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            self.panel = panel
        }
        refreshSnapshot(for: manager)
        rebuildContent(reason: PeekCenter.shared.active?.reason ?? "")
        position()
        panel?.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let manager = PeekCenter.shared.targetManager else { return }
                self.refreshSnapshot(for: manager)
                self.rebuildContent(reason: PeekCenter.shared.active?.reason ?? "")
            }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func refreshSnapshot(for manager: TabManager) {
        guard let webView = manager.selectedTab?.browser.webView else {
            snapshot = nil
            return
        }
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            Task { @MainActor in
                self?.snapshot = image
                self?.rebuildContent(reason: PeekCenter.shared.active?.reason ?? "")
            }
        }
    }

    private func rebuildContent(reason: String) {
        let content = PeekOverlayContent(
            reason: reason,
            snapshot: snapshot,
            onGoHandle: { [weak self] in
                self?.goHandle()
            },
            onDone: { PeekCenter.shared.resolve(completed: true) },
            onDismiss: { PeekCenter.shared.resolve(completed: false) })
        if let host {
            host.rootView = content
        } else if let panel {
            let host = NSHostingView(rootView: content)
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            self.host = host
        }
    }

    private func goHandle() {
        guard let manager = PeekCenter.shared.targetManager else { return }
        let window = WindowSurfaceRegistry.shared.window(for: manager.sessionKey)
            ?? manager.selectedTab?.browser.webView.window
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // 浮层保留（"完成"还要点），但挪到右上角避免挡住操作区。
        position()
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 24,
                                     y: frame.maxY - size.height - 24))
    }
}

/// 浮层内容：快照 + 原因 + 三个动作。
private struct PeekOverlayContent: View {
    @Environment(\.appAccent) private var appAccent: Color
    let reason: String
    let snapshot: NSImage?
    let onGoHandle: () -> Void
    let onDone: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appAccent)
                Text(String(localized: "Agent needs your help"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Group {
                if let snapshot {
                    Image(nsImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ZStack {
                        Color.secondary.opacity(0.08)
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 8) {
                Button(String(localized: "Go Handle"), action: onGoHandle)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Spacer()
                Button(String(localized: "Dismiss"), action: onDismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(String(localized: "Done"), action: onDone)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
    }
}
