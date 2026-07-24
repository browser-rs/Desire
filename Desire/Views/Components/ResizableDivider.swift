import SwiftUI

/// A vertical divider that users can drag to resize an adjacent panel.
/// The dragged distance is subtracted from the panel width (dragging left
/// makes the panel narrower, right makes it wider). Clamped to `range`.
struct ResizableDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>

    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15))
            .frame(width: 4)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let newWidth = (width - value.translation.width)
                            .clamped(to: range)
                        width = newWidth
                    }
            )
    }
}

/// Clamps `CGFloat` to a ClosedRange. Inlined as an extension to keep the
/// call site clean.
extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
