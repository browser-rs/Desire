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
        switch health {
        case .signedOut: .secondary
        case .syncing: .blue
        case .error: .orange
        case .ok: .green
        }
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
        .help(health.title + " · 点击打开同步设置")
        .accessibilityLabel(health.title)
    }
}
