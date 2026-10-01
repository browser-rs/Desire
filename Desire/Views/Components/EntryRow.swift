import SwiftUI

struct EntryRow: View {
    let title: String
    let subtitle: String
    /// 可选尾缀徽章文案（如历史行的 "×12" 访问次数）。
    var badgeText: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .lineLimit(1)
                        .font(.body)
                    if let badgeText {
                        Text(badgeText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            .clipShape(Capsule())
                    }
                }
                Text(subtitle).lineLimit(1).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    EntryRow(title: "Google", subtitle: "https://google.com", action: {})
        .padding()
}
