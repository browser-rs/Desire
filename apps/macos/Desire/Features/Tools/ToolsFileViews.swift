import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 文件工具视图（v0.8.33 批次四）：批量重命名、压缩/解压。
// 纯逻辑在 BatchRenameCore / ArchiveCore，文件操作在对应 Engine。

private struct FileToolField: View {
    let title: String
    @Binding var text: String
    var width: CGFloat = 150

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: width)
        }
    }
}

private struct FileToolRow: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(name)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - 批量重命名

struct BatchRenameToolView: View {
    @State private var urls: [URL] = []
    @State private var find = ""
    @State private var replacement = ""
    @State private var useRegex = false
    @State private var caseInsensitive = false
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var appendNumber = false
    @State private var numberStart = "1"
    @State private var numberStep = "1"
    @State private var numberPadding = "2"
    @State private var appendDate = false
    @State private var newExtension = ""
    @State private var plan: [BatchRenameCore.Item] = []
    @State private var error: String?
    @State private var note: String?
    @State private var working = false
    @State private var confirmRename = false

    private var rule: BatchRenameCore.Rule {
        BatchRenameCore.Rule(
            find: find, replacement: replacement,
            useRegex: useRegex, caseInsensitive: caseInsensitive,
            prefix: prefix, suffix: suffix,
            appendNumber: appendNumber,
            numberStart: Int(numberStart) ?? 1,
            numberStep: Int(numberStep) ?? 1,
            numberPadding: Int(numberPadding) ?? 2,
            appendDate: appendDate,
            newExtension: newExtension)
    }

