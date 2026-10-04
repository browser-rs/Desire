import SwiftUI

/// Floating bar shown next to a text selection, offering one-tap AI actions
/// on the selected text (explain / translate / bring into the AI panel).
struct SelectionAIBar: View {
    let onExplain: () -> Void
    let onTranslate: () -> Void
    let onAsk: () -> Void
    /// 划选高亮（0.3.7）：色板下标回调（AnnotationStore.palette）。
    var onHighlight: ((Int) -> Void)? = nil
    private let highlightColors = ["#ffe066", "#b2f2bb", "#a5d8ff", "#fcc2d7"]

    var body: some View {
        HStack(spacing: 2) {
            barButton("解释", icon: "text.bubble", action: onExplain)
            barButton("翻译", icon: "character.bubble", action: onTranslate)
            barButton("问 Agent", icon: "wand.and.stars", action: onAsk)
            if let onHighlight {
                Divider().frame(height: 14)
                ForEach(0..<4, id: \.self) { i in
                    Button {
                        onHighlight(i)
                    } label: {
                        Circle()
                            .fill(Color(hex: highlightColors[i]))
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
                            .padding(2)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Highlight")
                }
            }
        }
        .padding(3)
        .background(.bar)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .overlay(
            Capsule().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }

    private func barButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .imageScale(.small)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
