import SwiftUI

struct CapsuleButton: View {
    let systemName: String
    let action: () -> Void

    var disabled: Bool = false
    var help: String? = nil
    var size: CGFloat = 16

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size))
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.4))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering && isEnabled
                              ? Color(nsColor: .controlBackgroundColor)
                              : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help ?? "")
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}

#Preview {
    HStack(spacing: 8) {
        CapsuleButton(systemName: "chevron.left", action: {})
        CapsuleButton(systemName: "chevron.right", action: {}, help: "前进")
        CapsuleButton(systemName: "arrow.clockwise", action: {})
        CapsuleButton(systemName: "house", action: {})
        CapsuleButton(systemName: "xmark", action: {}, disabled: true)
    }
    .padding()
}
