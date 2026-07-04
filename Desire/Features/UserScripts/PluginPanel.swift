//
//  PluginPanel.swift
//  Desire
//
//  Created by mankong on 2026/7/5.
//

import SwiftUI
import UniformTypeIdentifiers

/// Independent Plugins window content.
///
/// Hosted in `PluginsWindowController`'s `NSWindow` (no `onClose` callback —
/// the window's traffic-light close button is the only way out).
/// Lists plugins grouped by Enabled / Disabled with a count badge in the
/// header. `PluginEditor` is presented as a sheet.
struct PluginPanel: View {
    @ObservedObject var store: PluginStore

    @State private var editingPlugin: Plugin?
    @State private var showImportPicker = false
    @State private var importError: String?

    private var enabledPlugins: [Plugin]  { store.plugins.filter { $0.isEnabled } }
    private var disabledPlugins: [Plugin] { store.plugins.filter { !$0.isEnabled } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.plugins.isEmpty {
                EmptyState(message: String(localized: "No Plugins"))
            } else {
                List {
                    if !enabledPlugins.isEmpty {
                        Section {
                            ForEach(enabledPlugins) { plugin in
                                pluginRow(plugin)
                            }
                        } header: {
                            sectionHeader("Enabled", count: enabledPlugins.count)
                        }
                    }
                    if !disabledPlugins.isEmpty {
                        Section {
                            ForEach(disabledPlugins) { plugin in
                                pluginRow(plugin)
                            }
                        } header: {
                            sectionHeader("Disabled", count: disabledPlugins.count)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .sheet(item: $editingPlugin) { plugin in
            PluginEditor(plugin: plugin, store: store)
        }
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.json, .desirePlugin]) { result in
            switch result {
            case .success(let url):
                if let plugin = store.importPlugin(from: url) {
                    store.add(plugin)
                } else {
                    importError = String(localized: "Failed to import plugin: invalid file format")
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert("Import Failed", isPresented: .init(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Plugins")
                .font(.title2.bold())
            Text("\(store.plugins.count)")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
            Spacer()
            Button {
                let p = Plugin(
                    name: String(localized: "New Plugin"),
                    jsCode: "// Plugin JavaScript code\nconsole.log('Desire plugin loaded');"
                )
                store.add(p)
                editingPlugin = p
            } label: {
                Label("Add", systemImage: "plus")
            }
            Button {
                showImportPicker = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.up.on.square")
            }
        }
        .padding()
    }

    private func sectionHeader(_ title: LocalizedStringKey, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("(\(count))")
                .foregroundStyle(.secondary)
        }
    }

    private func pluginRow(_ plugin: Plugin) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { plugin.isEnabled },
                set: { enabled in
                    var p = plugin
                    p.isEnabled = enabled
                    store.update(p)
                }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if !plugin.description.isEmpty {
                    Text(plugin.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text("v\(plugin.version)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if !plugin.author.isEmpty {
                        Text("by \(plugin.author)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if !plugin.urlPatterns.isEmpty {
                        Text(plugin.urlPatterns.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Button {
                editingPlugin = plugin
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Edit")

            Button {
                exportPlugin(plugin)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Export")

            Button {
                store.remove(plugin)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete")
        }
        .padding(.vertical, 4)
    }

    private func exportPlugin(_ plugin: Plugin) {
        guard let url = store.exportPlugin(plugin) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(plugin.name).desireplugin"
        panel.allowedContentTypes = [.desirePlugin]
        panel.begin { response in
            if response == .OK, let dest = panel.url {
                try? FileManager.default.copyItem(at: url, to: dest)
                try? FileManager.default.removeItem(at: url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

private struct PluginEditor: View {
    /// Local editable copy of the plugin. Edited in place by the form
    /// fields; only persisted via `store.update(...)` when the user clicks
    /// Save. Cancel simply dismisses without writing, fixing the previous
    /// bug where Cancel also called `store.update(plugin)`.
    @State private var editablePlugin: Plugin
    @ObservedObject var store: PluginStore
    @State private var urlPatternsText: String
    @State private var excludePatternsText: String
    @Environment(\.dismiss) private var dismiss

    init(plugin: Plugin, store: PluginStore) {
        _editablePlugin = State(initialValue: plugin)
        self.store = store
        _urlPatternsText = State(initialValue: plugin.urlPatterns.joined(separator: "\n"))
        _excludePatternsText = State(initialValue: plugin.excludePatterns.joined(separator: "\n"))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Edit Plugin").font(.headline)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    editablePlugin.urlPatterns = urlPatternsText
                        .components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    editablePlugin.excludePatterns = excludePatternsText
                        .components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    store.update(editablePlugin)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 8) {
                TextField("Name", text: $editablePlugin.name)
                    .frame(width: 180)
                TextField("Version", text: $editablePlugin.version)
                    .frame(width: 60)
                TextField("Author", text: $editablePlugin.author)
                    .frame(width: 120)
            }

            TextField("Description", text: $editablePlugin.description)

            HStack {
                Picker("Run At", selection: $editablePlugin.runAt) {
                    ForEach(RunAt.allCases, id: \.self) { at in
                        Text(at.rawValue.replacingOccurrences(of: "_", with: " ")).tag(at)
                    }
                }
                .frame(width: 200)
                Spacer()
                Toggle("Enabled", isOn: $editablePlugin.isEnabled)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("URL Match Patterns (one per line)").font(.caption)
                    TextEditor(text: $urlPatternsText)
                        .codeEditorStyle()
                        .frame(height: 80)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Exclude Patterns (one per line)").font(.caption)
                    TextEditor(text: $excludePatternsText)
                        .codeEditorStyle()
                        .frame(height: 80)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("JavaScript Code").font(.caption)
                TextEditor(text: $editablePlugin.jsCode)
                    .codeEditorStyle()
                    .frame(minHeight: 120)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("CSS Code").font(.caption)
                TextEditor(text: $editablePlugin.cssCode)
                    .codeEditorStyle()
                    .frame(minHeight: 80)
            }
        }
        .padding()
        .frame(width: 560, height: 560)
    }
}

/// Shared styling for monospaced code editors with a rounded, filled
/// background — replaces the old `.border(Color.secondary.opacity(0.2))`
/// with a System Settings.app-style `RoundedRectangle` filled with
/// `.textBackgroundColor` and stroked with `.separatorColor`.
private struct CodeEditorStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
    }
}

private extension View {
    func codeEditorStyle() -> some View {
        modifier(CodeEditorStyle())
    }
}

extension UTType {
    static let desirePlugin = UTType(exportedAs: "me.siwi.Desire.plugin")
}

#Preview {
    PluginPanel(store: PluginStore())
}
