//
//  SettingsView.swift
//  Desire
//
//  Created by mankong on 2026/7/5.
//

import SwiftUI

/// Modern two-column Settings window content (System Settings.app style).
///
/// Replaces the old 4-tab `TabView` with a `NavigationSplitView`: sidebar
/// lists the sections, detail area shows the selected section's `Form`.
/// Designed to be hosted in an independent `NSWindow` (see
/// `SettingsWindowController`), so it has no `onDone` callback or fixed frame —
/// the window's traffic-light close button is the only way out.
struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general
        case privacy
        case autofill
        case keyboardShortcuts

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .privacy: "hand.raised"
            case .autofill: "doc.text.fill"
            case .keyboardShortcuts: "keyboard"
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .general: "General"
            case .privacy: "Privacy"
            case .autofill: "Autofill"
            case .keyboardShortcuts: "Keyboard Shortcuts"
            }
        }
    }

    @ObservedObject var settings: Settings
    @ObservedObject var contentBlocker: ContentBlocker
    @ObservedObject var downloadStore: DownloadStore
    @ObservedObject var formAutofillStore: FormAutofillStore
    @ObservedObject var permissionStore: PermissionStore
    @ObservedObject var historyStore: HistoryStore

    @State private var selectedSection: Section = .general

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .listStyle(.sidebar)
        } detail: {
            switch selectedSection {
            case .general:
                GeneralSettingsSection(settings: settings, downloadStore: downloadStore)
            case .privacy:
                PrivacySettingsSection(
                    settings: settings,
                    contentBlocker: contentBlocker,
                    permissionStore: permissionStore,
                    historyStore: historyStore
                )
            case .autofill:
                FormAutofillSettingsView(store: formAutofillStore)
            case .keyboardShortcuts:
                KeyboardShortcutsView()
            }
        }
        .frame(minWidth: 600, minHeight: 420)
    }
}

private struct KeyboardShortcutsView: View {
    private let shortcuts: [(String, LocalizedStringKey)] = [
        ("⌘T", "New Tab"),
        ("⌘⇧N", "New Incognito Tab"),
        ("⌘W", "Close Tab"),
        ("⌘⇧T", "Reopen Closed Tab"),
        ("⌘{", "Previous Tab"),
        ("⌘}", "Next Tab"),
        ("⌘1-9", "Switch to Tab 1-9"),
        ("⌘L", "Focus Address Bar"),
        ("⌘R", "Reload Page"),
        ("⌘F", "Find in Page"),
        ("⌘G", "Find Next"),
        ("⌘⇧G", "Find Previous"),
        ("Esc", "Exit Find"),
        ("⌘[", "Go Back"),
        ("⌘]", "Go Forward"),
        ("⌘=", "Zoom In"),
        ("⌘-", "Zoom Out"),
        ("⌘0", "Reset Zoom"),
        ("⌘⇧I", "Inspect Element"),
        ("⌘P", "Print"),
        ("⌘Y", "Browsing History"),
        ("⌘⇧A", "Search Tabs"),
        ("⌘⇧B", "Sidebar"),
        ("⌘⇧M", "Responsive Design Mode"),
    ]

    var body: some View {
        List(shortcuts, id: \.0) { shortcut in
            HStack {
                Text(shortcut.0)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(shortcut.1)
            }
        }
        .padding()
    }
}
