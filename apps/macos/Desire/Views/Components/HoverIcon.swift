import SwiftUI

struct HoverIcon: View {
    let systemName: String
    let action: () -> Void
    var disabled: Bool = false
    var help: String = ""

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: .radiusButton)
                        .fill(isHovering && !disabled
                              ? Color(nsColor: .controlBackgroundColor)
                              : Color.clear)
                )
                .contentShape(Rectangle())
                .animation(.hoverFast, value: isHovering)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        // v0.7.28：图标按钮的统一可读标签（help 是唯一的语义来源；没有
        // help 时退回 SF Symbol 名，至少让 VoiceOver 不是"按钮"而已）。
        .accessibilityLabel(Text(help.isEmpty ? systemName : help))
        .onHover { isHovering = $0 }
    }
}

#Preview {
    HStack(spacing: 8) {
        HoverIcon(systemName: "bookmark", action: {})
        HoverIcon(systemName: "bookmark.fill", action: {}, help: "删除书签")
        HoverIcon(systemName: "arrow.down.circle", action: {}, disabled: true)
        HoverIcon(systemName: "ellipsis", action: {})
    }
    .padding()
}
