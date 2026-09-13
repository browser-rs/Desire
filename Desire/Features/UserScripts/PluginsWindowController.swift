//
//  PluginsWindowController.swift
//  Desire
//
//  Created by mankong on 2026/7/5.
//

import AppKit
import SwiftUI

/// Singleton controller that owns the independent Plugins window.
///
/// Same imperative NSWindow pattern as `SettingsWindowController`: standard
/// titled window (not NSPanel), `isReleasedWhenClosed = false`, and a
/// `NSWindowWillCloseNotification` observer that clears the reference so the
/// next `show(...)` re-creates the window fresh.
@MainActor
final class PluginsWindowController {
    static let shared = PluginsWindowController()

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    private init() {}

    func show(pluginStore: PluginStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let view = PluginPanel(store: pluginStore)
        let hosting = NSHostingView(rootView: view)
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = String(localized: "Plugins")
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
            // The block is @Sendable, but `queue: .main` guarantees it runs
            // on the main thread — assert that and hop onto the actor so the
            // MainActor-isolated properties are legally reachable.
            MainActor.assumeIsolated {
                guard let self,
                      let closing = note.object as? NSWindow,
                      closing === self.window else { return }
                if let obs = self.closeObserver {
                    NotificationCenter.default.removeObserver(obs)
                    self.closeObserver = nil
                }
                self.window = nil
            }
        }

        window = newWindow
    }
}
