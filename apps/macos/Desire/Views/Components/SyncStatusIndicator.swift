import SwiftUI

/// 同步状态点（v0.7.25 可发现性）：常态可见的同步健康指示——此前只在失效时
/// 才有通知/横幅，正常/同步中/未登录都无处可见。点击打开设置（Sync 区块）。
struct SyncStatusIndicator: View {
    @ObservedObject var store: SyncStore

    private var health: SyncHealth {
        let signedIn: Bool = {
            if case .signedIn = store.authState { return true }
            return false
        }()
        return SyncHealth.derive(signedIn: signedIn, syncing: store.isSyncing,
                                 hasError: store.lastError != nil)
    }

    private var color: Color {
        // 旧安装的三条同步凭据还没合并：同步暂停等用户显式重新授权。
        if store.needsSecretMigration { return .orange }
        switch health {
        case .signedOut: return .secondary
        case .syncing: return .blue
        case .error: return .orange
        case .ok: return .green
        }
    }

    private var helpText: String {
        if store.needsSecretMigration {
            return String(localized: "Sync paused — click to re-authorize")
        }
        return health.title + " · 点击打开同步设置"
    }

    var body: some View {
        Button {
            CommandBus.shared.send(.showSettings)
        } label: {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(helpText)
    }
}
