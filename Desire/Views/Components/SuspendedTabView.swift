import SwiftUI

struct SuspendedTabView: View {
    let tab: Tab

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Tab Suspended")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Click to reload — \(tab.displayTitle)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Reload") {
                reload()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onTapGesture {
            reload()
        }
    }

    private func reload() {
        tab.isSuspended = false
        tab.lastAccessed = Date()
        tab.restoreSuspendedState()
    }
}
