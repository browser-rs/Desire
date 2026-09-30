import AppKit
import SwiftUI

/// 批量下载的默认参数表单——**两个入口共用**：
/// ① 设置 ▸ 批量下载（日常调整）；② DownloadPanel"视频任务"首次进入的
/// 引导（`onboardingDone` 未打卡时自动弹出，完成后打卡不再弹）。
///
/// 这些值是引擎的**确定性默认**；对话中让智能体下批量任务时，工具参数
/// （directory/splitEvery/maxConcurrent/naming）依然逐批覆盖。
struct BatchDownloadSettingsContent: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    /// 引导模式：底部显示完成按钮，保存 onboardingDone 打卡。
    var isOnboarding: Bool = false
    var onComplete: (() -> Void)? = nil

    @State private var baseDirectory: String = BatchMediaPreferences.baseDirectory ?? ""
    @State private var splitEnabled: Bool = BatchMediaPreferences.splitEvery != nil
    @State private var splitCountText: String = String(BatchMediaPreferences.splitEvery ?? 120)
    @State private var maxConcurrent: Int = BatchMediaPreferences.maxConcurrent
    @State private var reserveGB: Int = BatchMediaPreferences.reserveGB
    @State private var skipDownloaded: Bool = BatchMediaPreferences.skipDownloaded
    @State private var naming: BatchMediaPlan.NamingStyle = BatchMediaPreferences.namingStyle
    @State private var timeoutText: String = String(BatchMediaPreferences.exportTimeoutMinutes)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isOnboarding {
                Text("Batch Download Setup")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.bottom, 4)
                Text("Batch Download Setup Subtitle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 14)
            }

            VStack(alignment: .leading, spacing: 0) {
                locationRow
                SettingsRowDivider()
                splitRow
                SettingsRowDivider()
                concurrencyRow
                SettingsRowDivider()
                reserveRow
                SettingsRowDivider()
                timeoutRow
                SettingsRowDivider()
                skipRow
                SettingsRowDivider()
                namingRow
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            Text("Batch Download Defaults Footer")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .padding(.horizontal, 14)

            if isOnboarding {
                HStack {
                    Spacer()
                    Button {
                        BatchMediaPreferences.onboardingDone = true
                        onComplete?()
                    } label: {
                        Text("Done")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(appAccent))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.top, 18)
            }
        }
    }

    // MARK: - 行

    private var locationRow: some View {
        settingsRow(
            String(localized: "Save Location"),
            subtitle: String(localized: "Where finished videos go. The agent can override this per batch in chat.")
        ) {
            HStack(spacing: 6) {
                Text(baseDirectory.isEmpty ? String(localized: "Default (~/Downloads)") : baseDirectory)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 190, alignment: .leading)
                    .foregroundStyle(baseDirectory.isEmpty ? .secondary : .primary)
                Button(String(localized: "Choose…")) { chooseDirectory() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appAccent)
                if !baseDirectory.isEmpty {
                    Button(String(localized: "Reset to Default")) {
                        baseDirectory = ""
                        BatchMediaPreferences.baseDirectory = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var splitRow: some View {
        settingsRow(
            String(localized: "Split Rule"),
            subtitle: String(localized: "Start a fresh archivedNNN subfolder after every N files.")
        ) {
            HStack(spacing: 6) {
                Toggle("", isOn: $splitEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .onChange(of: splitEnabled) { _, on in persistSplit() }
                TextField("", text: $splitCountText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                    )
                    .disabled(!splitEnabled)
                    .opacity(splitEnabled ? 1 : 0.4)
                    .onChange(of: splitCountText) { _, _ in persistSplit() }
                Text(String(localized: "files per folder"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var concurrencyRow: some View {
        settingsRow(
            String(localized: "Concurrency"),
            subtitle: String(localized: "How many videos download at the same time.")
        ) {
            Picker("", selection: $maxConcurrent) {
                ForEach(1...4, id: \.self) { n in Text(verbatim: "\(n)").tag(n) }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .labelsHidden()
            .onChange(of: maxConcurrent) { _, n in
                BatchMediaPreferences.maxConcurrent = n
            }
        }
    }

    private var reserveRow: some View {
        settingsRow(
            String(localized: "Reserve Space (GB)"),
            subtitle: String(localized: "Pause the batch (and tell you) when free space drops below this; auto-resumes when space recovers.")
        ) {
            Stepper(value: $reserveGB, in: 1...500, step: 1) {
                Text(verbatim: "\(reserveGB) GB")
                    .font(.system(size: 12).monospacedDigit())
            }
            .onChange(of: reserveGB) { _, n in
                BatchMediaPreferences.reserveGB = n
            }
        }
    }

    private var timeoutRow: some View {
        settingsRow(
            String(localized: "Time Limit (min)"),
            subtitle: String(localized: "Hard cap for a single download task; 0 = no limit. Long videos on slow networks may need this raised.")
        ) {
            HStack(spacing: 4) {
                TextField("", text: $timeoutText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                    )
                Text(String(localized: "min"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .onChange(of: timeoutText) { _, text in
                let n = Int(text.trimmingCharacters(in: .whitespaces)) ?? 30
                BatchMediaPreferences.exportTimeoutMinutes = n
            }
        }
    }

    private var skipRow: some View {
        settingsRow(
            String(localized: "Skip Already Downloaded"),
            subtitle: String(localized: "Re-running the same list skips files saved before (per-batch force can bypass).")
        ) {
            Toggle("", isOn: $skipDownloaded)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .onChange(of: skipDownloaded) { _, on in
                    BatchMediaPreferences.skipDownloaded = on
                }
        }
    }

    private var namingRow: some View {
        settingsRow(
            String(localized: "Naming Style"),
            subtitle: String(localized: "Clean collapses repeated site title templates; code puts the ID first.")
        ) {
            Picker("", selection: $naming) {
                Text(String(localized: "Clean")).tag(BatchMediaPlan.NamingStyle.clean)
                Text(String(localized: "Code")).tag(BatchMediaPlan.NamingStyle.code)
                Text(String(localized: "Title")).tag(BatchMediaPlan.NamingStyle.title)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .labelsHidden()
            .onChange(of: naming) { _, style in
                BatchMediaPreferences.namingStyle = style
            }
        }
    }

    // MARK: - 共用

    private func settingsRow<Trailing: View>(
        _ title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
                .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose where batch downloads go")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        baseDirectory = url.path
        BatchMediaPreferences.baseDirectory = url.path
    }

    private func persistSplit() {
        let n = Int(splitCountText.trimmingCharacters(in: .whitespaces)) ?? 0
        BatchMediaPreferences.splitEvery = splitEnabled ? max(1, n) : nil
    }
}

/// 设置页包装（Settings ▸ 批量下载）。**必须套 SettingsContainer**：
/// 其它区块都经它限宽居中（720pt），裸 SettingsSection 会被拉满整窗宽、
/// 行控件顶到窗口右缘并被截断（用户实测截图）。
struct BatchDownloadSettingsSection: View {
    var body: some View {
        SettingsContainer {
            SettingsSection(
                title: String(localized: "Batch Downloads"),
                subtitle: String(localized: "Defaults for batch video downloads — the agent can override per batch in chat."),
                icon: "square.stack.3d.up"
            ) {
                BatchDownloadSettingsContent()
                    .padding(.vertical, 8)
            }
        }
    }
}
