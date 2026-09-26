import SwiftUI

/// 快捷动作药丸行（对应桌面 AgentQuickActionBar）。
/// 文案 / 图标由 Mac 快照下发（唯一来源，两端不硬编码）；
/// 「重新生成」与快捷动作同一行（分成两行看着像两组无关按钮）。
struct QuickActionBarView: View {
    let actions: [RemoteQuickAction]
    let canRegenerate: Bool
    let disabled: Bool
    let onAction: (String) -> Void
    let onRegenerate: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(actions) { action in
                    pill(icon: action.icon, title: action.title) { onAction(action.key) }
                }
                if canRegenerate {
                    pill(icon: "arrow.clockwise", title: "重新生成", action: onRegenerate)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 28)
    }

    private func pill(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Color(.tertiarySystemBackground))
            )
            .overlay(
                Capsule().strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
