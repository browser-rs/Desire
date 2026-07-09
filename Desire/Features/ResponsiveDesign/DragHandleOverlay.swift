import SwiftUI

struct DragHandleOverlay: View {
    @Binding var config: ResponsiveConfig
    let viewportSize: CGSize

    @State private var dragStartW: Int = 0
    @State private var dragStartH: Int = 0

    private let cornerSize: CGFloat = 10
    private let edgeLength: CGFloat = 24
    private let edgeThickness: CGFloat = 4

    var body: some View {
        let w = viewportSize.width
        let h = viewportSize.height

        ZStack {
            ResizeCornerHandle()
                .fill(Color.accentColor)
                .frame(width: cornerSize + 4, height: cornerSize + 4)
                .position(x: w, y: h)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if dragStartW == 0 {
                                dragStartW = config.customWidth
                                dragStartH = config.customHeight
                            }
                            config.selectedPresetID = nil
                            config.customWidth = max(200, dragStartW + Int(value.translation.width))
                            config.customHeight = max(200, dragStartH + Int(value.translation.height))
                        }
                        .onEnded { _ in
                            dragStartW = 0
                            dragStartH = 0
                        }
                )

            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor.opacity(0.3))
                .frame(width: edgeThickness, height: edgeLength)
                .position(x: w, y: h / 2)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if dragStartW == 0 {
                                dragStartW = config.customWidth
                            }
                            config.selectedPresetID = nil
                            config.customWidth = max(200, dragStartW + Int(value.translation.width))
                        }
                        .onEnded { _ in
                            dragStartW = 0
                        }
                )

            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor.opacity(0.3))
                .frame(width: edgeLength, height: edgeThickness)
                .position(x: w / 2, y: h)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if dragStartH == 0 {
                                dragStartH = config.customHeight
                            }
                            config.selectedPresetID = nil
                            config.customHeight = max(200, dragStartH + Int(value.translation.height))
                        }
                        .onEnded { _ in
                            dragStartH = 0
                        }
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ResizeCornerHandle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.minY + 4))
            p.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.maxY - 4))
            p.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 4))
            p.closeSubpath()
        }
    }
}
