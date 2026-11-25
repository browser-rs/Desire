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
            .init(icon: "bolt.badge.clock", title: String(localized: "The same request, remembered"),
                  detail: String(localized: "Say the same thing again and the skill you used last time loads up front: no re-exploring the workflow, no re-learning it on every run. Matching is deliberately strict — it needs two earlier runs of the same request and one unambiguous skill.")),
            .init(icon: "arrow.triangle.2.circlepath", title: String(localized: "Corrections fix the skill itself"),
                  detail: String(localized: "When you correct the agent after it followed a skill, it drafts a targeted patch — which passage, what to change, and why — and shows it right in the chat. One tap applies it, the previous version is backed up, and nothing is rewritten without your confirmation.")),
            .init(icon: "hourglass", title: String(localized: "Waiting no longer burns requests"),
                  detail: String(localized: "Long downloads, exports and conversions now end the turn with a single subscription: you are notified when they finish, and a failed one comes back to the agent automatically. The turn spinner also notices when it has been looking at the same thing too long and says so.")),
            .init(icon: "square.stack.3d.up", title: String(localized: "Tool definitions scaled to the task (experimental)"),
                  detail: String(localized: "When a repeated request loads a skill, each model request can carry only the tool definitions that skill needs — measured on our fixture at 87% fewer characters — with a way to pull in anything else on demand and an automatic fallback to the full set. Off by default until real-gateway numbers are in.")),
            .init(icon: "stethoscope", title: String(localized: "Diagnostics that tell the truth"),
                  detail: String(localized: "Main-thread stall reports no longer fire when the machine was simply asleep (32 of 33 installed-build records were sleep wake-ups), old sampling files are pruned, and diagnostics now separate app builds from development runs — plus test launches are sealed off from your preferences, keychain and browsing data.")),
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
