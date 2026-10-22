import AppKit
import SwiftUI

/// 浏览器数据导入（v0.8.0）：检测本机 Chrome/Edge/Brave/Arc/Safari 档案，
/// 预览书签/历史计数，选择要导入的域，执行并显示报告。
///
/// 隐私：密码不解浏览器的加密库（Chromium Safe Storage / Safari Keychain），
/// 面板里明确提示走 CSV；历史只读取复制出来的临时库，不直连原文件。
struct BrowserImportSheet: View {
    @ObservedObject var settings: Settings
    @Environment(\.dismiss) private var dismiss

    @State private var profiles: [BrowserImportProfile] = []
    @State private var selectedID: String?
    @State private var preview: BrowserImportPreview?
    @State private var report: BrowserImportReport?
    @State private var includeBookmarks = true
    @State private var includeHistory = true
    @State private var includeSettings = false
    @State private var errorText: String?

    private var selectedProfile: BrowserImportProfile? {
        profiles.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import Browser Data")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Bring over bookmarks, history and home/startup pages. Passwords stay CSV-only.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            if let report {
                reportView(report)
            } else {
                profilesView
                if let preview {
                    previewView(preview)
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .task {
            profiles = BrowserImportService.detectedProfiles()
            if selectedID == nil { selectedID = profiles.first?.id }
        }
    }

    // MARK: - Profiles

    private var profilesView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Detected Profiles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose Folder…") { chooseFolder() }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            if profiles.isEmpty {
                Text("No browser profiles detected. Use Choose Folder… and select a Chrome profile folder or Safari.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(profiles) { profile in
                            profileRow(profile)
                            Divider().opacity(0.4)
                        }
                    }
                }
                .frame(maxHeight: 150)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45)))
            }
        }
    }

    private func profileRow(_ profile: BrowserImportProfile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: profile.source))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(profile.source.displayName) · \(profile.name)")
                    .font(.system(size: 12, weight: .medium))
                Text(profile.profilePath)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Preview") { loadPreview(profile) }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { loadPreview(profile) }
        .background(selectedID == profile.id
            ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.12)
            : Color.clear)
    }

    private func icon(for source: BrowserImportSource) -> String {
        switch source {
        case .safari: "safari"
        default: "globe"
        }
    }

    // MARK: - Preview

    private func previewView(_ preview: BrowserImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                countPill("Bookmarks", preview.bookmarkCount)
                countPill("History", preview.historyCount)
                if !preview.settings.isEmpty {
                    countPill("Settings", preview.settings.startupURLs.count + (preview.settings.homePage == nil ? 0 : 1))
                }
            }
            Toggle("Bookmarks", isOn: $includeBookmarks)
                .disabled(preview.bookmarkCount == 0)
            Toggle("History", isOn: $includeHistory)
                .disabled(preview.historyCount == 0)
            Toggle("Homepage & startup pages", isOn: $includeSettings)
                .disabled(preview.settings.isEmpty)
            if !preview.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(preview.warnings.prefix(4), id: \.self) { warning in
                        Text("• \(warning)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Import") { runImport(preview) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!includeBookmarks && !includeHistory && !includeSettings)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45)))
    }

    private func countPill(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: "\(count)")
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func loadPreview(_ profile: BrowserImportProfile) {
        selectedID = profile.id
        report = nil
        errorText = nil
        preview = BrowserImportService.preview(profile)
        includeBookmarks = (preview?.bookmarkCount ?? 0) > 0
        includeHistory = (preview?.historyCount ?? 0) > 0
        includeSettings = !(preview?.settings.isEmpty ?? true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url,
              let profile = BrowserImportService.profile(atPath: url.path) else {
            errorText = String(localized: "That folder doesn't look like a Chrome profile or Safari data folder.")
            return
        }
        if !profiles.contains(where: { $0.id == profile.id }) {
            profiles.append(profile)
        }
        loadPreview(profile)
    }

    private func runImport(_ preview: BrowserImportPreview) {
        guard let profile = selectedProfile else { return }
        guard let app = AppState.live else {
            errorText = String(localized: "App state is not ready.")
            return
        }
        report = BrowserImportService.perform(
            profile,
            preview: preview,
            includeBookmarks: includeBookmarks,
            includeHistory: includeHistory,
            includeSettings: includeSettings,
            settings: settings,
            bookmarkStore: app.bookmarkStore,
            historyStore: app.historyStore)
    }

    @ViewBuilder
    private func reportView(_ report: BrowserImportReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Import Complete", systemImage: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
            HStack(spacing: 18) {
                countPill("Bookmarks", report.bookmarksImported)
                countPill("Duplicates skipped", report.bookmarksSkipped)
                countPill("History", report.historyImported)
                if !report.settingsApplied.isEmpty {
                    countPill("Settings", report.settingsApplied.count)
                }
            }
            if !report.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(report.warnings.prefix(5), id: \.self) { warning in
                        Text("• \(warning)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45)))
    }
}
