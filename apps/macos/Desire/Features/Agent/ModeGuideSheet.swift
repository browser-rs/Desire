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
            HStack {
                Spacer()
                Button(String(localized: "Got it")) { onClose() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
