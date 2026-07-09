import AppKit
import SwiftUI

struct RulerOverlay: View {
    let viewportSize: CGSize

    var body: some View {
        VStack(spacing: 0) {
            RulerView(length: viewportSize.width, orientation: .horizontal)
                .frame(height: 16)
            Spacer()
        }
        .overlay(alignment: .leading) {
            RulerView(length: viewportSize.height, orientation: .vertical)
                .frame(width: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct RulerView: View {
    let length: CGFloat
    let orientation: Axis

    private let tickInterval: CGFloat = 50

    var body: some View {
        Canvas { context, size in
            let total = orientation == .horizontal ? size.width : size.height
            let majorInterval = tickInterval
            let tickCount = Int(total / majorInterval)

            for i in 0...tickCount {
                let pos = CGFloat(i) * majorInterval
                if orientation == .horizontal {
                    context.stroke(
                        Path { p in
                            p.move(to: CGPoint(x: pos, y: 0))
                            p.addLine(to: CGPoint(x: pos, y: i % 2 == 0 ? 12 : 6))
                        },
                        with: .color(Color(nsColor: .tertiaryLabelColor)),
                        lineWidth: 0.5
                    )
                    if i % 2 == 0 {
                        context.draw(
                            Text("\(i * 50)").font(.system(size: 7)).foregroundColor(Color(nsColor: .tertiaryLabelColor)),
                            at: CGPoint(x: pos + 2, y: 14)
                        )
                    }
                } else {
                    context.stroke(
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: pos))
                            p.addLine(to: CGPoint(x: i % 2 == 0 ? 12 : 6, y: pos))
                        },
                        with: .color(Color(nsColor: .tertiaryLabelColor)),
                        lineWidth: 0.5
                    )
                    if i % 2 == 0 {
                        context.draw(
                            Text("\(i * 50)").font(.system(size: 7)).foregroundColor(Color(nsColor: .tertiaryLabelColor)),
                            at: CGPoint(x: 14, y: pos + 2)
                        )
                    }
                }
            }
        }
        .frame(
            width: orientation == .horizontal ? length : 16,
            height: orientation == .horizontal ? 16 : length
        )
    }
}
