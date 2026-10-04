//
//  ScreenshotSession.swift
//  Desire
//
//  Created by mankong on 2026/7/5.
//

import AppKit

/// Borderless panel subclass that can become the key window.
///
/// `NSPanel` with `[.borderless, .fullSizeContentView]` returns `false` for
/// `canBecomeKey` by default — without overriding it, `makeFirstResponder`
/// silently fails and keyboard input (text annotation field, Cmd+Z undo, Esc
/// cancel) never reaches the overlay.
final class ScreenshotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Orchestrator for the screenshot flow: permission check → screen capture → overlay → result.
/// Caseless namespace (per Plan agent S4). Holds session state in a private `Holder`.
enum ScreenshotSession {
    private final class Holder {
        weak var panel: NSPanel?
        var browserKeyWindow: NSWindow?
    }
    private static let holder = Holder()

    @MainActor
    static func start(
        saveFolder: URL,
        onResult: @escaping (ScreenshotResult) -> Void
    ) {
        // Permission: preflight first; if missing, request and prompt (permission
        // only takes effect on the next launch, so we never capture immediately
        // after a fresh grant — that would yield a black image).
        guard ScreenshotCapture.hasPermission else {
            let granted = ScreenshotCapture.requestPermission()
            if granted {
                showAlert(
                    title: String(localized: "Screenshot"),
                    message: String(localized: "Permission granted. Trigger the screenshot shortcut again to capture."),
                    buttonTitle: String(localized: "OK")
                )
            } else {
                showAlert(
                    title: String(localized: "Screenshot"),
                    message: String(localized: "Screen Recording permission is required. Open System Settings → Privacy & Security → Screen Recording."),
                    buttonTitle: String(localized: "Open Settings")
                ) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            return
        }

        // 3) Target screen: the one containing the browser key window.
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            onResult(.cancelled)
            return
        }

        // 4) Capture the screen async, then show the overlay on the main actor.
        holder.browserKeyWindow = NSApp.keyWindow
        Task {
            guard let image = await ScreenshotCapture.captureScreen(screen) else {
                await MainActor.run { onResult(.cancelled) }
                return
            }
            await MainActor.run { showOverlay(image: image, on: screen, saveFolder: saveFolder, onResult: onResult) }
        }
    }

    @MainActor
    private static func showOverlay(
        image: NSImage,
        on screen: NSScreen,
        saveFolder: URL,
        onResult: @escaping (ScreenshotResult) -> Void
    ) {
        let panel = ScreenshotPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        let view = ScreenshotOverlayView(frame: screen.frame, capturedImage: image, saveFolder: saveFolder)
        view.onResult = { result in
            end(result, panel: panel, onResult: onResult)
        }
        panel.contentView = view
        panel.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)

        holder.panel = panel
    }

    @MainActor
    private static func end(_ result: ScreenshotResult, panel: NSPanel, onResult: @escaping (ScreenshotResult) -> Void) {
        panel.orderOut(nil)
        // Restore the browser window as key so Cmd+L / Cmd+T / Cmd+R work after the session.
        holder.browserKeyWindow?.makeKey()
        holder.browserKeyWindow = nil
        onResult(result)
    }

    @MainActor
    private static func showAlert(title: String, message: String, buttonTitle: String, onOk: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: buttonTitle)
        alert.runModal()
        onOk?()
    }
}