    private var conflictCount: Int {
        plan.filter { $0.conflict != nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(String(localized: "Add Files…")) { addFiles() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(String(localized: "Add Folder…")) { addFolder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if !urls.isEmpty {
                    Text(verbatim: "\(urls.count) files")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if urls.isEmpty {
                Text(String(localized: "Add files to see a live preview before renaming."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            ruleEditor
            if let error {
                ToolErrorText(text: error)
            }
            if !plan.isEmpty {
                preview
            }
            HStack(spacing: 8) {
                Button(String(localized: "Rename…")) { confirmRename = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(plan.isEmpty || conflictCount > 0 || working)
                if conflictCount > 0 {
                    Text(String(localized: "Fix \(conflictCount) conflicts first."))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }
                if working {
                    ProgressView().controlSize(.small)
                }
            }
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: rule) { _, _ in recompute() }
        .onChange(of: urls) { _, _ in recompute() }
        .alert(String(localized: "Rename \(plan.count) files?"), isPresented: $confirmRename) {
            Button(String(localized: "Rename"), role: .destructive) { performRename() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Files are renamed in two phases; existing files are never overwritten."))
        }
    }

    private var ruleEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                FileToolField(title: String(localized: "Find"), text: $find)
                FileToolField(title: String(localized: "Replace"), text: $replacement)
                ToolToggle(title: String(localized: "Regex"), isOn: $useRegex)
                ToolToggle(title: String(localized: "Ignore case"), isOn: $caseInsensitive)
            }
            HStack(spacing: 12) {
                FileToolField(title: String(localized: "Prefix"), text: $prefix, width: 120)
                FileToolField(title: String(localized: "Suffix"), text: $suffix, width: 120)
                FileToolField(title: String(localized: "Extension"), text: $newExtension, width: 70)
                ToolToggle(title: String(localized: "Add date"), isOn: $appendDate)
            }
            HStack(spacing: 12) {
                ToolToggle(title: String(localized: "Append number"), isOn: $appendNumber)
                if appendNumber {
                    FileToolField(title: String(localized: "Number start"), text: $numberStart, width: 50)
                    FileToolField(title: String(localized: "Number step"), text: $numberStep, width: 50)
                    FileToolField(title: String(localized: "Zero padding"), text: $numberPadding, width: 50)
                }
            }
        }
    }

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(plan) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.conflict == nil
                              ? "arrow.right" : "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(item.conflict == nil
                                             ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.orange))
                        Text(item.originalName)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(item.proposedName)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(item.conflict == nil
                                             ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let conflict = item.conflict {
                            Text(conflictName(conflict))
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxHeight: 200)
    }

    private func conflictName(_ conflict: BatchRenameCore.Conflict) -> String {
        switch conflict {
        case .duplicate: return String(localized: "duplicate")
        case .exists: return String(localized: "exists")
        case .empty: return String(localized: "empty")
        case .invalidExtension: return String(localized: "bad extension")
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        urls.append(contentsOf: panel.urls)
        error = nil
        note = nil
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        urls.append(contentsOf: contents.filter { !$0.hasDirectoryPath })
        error = nil
        note = nil
    }

    private func recompute() {
        guard !urls.isEmpty else {
            plan = []
            error = nil
            return
        }
        var existing: [URL: Set<String>] = [:]
        let directories = Set(urls.map { $0.deletingLastPathComponent() })
        for directory in directories {
            let names = (try? FileManager.default.contentsOfDirectory(
                atPath: directory.path)) ?? []
            existing[directory] = Set(names.map { $0.lowercased() })
        }
        switch BatchRenameCore.plan(urls: urls, rule: rule,
                                    existingNamesByDirectory: existing) {
        case .success(let nextPlan):
            plan = nextPlan
            error = nil
        case .failure(let failure):
            plan = []
            error = failure.localizedDescription
        }
    }

    private func performRename() {
        let snapshot = plan
        working = true
        error = nil
        note = nil
        Task {
            do {
                let count = try await BatchRenameEngine.apply(snapshot)
                urls = snapshot.map(\.finalURL)
                note = String(localized: "Renamed \(count) files.")
                recompute()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: - 压缩 / 解压

private enum ArchiveMode: String, CaseIterable, Identifiable {
    case compress, extract
    var id: String { rawValue }
}

struct ArchiveToolView: View {
    @State private var mode: ArchiveMode = .compress
    @State private var sources: [URL] = []
    @State private var format: ArchiveCore.Format = .zip
    @State private var archiveURL: URL?
    @State private var destination: URL?
    @State private var entries: [ArchiveCore.Entry] = []
    @State private var unsafeEntry: String?
    @State private var error: String?
    @State private var note: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $mode) {
                Text(String(localized: "Compress")).tag(ArchiveMode.compress)
                Text(String(localized: "Extract")).tag(ArchiveMode.extract)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
            if mode == .compress {
                compressView
            } else {
                extractView
            }
            if let error {
                ToolErrorText(text: error)
            }
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: mode) { _, _ in
            error = nil
            note = nil
        }
    }

    private var compressView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(String(localized: "Add Files…")) { addFiles() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(String(localized: "Add Folder…")) { addFolder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if !sources.isEmpty {
                    Text(verbatim: "\(sources.count) items")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(sources.enumerated()), id: \.offset) { index, url in
                FileToolRow(name: url.lastPathComponent) {
                    sources.remove(at: index)
                }
            }
            HStack(spacing: 12) {
                Picker("", selection: $format) {
                    ForEach(ArchiveCore.Format.allCases) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 180)
                Button(String(localized: "Create Archive…")) { createArchive() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(sources.isEmpty || working)
                if working {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private var extractView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(String(localized: "Choose Archive…")) { chooseArchive() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if let archiveURL {
                    Text(archiveURL.lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if !entries.isEmpty {
                Text(verbatim: "\(entries.count) entries")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(entries.prefix(30).enumerated()), id: \.offset) { _, entry in
                            HStack(spacing: 6) {
                                Image(systemName: entry.isDirectory ? "folder" : "doc")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Text(entry.path)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            if let unsafeEntry {
                ToolErrorText(text: String(localized: "Unsafe path in archive: \(unsafeEntry)"))
            }
            HStack(spacing: 8) {
                Button(destination?.lastPathComponent ?? String(localized: "Choose Destination…")) {
                    chooseDestination()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(String(localized: "Extract")) { extract() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(archiveURL == nil || destination == nil || unsafeEntry != nil || working)
                if working {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        sources.append(contentsOf: panel.urls)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sources.append(url)
    }

    private func createArchive() {
        let name = ArchiveCore.archiveFileName(
            sourceName: sources.first?.lastPathComponent ?? "Archive", format: format)
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .zip ? [.zip] : [.gzip]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        working = true
        error = nil
        note = nil
        Task {
            do {
                let count = try await ArchiveEngine.create(
                    sources: sources, format: format, to: destination)
                note = String(localized: "Created an archive with \(count) items.")
                RecentLocalFiles.record(url: destination)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .gzip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        archiveURL = url
        destination = url.deletingLastPathComponent()
        entries = []
        unsafeEntry = nil
        error = nil
        note = nil
        Task {
            do {
                let listed = try await ArchiveEngine.list(archive: url)
                entries = listed
                unsafeEntry = ArchiveCore.firstUnsafeEntry(listed.map(\.path))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return }
        destination = panel.url
    }

    private func extract() {
        guard let archiveURL, let destination else { return }
        working = true
        error = nil
        note = nil
        Task {
            do {
                let extracted = try await ArchiveEngine.extract(
                    archive: archiveURL, to: destination)
                note = String(localized: "Extracted \(extracted.count) entries.")
                RecentLocalFiles.record(url: destination)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
