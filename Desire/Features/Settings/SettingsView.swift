//
//  SettingsView.swift
//  Desire
//
//  Created by mankong on 2026/7/5.
//

import Combine
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
        case ai
        case privacy
        case autofill
        case keyboardShortcuts

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .ai: "brain.head.profile"
            case .privacy: "hand.raised"
            case .autofill: "doc.text.fill"
            case .keyboardShortcuts: "keyboard"
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .general: "General"
            case .ai: "AI"
            case .privacy: "Privacy"
            case .autofill: "Autofill"
            case .keyboardShortcuts: "Keyboard Shortcuts"
            }
        }
    }

    @ObservedObject var settings: Settings
    @ObservedObject var aiPreference: AIPreferenceStore
    @ObservedObject var contentBlocker: ContentBlockerStore
    @ObservedObject var downloadStore: DownloadStore
    @ObservedObject var formAutofillStore: FormAutofillStore
    @ObservedObject var permissionStore: PermissionStore
    @ObservedObject var historyStore: HistoryStore
    @ObservedObject var privacyModeStore: PrivacyModeStore

    @State private var selectedSection: Section = .general

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.icon)
                    .labelStyle(.titleAndIcon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .navigationSplitViewStyle(.balanced)
            .listStyle(.sidebar)
        } detail: {
            switch selectedSection {
            case .general:
                GeneralSettingsSection(settings: settings, downloadStore: downloadStore)
            case .ai:
                AISettingsSection(store: aiPreference)
            case .privacy:
                PrivacySettingsStoreSection(
                    settings: settings,
                    contentBlocker: contentBlocker,
                    permissionStore: permissionStore,
                    historyStore: historyStore,
                    privacyModeStore: privacyModeStore
                )
            case .autofill:
                FormAutofillSettingsView(store: formAutofillStore)
            case .keyboardShortcuts:
                KeyboardShortcutsEditorView()
            }
        }
    }
}

private struct KeyboardShortcutsEditorView: View {
    @StateObject private var store = KeyboardShortcutStore()
    @State private var editing: ShortcutMapping?
    @State private var showRecorder = false
    @State private var showConflict = false
    @State private var conflicts: [ShortcutMapping] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Keyboard Shortcuts").font(.headline)

                if store.filteredShortcuts.count != store.shortcuts.count {
                    Text("\(store.filteredShortcuts.count) of \(store.shortcuts.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Capsule())
                }

                Spacer()

                Button("Reset All") { store.resetAll() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Search and filters
            HStack(spacing: 8) {
                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search Shortcuts…", text: $store.searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Category filter
                Menu {
                    Button("All Categories") { store.selectedCategory = nil }
                    Divider()
                    ForEach(ShortcutMapping.Category.allCases, id: \.self) { category in
                        Button {
                            store.selectedCategory = category
                        } label: {
                            Label(category.rawValue, systemImage: category.icon)
                        }
                    }
                } label: {
                    Image(systemName: store.selectedCategory?.icon ?? "filter")
                        .foregroundStyle(store.selectedCategory != nil ? Color.accentColor : .secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // Content
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(store.groupedShortcuts, id: \.0) { category, mappings in
                        Section {
                            ForEach(mappings) { mapping in
                                shortcutRow(mapping)
                                if mapping.id != mappings.last?.id { Divider() }
                            }
                        } header: {
                            HStack {
                                Image(systemName: category.icon)
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 12))
                                Text(category.rawValue)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(mappings.count)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showRecorder) {
            if let mapping = editing {
                ShortcutRecorderView(shortcut: mapping) { updated in
                    conflicts = store.findConflicts(mapping: updated)
                    if conflicts.isEmpty {
                        store.update(updated)
                        showRecorder = false
                    } else {
                        showConflict = true
                    }
                } onCancel: {
                    showRecorder = false
                }
            }
        }
        .alert("Shortcut Conflict", isPresented: $showConflict) {
            Button("Cancel", role: .cancel) {
                showRecorder = true
                showConflict = false
            }
            Button("Override") {
                if let mapping = editing {
                    store.update(mapping)
                }
                showRecorder = false
                showConflict = false
            }
        } message: {
            Text("This shortcut conflicts with: \(conflicts.map { $0.commandName }.joined(separator: ", "))")
        }
    }

    @ViewBuilder
    private func shortcutRow(_ mapping: ShortcutMapping) -> some View {
        HStack(spacing: 8) {
            Text(mapping.commandName)
                .font(.system(size: 12))

            if mapping.isCustomized {
                Image(systemName: "asterisk.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 10))
            }

            Spacer()

            Button {
                editing = mapping
                showRecorder = true
            } label: {
                Text(mapping.displayText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(mapping.isCustomized ? Color.accentColor : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Click to customize")

            if mapping.isCustomized {
                Button {
                    store.resetOne(id: mapping.id)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Reset to default")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct ShortcutRecorderView: View {
    @State var shortcut: ShortcutMapping
    let onSave: (ShortcutMapping) -> Void
    let onCancel: () -> Void

    @State private var isRecording = false
    @State private var recordedKey = ""
    @State private var recordedFlags: UInt = 0

    var body: some View {
        VStack(spacing: 20) {
            Text("Customize Shortcut").font(.headline)
            Text(shortcut.commandName).font(.subheadline)

            if isRecording {
                Text("Press new shortcut…")
                    .font(.system(.title2, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
            } else {
                Button("Click to Record") {
                    isRecording = true
                }
                .buttonStyle(.borderedProminent)
            }

            Text("Current: \(shortcut.displayText)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Save") {
                    if !recordedKey.isEmpty {
                        shortcut.keyEquivalent = recordedKey
                        shortcut.modifierFlags = recordedFlags
                        shortcut.isCustomized = true
                    }
                    onSave(shortcut)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRecording)
            }
        }
        .padding(24)
        .frame(width: 320)
        .background(ShortcutRecorderNSView(
            isRecording: $isRecording,
            recordedKey: $recordedKey,
            recordedFlags: $recordedFlags
        ))
    }
}

private struct ShortcutRecorderNSView: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var recordedKey: String
    @Binding var recordedFlags: UInt

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isRecording = isRecording
        if isRecording {
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard let characters = event.charactersIgnoringModifiers else { return event }
                let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
                guard !flags.isEmpty else { return event }

                recordedKey = characters.lowercased()
                recordedFlags = flags.rawValue
                isRecording = false
                context.coordinator.monitor = nil
                return nil
            }
        } else if context.coordinator.monitor != nil {
            context.coordinator.monitor = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var isRecording = false
        var monitor: Any?
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
