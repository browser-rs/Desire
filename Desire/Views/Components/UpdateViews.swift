import SwiftUI

/// In-app update banner (toolbar area): shows when a newer release exists
/// and the user hasn't dismissed it for this tag.
struct UpdateBannerView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var checker: UpdateChecker

    private var installButtonTitle: String {
        switch checker.installState {
        case .downloading: String(localized: "Downloading…")
        case .installing: String(localized: "Installing…")
        case .readyToRelaunch: String(localized: "Relaunching…")
        default: String(localized: "Update & Relaunch")
        }
    }

    var body: some View {
        if let tag = checker.latestTag, !checker.bannerDismissed {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(appAccent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "\(tag) is available"))
                        .font(.system(size: 12, weight: .medium))
                    Text(String(localized: "Click to view release notes"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                // 自更新（0.3.8）：装在 /Applications 时可一键下载校验
                // 并重启安装。
                if checker.canSelfUpdate {
                    Button {
                        checker.installNow()
                    } label: {
                        HStack(spacing: 4) {
                            if checker.installState == .downloading || checker.installState == .installing {
                                ProgressView().controlSize(.mini)
                            }
                            Text(installButtonTitle)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(appAccent.opacity(0.2)))
                        .foregroundStyle(appAccent)
                    }
                    .buttonStyle(.plain)
                    .disabled(checker.installState == .downloading || checker.installState == .installing)
                    if case .failed(let reason) = checker.installState {
                        Text(reason)
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                            .help(reason)
                    }
                }
                Button {
                    checker.bannerDismissed = true
                    if let url = checker.releasePageURL {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("View Release")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                Button {
                    checker.bannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Dismiss"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(appAccent.opacity(0.06))
            .overlay(alignment: .bottom) { Divider() }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Settings ▸ System ▸ "Check for Updates" 行。
///
/// 用统一的 `SettingsRow` + `SettingsCapsuleButton`（此前自己搓了一套 HStack +
/// 胶囊按钮，和同一卡片里其它行不一致）。三个行为上的改动：
/// - 有新版时**给出可点的动作**：装在 /Applications 就能一键更新，否则给"查看发布页"
///   ——此前只报"有新版本"，用户在这儿无事可做；
/// - 状态行带上当前版本号；
/// - 检查中不再把按钮换成固定 60pt 的转圈（宽度会跳），阶段改由状态文字表达，
///   按钮保持原宽禁用。
struct CheckUpdatesRow: View {
    @ObservedObject var checker: UpdateChecker

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var hasUpdate: Bool {
        if case .available = checker.lastCheckResult { return true }
        return false
    }

    private var busy: Bool {
        checker.isChecking || checker.installState == .downloading || checker.installState == .installing
    }

    var body: some View {
        SettingsRow("Check for Updates", subtitle: statusText, systemImage: "arrow.triangle.2.circlepath") {
            HStack(spacing: 8) {
                if hasUpdate {
                    if checker.canSelfUpdate {
                        SettingsCapsuleButton(installButtonTitle, isDisabled: busy) {
                            checker.installNow()
                        }
                    } else {
                        SettingsCapsuleButton("View Release") {
                            NSWorkspace.shared.open(checker.releasePageURL ?? UpdateChecker.releasesURL)
                        }
                    }
                }
                // 版本号用胶囊展示（不翻译）
                StatusPill(text: "v\(currentVersion)", kind: .neutral)
                SettingsCapsuleButton("Check Now", style: .secondary, isDisabled: busy) {
                    checker.startCheck()
                }
            }
        }
    }

    private var installButtonTitle: String {
        checker.installState == .readyToRelaunch
            ? String(localized: "Restart to Update")
            : String(localized: "Install Update")
    }

    private var statusText: String {
        if checker.isChecking { return String(localized: "Checking…") }
        if case .failed(let message) = checker.installState { return message }
        switch checker.lastCheckResult {
        case .available(let tag):
            return String(localized: "\(tag) is available")
        case .upToDate:
            return String(localized: "You're up to date.")
        case .failed(let error):
            return error
        case nil:
            return String(localized: "Check GitHub Releases for the latest build.")
        }
    }
}
