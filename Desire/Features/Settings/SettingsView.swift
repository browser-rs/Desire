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
            case .ai: "Agent"
            case .privacy: "Privacy"
            case .autofill: "Autofill"
            case .keyboardShortcuts: "Keyboard Shortcuts"
            }
        }
    }

    @ObservedObject var settings: Settings
    @ObservedObject var aiPreference: AgentPreferenceStore
    @ObservedObject var contentBlocker: ContentBlockerStore
    /// 视频站广告拦截（YouTube/哔哩哔哩等的广告位与列表页广告卡片）。
    @ObservedObject var videoAdBlocker: VideoAdBlocker
    @ObservedObject var downloadStore: DownloadStore
    @ObservedObject var formAutofillStore: FormAutofillStore
    @ObservedObject var permissionStore: PermissionStore
    @ObservedObject var historyStore: HistoryStore
    @ObservedObject var privacyModeStore: PrivacyModeStore
    var shortcutStore: KeyboardShortcutStore

    @State private var selectedSection: Section = .general

    var body: some View {
        content
            // 设置窗口是独立 scene：ContentView 上的 .tint(settings.accentColor)
            // 不会覆盖到这里，不补这一次的话设置里的强调色在设置窗内不生效
            // （侧栏选中、按钮胶囊都会退回系统强调色）。
            .appAccent(settings.accentColor.color)
    }

    private var content: some View {
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
            detailContent
                .settingsPageBackground()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .general:
            GeneralSettingsSection(
                settings: settings,
                downloadStore: downloadStore,
                videoAdBlocker: videoAdBlocker
            )
        case .ai:
            AgentSettingsSection(store: aiPreference)
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
            KeyboardShortcutsEditorView(store: shortcutStore)
        }
    }
}

private struct KeyboardShortcutsEditorView: View {
    /// The SHARED instance (SystemState) — the same object the menu commands
    /// and hidden shortcut buttons observe. The old private @StateObject here
    /// saved customizations to disk where nothing ever read them.
    @ObservedObject var store: KeyboardShortcutStore
    @State private var editing: ShortcutMapping?
    @State private var showRecorder = false
    @State private var showConflict = false
    @State private var conflicts: [ShortcutMapping] = []

    var body: some View {
        SettingsContainer {
            // MARK: - Header

            SettingsSection(
                title: "Keyboard Shortcuts",
                subtitle: store.filteredShortcuts.count != store.shortcuts.count
                    ? "\(store.filteredShortcuts.count) of \(store.shortcuts.count) shown."
                    : "Customize any binding. Click the current shortcut to record a new one. Re-recorded bindings apply on the next launch.",
                icon: "keyboard"
            ) {
                VStack(spacing: 10) {
                    // Search field
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField("Search shortcuts…", text: $store.searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                        if !store.searchText.isEmpty {
                            Button {
                                store.searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                    )

                    // Category filter chips
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            CategoryChip(
                                title: "All",
                                systemImage: "square.grid.2x2",
                                isSelected: store.selectedCategory == nil
                            ) {
                                store.selectedCategory = nil
                            }
                            ForEach(ShortcutMapping.Category.allCases, id: \.self) { category in
                                CategoryChip(
                                    title: category.rawValue,
                                    systemImage: category.icon,
                                    isSelected: store.selectedCategory == category
                                ) {
                                    store.selectedCategory = category
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }

            // MARK: - Grouped Shortcuts

            ForEach(store.groupedShortcuts, id: \.0) { category, mappings in
                SettingsSection(
                    title: category.rawValue,
                    subtitle: "\(mappings.count) shortcut\(mappings.count == 1 ? "" : "s").",
                    icon: category.icon
                ) {
                    VStack(spacing: 0) {
                        ForEach(Array(mappings.enumerated()), id: \.element.id) { index, mapping in
                            shortcutRow(mapping)
                            if index < mappings.count - 1 {
                                SettingsRowDivider()
                            }
                        }
                    }
                }
            }

            // MARK: - Reset

            SettingsSection(
                title: "Reset",
                subtitle: "Revert every shortcut to its default binding.",
                icon: "arrow.counterclockwise"
            ) {
                HStack {
                    Spacer()
                    Button {
                        store.resetAll()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11))
                            Text("Reset All Shortcuts")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Color.red.opacity(0.12))
                        )
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mapping.commandName)
                        .font(.system(size: 12, weight: .medium))
                    if mapping.isCustomized {
                        StatusPill(text: "Custom", kind: .info)
                    }
                }
            }

            Spacer()

            Button {
                editing = mapping
                showRecorder = true
            } label: {
                ShortcutKeySequence(display: mapping.displayText)
            }
            .buttonStyle(.plain)
            .help("Click to customize")

            if mapping.isCustomized {
                Button {
                    store.resetOne(id: mapping.id)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle().fill(Color.secondary.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help("Reset to default")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}

// MARK: - Category chip

private struct CategoryChip: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isSelected
                          ? AnyShapeStyle(.tint.opacity(0.18))
                          : AnyShapeStyle(Color.secondary.opacity(isHovering ? 0.12 : 0.08)))
            )
            .overlay(
                Capsule()
                    .stroke(
                        isSelected
                            ? AnyShapeStyle(.tint.opacity(0.4))
                            : AnyShapeStyle(Color.secondary.opacity(0.18)),
                        lineWidth: 0.5
                    )
            )
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.15), value: isHovering)
        .animation(.smooth(duration: 0.15), value: isSelected)
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
                    .foregroundStyle(.tint)
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
