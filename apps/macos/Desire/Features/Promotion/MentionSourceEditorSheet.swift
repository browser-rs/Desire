import SwiftUI

/// 自定义提及雷达来源（v0.8.2）：搜索/社区入口 URL，用 `{query}` 占位。
struct MentionSourceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PromotionStore.shared

    @State private var name = ""
    @State private var platform = ""
    @State private var searchURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Mention Source")
                .font(.system(size: 14, weight: .semibold))
            Text("Use {query} where the keyword goes. Without it, ?q= is appended.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(String(localized: "Name"), text: $name)
                .textFieldStyle(.roundedBorder)
            TextField(String(localized: "Platform"), text: $platform)
                .textFieldStyle(.roundedBorder)
            TextField("https://example.com/search?q={query}", text: $searchURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                Button(String(localized: "Add")) {
                    if store.addMentionSource(name: name,
                                              platform: platform,
                                              searchURL: searchURL) != nil {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || searchURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
