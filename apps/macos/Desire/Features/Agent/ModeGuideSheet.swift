import SwiftUI

/// 首次切到非浏览器模式的说明（v0.8.23）：一屏讲清界面与打扰边界，只出现一次。
struct ModeGuideSheet: View {
    @Environment(\.appAccent) private var appAccent
    let mode: AppUsageMode
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(appAccent)
                Text(mode.title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            Text(mode.detail)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(localized: "You can switch anytime from the Mode menu (⌃⌘1–3)."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            if mode != .browser {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "How should the agent's browser relate to your logins?"))
                        .font(.system(size: 11.5, weight: .medium))
                    HStack(spacing: 8) {
                        Button(String(localized: "Isolated container (recommended)")) {
                            AppModeStore.shared.setAgentSharesUserProfile(false)
                            onClose()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button(String(localized: "Share my login state")) {
                            AppModeStore.shared.setAgentSharesUserProfile(true)
                            onClose()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text(String(localized: "You can change this later in Settings › Usage Mode."))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Got it")) { onClose() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
