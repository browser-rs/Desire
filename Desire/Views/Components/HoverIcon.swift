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
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering && !disabled
                              ? Color(nsColor: .controlBackgroundColor)
                              : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
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
