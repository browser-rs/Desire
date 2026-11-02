import SwiftUI

/// 书架顶部的同步状态条（v0.8.37）：只在同步中或 ebooks 域失败时出现。
struct EbookSyncStatusStrip: View {
    @ObservedObject var store: SyncStore

    private var failure: String? {
        if case .failed(let message)? = store.domainStatus[.ebooks] {
            return message
        }
        return nil
    }

    var body: some View {
        if let failure {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text(String(localized: "Books sync failed: \(failure)"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button(String(localized: "Open Sync Settings")) {
                    CommandBus.shared.send(.showSettingsSection("sync"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.08))
        } else if store.isSyncing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Syncing books…"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 5)
        }
    }
}
