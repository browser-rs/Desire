import SwiftUI

struct EntryRow: View {
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).font(.body)
                Text(subtitle).lineLimit(1).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

@ViewBuilder
func emptyState(_ message: String) -> some View {
    VStack {
        Spacer()
        Text(message).foregroundStyle(.secondary)
        Spacer()
    }
    .frame(maxWidth: .infinity)
}
