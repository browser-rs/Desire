import AppKit
import SwiftUI

/// 阅读回顾卡（v0.8.36）：本地摘要 + 复制 / 交给 Agent 写一段。
struct ReadingDigestView: View {
    @Environment(\.appAccent) private var appAccent
    let markdown: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "book.pages")
                    .font(.system(size: 12))
                    .foregroundStyle(appAccent)
                Text(String(localized: "Reading Review"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(String(localized: "Done")) { onClose() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(14)
            Divider()
            ScrollView {
                Text(markdown)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            Divider()
            HStack(spacing: 8) {
                Button(String(localized: "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                Button(String(localized: "Ask Agent to Write")) {
                    AgentDraftInbox.shared.send(
                        markdown + "\n\n"
                            + String(localized: "Write a short, encouraging weekly reading review from this digest. Mention one book and one highlight; keep it under 150 words."))
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)
        }
        .frame(width: 600, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
