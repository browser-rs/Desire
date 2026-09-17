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
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    store.fullAccess
                        ? Color.orange.opacity(0.15)
                        : Color(nsColor: .controlBackgroundColor).opacity(0.6)
                )
            )
            .overlay(
                Capsule().stroke(
                    (store.fullAccess ? Color.orange : Color(nsColor: .separatorColor)).opacity(0.5),
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
