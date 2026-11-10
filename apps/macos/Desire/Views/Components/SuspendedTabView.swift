import SwiftUI

struct SuspendedTabView: View {
    let tab: Tab

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(String(localized: "Tab Suspended"))
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(tab.displayTitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 24)
            Text(String(localized: "Click to reload"))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button(String(localized: "Reload")) {
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
