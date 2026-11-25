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
            .init(icon: "film", title: String(localized: "Only the real videos get downloaded"),
                  detail: String(localized: "Batch download now works out which media on a page is actual content. HLS segments fold into the playlist they belong to; ads, previews and thumbnails are set aside, with a reason for each. A page with one video gives one task and a page with three gives three — no fragments, no duplicates.")),
            .init(icon: "rectangle.on.rectangle", title: String(localized: "Every video on the page, even the lazy ones"),
                  detail: String(localized: "The page resolver no longer stops at the first player it sees. It scrolls, starts each player and waits for the list to settle, so videos that only load as they come into view are collected too. The tool that lists a page's videos shows the content and the excluded items side by side.")),
            .init(icon: "globe", title: String(localized: "Site rules that stay on their own site and keep improving"),
                  detail: String(localized: "How to find the videos on a detail page, how many there are and how fast to pull them is stored in that site's own DPP adapter and applies nowhere else. Every task sharpens it: an address that expires mid-download shortens the validity window, rate limiting lowers the connection count, and a rule that stops matching is flagged for relearning. Each change is recorded and the previous version is kept.")),
            .init(icon: "speedometer", title: String(localized: "Long videos download in parallel and recover from an expired address"),
                  detail: String(localized: "HLS segments are fetched concurrently instead of one after another — more than five times faster on a rate-limited source. A signed address that expires part-way is noticed at once: the page is resolved again and the download resumes from the segments already fetched.")),
            .init(icon: "square.and.arrow.down", title: String(localized: "Downloads choose their method with evidence"),
                  detail: String(localized: "Before a download starts, the engine reads the stream — on-demand or live, quality variants, encryption, separate audio tracks — and decides how to fetch it, logging the reasons. The first segments are timed to set the connection count, and the agent can ask for the same assessment, with measured speed and an ETA, instead of guessing or writing its own downloader.")),
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
