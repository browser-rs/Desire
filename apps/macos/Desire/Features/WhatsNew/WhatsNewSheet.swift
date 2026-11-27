import AppKit
import SwiftUI

/// 更新后 What's New（v0.8.0）：本版亮点 + 一次性迁移入口。
struct WhatsNewSheet: View {
    @ObservedObject var sync: SyncStore
    @ObservedObject private var store = WhatsNewStore.shared
    @Environment(\.dismiss) private var dismiss

    private struct Highlight: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
    }

    /// 每次发版更新为当版亮点（v0.8.26 / v0.8.46 两次漏过的坑——发版 checklist 固定项）。
    private var highlights: [Highlight] {
        [
            .init(icon: "magnifyingglass.circle", title: String(localized: "The everyday browser, finished"),
                  detail: String(localized: "Find can match whole words; history can keep only the last N days; a tab group can be saved as a workspace; and the password health card opens the site that needs a new password.")),
            .init(icon: "lock.shield", title: String(localized: "Accounts that can prove what happened"),
                  detail: String(localized: "Signing out now revokes every refresh token on that device, password changes and revocations take effect immediately, recovery codes reset an account once, and an audit log records sign-ins, password changes and device revocations. Rate limits and sync quotas are shared across server instances.")),
            .init(icon: "brain.head.profile", title: String(localized: "An agent you can see through"),
                  detail: String(localized: "Missed weekly tasks catch up once on launch; prompt-cache prefix changes are explained in the trace; the approval card previews how many same-shape calls a batch will cover (max 8); revisions show a line diff and can be undone; spilled tool results have a searchable viewer.")),
            .init(icon: "iphone.gen3", title: String(localized: "The phone can start the work too"),
                  detail: String(localized: "Remote can open or duplicate tabs, filter and collapse groups, start a batch from a URL list with a time window, retry sync and clear conflict notes. Frame receipts now delete delivered rows instead of waiting for the next pull.")),
            .init(icon: "arrow.triangle.branch", title: String(localized: "Chains and downloads that hand off"),
                  detail: String(localized: "Task cards show the full chain, each step can set its own retry limit, and Continue reuses the previous step's successful output. A command template's finished output now feeds the next chained task. Ordinary downloads share the concurrency/time-window queue, and Settings search accepts pinyin initials.")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's New in Desire \(store.versionName)")
                        .font(.system(size: 18, weight: .semibold))
                    Text("A browser that does more of the work.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(highlights) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                Text(item.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            if sync.needsSecretMigration {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sync is paused once after this update")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Re-authorize the stored sync credentials once; later updates ask at most once.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Re-authorize") { openSyncSettings() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.08)))
            }

            HStack {
                Button("Release Notes") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/browser-rs/Desire/releases")!)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    store.dismiss()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560, height: 470)
        .onDisappear { store.markSeen() }
    }

    private func openSyncSettings() {
        store.markSeen()
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            SettingsView.SettingsSectionNavigator.shared.selected = .sync
            CommandBus.shared.send(.showSettings)
        }
    }
}
