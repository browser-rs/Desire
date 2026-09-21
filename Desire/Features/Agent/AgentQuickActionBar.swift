import SwiftUI

/// Horizontal strip of quick-action shortcuts shown above the input bar
/// once a conversation is in progress.
struct AgentQuickActionBar: View {
    let isProcessing: Bool
    var onAction: (AgentQuickAction) -> Void

    var body: some View {
        // Horizontal scroll: in the narrow sidebar the 5 pills have less
        // room than their labels need — without scrolling each button's
        // text wraps one character per line (unreadable).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(AgentQuickAction.allCases, id: \.title) { action in
                Button {
                    onAction(action)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: action.icon)
                            .font(.system(size: 10, weight: .medium))
                        Text(action.title)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    )
                    .overlay(
                        Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isProcessing)
                .help(action.prompt)
                }
            }
            Spacer(minLength: 0)
        }
        // 横向 ScrollView 在**垂直方向也是贪心的**：不给它高度，它会把消息列表与
        // 输入框之间的剩余空间全吃掉，按钮行于是"悬在面板中间"（用户实测："应该固定
        // 放置在输入框上面"）。这里固定 24pt（药丸高度），配合 AgentPanel 里给
        // `ScrollViewReader` 挂的弹性尺寸——两者缺一，剩余空间都会漏给这一行。
        // 注意：`fixedSize(vertical:)` 在这里会让内容塌成 0 高（实测整排按钮消失）。
        .frame(height: 24)
        .padding(.top, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
