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
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
