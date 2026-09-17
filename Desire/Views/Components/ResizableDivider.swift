import SwiftUI

/// A vertical divider that users can drag to resize an adjacent panel.
/// The dragged distance is subtracted from the panel width (dragging left
/// makes the panel narrower, right makes it wider). Clamped to `range`.
struct ResizableDivider: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>

    @State private var isHovering = false
    /// Width captured on the first drag tick — subtracting the CUMULATIVE
    /// translation from the ALREADY-UPDATED width compounded every frame
    /// (drag 10px → panel jumped 20 → 40 …), which felt like "can't drag".
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(isHovering ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.22))
            .frame(width: 5)
            // 11pt hit target around the 5pt visible strip — a hairline is
            // nearly impossible to grab.
            .contentShape(Rectangle().inset(by: -3))
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = width }
                        width = (dragStartWidth! - value.translation.width)
                            .clamped(to: range)
                    }
                    .onEnded { _ in dragStartWidth = nil }
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
