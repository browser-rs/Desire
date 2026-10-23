import SwiftUI

/// 回复台（v0.8.3）：拟稿 → 打开页面并**只填入** → 用户自己按发送 →
/// Mark replied。绝不自动发送。
struct PromotionReplySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent
    @ObservedObject private var store = PromotionStore.shared
    let interaction: PromotionInteraction
    var onSendToAgent: ((String) -> Void)? = nil

    @State private var text: String
    @State private var result: PromotionReplyHelper.Result?
    @State private var working = false

    init(interaction: PromotionInteraction, onSendToAgent: ((String) -> Void)? = nil) {
        self.interaction = interaction
        self.onSendToAgent = onSendToAgent
        _text = State(initialValue: interaction.reply ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            VStack(alignment: .leading, spacing: 4) {
                Text(interaction.text)
                    .font(.system(size: 11.5))
                    .textSelection(.enabled)
                    .lineLimit(6)
                if let post = interaction.postTitle, !post.isEmpty {
                    Text("「\(post)」")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
            TextEditor(text: $text)
                .font(.system(size: 12))
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
            HStack(spacing: 8) {
                Button(String(localized: "Use Template")) {
                    text = PromotionReplyDesk.template(for: interaction.kind)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                if let onSendToAgent {
                    Button(String(localized: "Ask Agent to Draft")) {
                        _ = store.replyInteraction(id: interaction.id, reply: text.isEmpty ? nil : text, status: nil)
                        onSendToAgent(PromotionReplyDesk.draftPrompt(for: interaction))
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if let result {
                Text(result.message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(result.ok ? Color.secondary : Color.orange)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(String(localized: "Ignore")) {
                    _ = store.replyInteraction(id: interaction.id, reply: nil, status: .ignored)
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if interaction.status != .replied {
                    Button(String(localized: "Mark Replied")) {
                        _ = store.replyInteraction(id: interaction.id,
                                                   reply: text.isEmpty ? nil : text,
                                                   status: .replied)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button {
                    runFill()
                } label: {
                    if working {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(String(localized: "Open & Fill"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(String(localized: "Close")) { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 540, height: 430)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(appAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(interaction.platform) · \(interaction.author)")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(interaction.kind.rawValue)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let url = interaction.url ?? interaction.postURL, let link = URL(string: url) {
                Link(destination: link) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func runFill() {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        working = true
        result = nil
        // 先保存草稿文本（用户可能在页面上发送后再回来 Mark replied）。
        _ = store.replyInteraction(id: interaction.id, reply: reply, status: nil)
        Task { @MainActor in
            let outcome = await PromotionReplyHelper.prepare(interaction: interaction, text: reply)
            working = false
            result = outcome
            if outcome.ok {
                // sheet 会挡住页面：填入成功后立即收起，让用户检查并自己按发送。
                dismiss()
            }
        }
    }
}
