import SwiftUI
import UniformTypeIdentifiers

struct SafariExtensionPanel: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var manager: SafariExtensionStore
    @State private var showImportPicker = false
    @State private var importError: String?
    @State private var selectedExtension: SafariExtension?
    @State private var showPermissionRequest = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if manager.extensions.isEmpty {
                EmptyState(message: String(localized: "No Safari Extensions Installed"))
            } else {
                List {
                    ForEach(manager.extensions) { extension_ in
                        extensionRow(extension_)
                    }
                }
            }
        }
        .frame(width: 600, height: 500)
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.safariExtension, .zip, .item]) { result in
            switch result {
            case .success(let url):
                do {
                    try manager.installExtension(from: url)
                } catch {
                    importError = error.localizedDescription
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
        .sheet(item: $selectedExtension) { ext in
            ExtensionDetailView(ext: ext, manager: manager)
        }
    }

    private var header: some View {
        HStack {
            Text("Safari Extensions")
                .font(.title2.bold())

            Text("\(manager.extensions.count)")
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(appAccent.opacity(0.15)))
                .foregroundStyle(appAccent)

            Spacer()

            Button {
                showImportPicker = true
            } label: {
                Label("Import Extension", systemImage: "square.and.arrow.up.on.square")
            }
        }
        .padding()
    }

    private func extensionRow(_ extension_: SafariExtension) -> some View {
        HStack(spacing: 12) {
            // Icon
            if let icon = SafariExtensionImporter.loadIcon(for: extension_) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(extension_.localizedName)
                    .font(.body.weight(.medium))

                Text("v\(extension_.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let author = extension_.manifest.author {
                    Text("by \(author)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Permissions indicator
            if extension_.needsPermissionRequest || extension_.needsHostPermissionRequest {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Requires permissions")
            }

            // Toggle
            Toggle("", isOn: Binding(
                get: { extension_.isEnabled },
                set: { enabled in
                    if enabled {
                        manager.enableExtension(extension_)
                    } else {
                        manager.disableExtension(extension_)
                    }
                }
            ))
            .labelsHidden()

            // Actions
            Button {
                selectedExtension = extension_
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Details")

            Button {
                manager.uninstallExtension(extension_)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Uninstall")
        }
        .padding(.vertical, 4)
    }
}

private struct ExtensionDetailView: View {
    let ext: SafariExtension
    @ObservedObject var manager: SafariExtensionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(ext.localizedName).font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Basic Info
                    GroupBox("Extension Information") {
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(label: "Version", value: ext.version)
                            if let author = ext.manifest.author {
                                InfoRow(label: "Author", value: author)
                            }
                            if let desc = ext.manifest.description {
                                Text(desc)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                    }

                    // Permissions
                    if !ext.requiredPermissions.isEmpty || !ext.requiredHostPermissions.isEmpty {
                        GroupBox("Permissions") {
                            VStack(alignment: .leading, spacing: 8) {
                                if !ext.requiredPermissions.isEmpty {
                                    Text("API Permissions:")
                                        .font(.caption.bold())
                                    ForEach(ext.requiredPermissions, id: \.self) { perm in
                                        HStack {
                                            Image(systemName: ext.permissionsGranted.contains(perm) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(ext.permissionsGranted.contains(perm) ? .green : .secondary)
                                            Text(perm).font(.caption)
                                        }
                                    }
                                }

                                if !ext.requiredHostPermissions.isEmpty {
                                    Text("Host Permissions:")
                                        .font(.caption.bold())
                                    ForEach(ext.requiredHostPermissions, id: \.self) { perm in
                                        HStack {
                                            Image(systemName: ext.hostPermissionsGranted.contains(perm) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(ext.hostPermissionsGranted.contains(perm) ? .green : .secondary)
                                            Text(perm).font(.caption)
                                        }
                                    }
                                }
                            }
                            .padding(8)
                        }
                    }

                    // Content Scripts
                    if let contentScripts = ext.manifest.content_scripts, !contentScripts.isEmpty {
                        GroupBox("Content Scripts") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(contentScripts.indices, id: \.self) { i in
                                    let script = contentScripts[i]
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Script \(i + 1)")
                                            .font(.caption.bold())
                                        Text("Matches: \(script.matches.joined(separator: ", "))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        if let js = script.js {
                                            Text("JS: \(js.joined(separator: ", "))")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        if let css = script.css {
                                            Text("CSS: \(css.joined(separator: ", "))")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                            .padding(8)
                        }
                    }

                    // Background
                    if let background = ext.manifest.background {
                        GroupBox("Background") {
                            VStack(alignment: .leading, spacing: 4) {
                                if let sw = background.service_worker {
                                    Text("Service Worker: \(sw)")
                                        .font(.caption)
                                }
                                if let scripts = background.scripts {
                                    Text("Scripts: \(scripts.joined(separator: ", "))")
                                        .font(.caption)
                                }
                                if let page = background.page {
                                    Text("Page: \(page)")
                                        .font(.caption)
                                }
                            }
                            .padding(8)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 500, height: 600)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption.bold())
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SafariExtensionPanel(manager: SafariExtensionStore())
}