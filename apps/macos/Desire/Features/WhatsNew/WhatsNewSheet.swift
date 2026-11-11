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
            .init(icon: "star.square.on.square", title: String(localized: "A bookmarks bar that finally keeps up"),
                  detail: String(localized: "Multi-level folders on the bar, drag to reorder, Open All, middle-click to open in a background tab, and an overflow menu when the bar runs out of room.")),
            .init(icon: "arrow.down.circle", title: String(localized: "The context menu pulls its weight"),
                  detail: String(localized: "Download Linked File lands in the downloads panel with pause and resume, Copy Link Text grabs the anchor's words, and Search with… picks the engine for any selection.")),
            .init(icon: "square.and.arrow.up.on.square", title: String(localized: "Send to… everywhere"),
                  detail: String(localized: "History, downloads and bookmark rows all gain the Send to… menu — drop a link onto the whiteboard, into Excerpts, or hand it to the Agent as a draft prompt.")),
            .init(icon: "scalemass", title: String(localized: "Spend less on simple turns"),
                  detail: String(localized: "Cost-aware routing gains an aggressive tier — every text-only turn runs on the free local model, falling back to the cloud when it fails — and routing decisions are visible in traces and stats.")),
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
