import SwiftUI

/// 划词就地结果卡（v0.7.25 旗舰）：贴在划词处的流式小卡——解释/翻译/词典
/// 不再绕道 Agent 面板烧回合。状态全在 `SelectionAssistCardModel`，本视图零逻辑。
struct SelectionInPlaceCard: View {
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var model: SelectionAssistCardModel
    let onClose: () -> Void
    let onCopy: (String) -> Void
    let onSpeak: (String) -> Void
    let onToWhiteboard: (String) -> Void
    let onFindRelated: (String) -> Void
    let onAsk: (String) -> Void

    private var modeIcon: String {
        switch model.mode {
        case .explain: "text.bubble"
        case .translate: "character.bubble"
        case .dictionary: "character.book.closed"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: modeIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(appAccent)
                Text(model.mode.title)
                    .font(.footnote.weight(.semibold))
                Text(model.sourceText.prefix(18) + (model.sourceText.count > 18 ? "…" : ""))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Group {
                switch model.phase {
                case .idle:
                    Text("准备中…")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                case .streaming:
                    ScrollView {
                        Text(model.text.isEmpty ? "…" : model.text)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                case .done:
                    ScrollView {
                        Text(model.text)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 4) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text("可点「追问」转 Agent 面板处理。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 6) {
                if model.phase == .streaming {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                if !model.text.isEmpty {
                    cardButton("相关内容", "text.magnifyingglass") { onFindRelated(model.sourceText) }
                    cardButton("复制", "doc.on.doc") { onCopy(model.text) }
                    cardButton("朗读", "speaker.wave.2") { onSpeak(model.text) }
                    cardButton("进白板", "rectangle.on.rectangle") { onToWhiteboard(model.text) }
                }
                cardButton("追问", "wand.and.stars") { onAsk(model.text) }
            }
        }
        .padding(10)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 4)
        )
    }

    private func cardButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10.5))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
