import SwiftUI

/// Inline FULL ACCESS toggle pill for the input bar (left utility group).
/// One click toggles — no menu digging. Orange = all tools run without
/// approval (including code execution); muted = normal approval gating.
struct AgentFullAccessPill: View {
    @ObservedObject var store: AgentSessionStore

    var body: some View {
        Button {
            store.fullAccess.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: store.fullAccess ? "shield.lefthalf.filled" : "shield")
                    .font(.system(size: 9, weight: .medium))
                Text("Full Access")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(store.fullAccess ? Color.orange : Color.secondary)
            .padding(.horizontal, 9)
            // 与输入栏其它控件同高、同描边（此前 20pt 胶囊和 28pt 圆钮混在一起）。
            .frame(height: 26)
            .background(
                Capsule().fill(
                    store.fullAccess
                        ? Color.orange.opacity(0.15)
                        : Color(nsColor: .controlBackgroundColor).opacity(0.6)
                )
            )
            .overlay(
                Capsule().stroke(
                    (store.fullAccess ? Color.orange.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.4)),
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("All tools run without approval — including code execution")
        .animation(.hoverFast, value: store.fullAccess)
    }
}
