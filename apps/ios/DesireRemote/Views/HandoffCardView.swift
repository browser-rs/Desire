import SwiftUI

/// **Apple Handoff 接力卡**（v0.8.67 批 2）：Mac 端 Desire 停在某个网页 →
/// iPhone 锁屏/多任务系统接力 → 点开进 app，本卡覆盖显示继续浏览上下文。
/// 三动作与既有通道一一对应：在 Mac 上打开（openOnMac，0.8.38 的
/// `openURL` 帧）/ 复制链接 / 问 Agent（0.8.66 AskAgent 的 prompt 通道）。
struct HandoffCardView: View {
    @EnvironmentObject var client: RemoteClient
    let item: RemoteClient.HandoffItem
    let onDismiss: () -> Void
    @State private var asked = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title?.isEmpty == false ? item.title! : item.url.host ?? "网页")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(item.url.absoluteString)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 8) {
                actionButton(icon: "macwindow", label: "在 Mac 上打开", filled: true) {
                    client.openOnMac(url: item.url.absoluteString)
                    onDismiss()
                }
                actionButton(icon: "doc.on.doc", label: copied ? "已复制" : "复制链接", filled: false) {
                    UIPasteboard.general.string = item.url.absoluteString
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                actionButton(icon: "questionmark.bubble", label: asked ? "已发送" : "问 Agent", filled: false) {
                    client.sendPrompt("请打开网页「\(item.url.absoluteString)」，读取内容后给我一份简明总结。")
                    asked = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        asked = false
                        onDismiss()
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5))
    }

    private func actionButton(icon: String, label: String, filled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Capsule().fill(
                    filled ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }
}
