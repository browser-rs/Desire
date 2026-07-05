//
//  SettingsWindowController.swift
//  Desire
//
//  Created by mankong on 2026/7/5.
//

import AppKit
import SwiftUI

/// Singleton controller that owns the independent Settings window.
///
/// Mirrors the imperative NSWindow pattern from `ScreenshotSession`, but uses
/// `NSWindow` (not `NSPanel`) since Settings is a standard titled window — not
/// a floating utility panel — so it doesn't need a `canBecomeKey` override.
///
/// `isReleasedWhenClosed = false` keeps the closed NSWindow alive in memory
/// (held by this controller); the `NSWindowWillCloseNotification` observer
/// clears the `window` reference so the next `show(...)` re-creates it.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    private init() {}

    func show(
        settings: Settings,
        aiPreference: AIPreferenceStore,
        contentBlocker: ContentBlocker,
        downloadStore: DownloadStore,
        formAutofillStore: FormAutofillStore,
        permissionStore: PermissionStore,
        historyStore: HistoryStore
    ) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let view = SettingsView(
            settings: settings,
            aiPreference: aiPreference,
            contentBlocker: contentBlocker,
            downloadStore: downloadStore,
            formAutofillStore: formAutofillStore,
            permissionStore: permissionStore,
            historyStore: historyStore
        )
        let hosting = NSHostingView(rootView: view)
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = String(localized: "Settings")
        newWindow.contentView = hosting
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: newWindow,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let closing = note.object as? NSWindow,
                  closing === self.window else { return }
            if let obs = self.closeObserver {
                NotificationCenter.default.removeObserver(obs)
                self.closeObserver = nil
            }
            self.window = nil
        }

        window = newWindow
    }
}
