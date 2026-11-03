import CoreGraphics
import SwiftUI

/// 直方图（v0.8.41）：亮度 + RGB 三通道实时小图。
/// 计算在后台 Task（128×128 降采样），主线程只画。
struct ImageHistogramView: View {
    let image: CGImage

    struct Counts: Equatable {
        var lum: [Int]
        var red: [Int]
        var green: [Int]
        var blue: [Int]
        var maxCount: Int
    }

    @State private var counts: Counts?

    var body: some View {
        VStack(spacing: 2) {
            if let counts {
                Canvas { context, size in
                    draw(counts, in: size, context: context)
                }
                .frame(width: 132, height: 64)
            } else {
                ProgressView()
                    .frame(width: 132, height: 64)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.primary.opacity(0.08)))
        .task(id: image) {
            let source = image
            let computed = await Task.detached(priority: .userInitiated) {
                Self.compute(source)
            }.value
            counts = computed
        }
    }

    private func draw(_ counts: Counts, in size: CGSize, context: GraphicsContext) {
        let background = CGRect(origin: .zero, size: size)
        context.fill(Path(background), with: .color(Color.black.opacity(0.55)))
        let barWidth = size.width / 256
        let scale = counts.maxCount > 0
            ? size.height / CGFloat(counts.maxCount) : 0

        func channelPath(_ values: [Int], close: Bool) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * barWidth + barWidth / 2
                let height = CGFloat(value) * scale
                path.addLine(to: CGPoint(x: x, y: size.height - height))
            }
            if close {
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
            }
            return path
        }

        let redPath = channelPath(counts.red, close: true)
        let greenPath = channelPath(counts.green, close: true)
        let bluePath = channelPath(counts.blue, close: true)
        let lumPath = channelPath(counts.lum, close: false)

        context.fill(redPath, with: .color(.red.opacity(0.35)))
        context.fill(greenPath, with: .color(.green.opacity(0.35)))
        context.fill(bluePath, with: .color(.blue.opacity(0.35)))
        context.stroke(lumPath, with: .color(.white.opacity(0.8)), lineWidth: 1)
    }

    nonisolated static func compute(_ image: CGImage) -> Counts {
        let target = 128
        guard let context = CGContext(
            data: nil, width: target, height: target,
            bitsPerComponent: 8, bytesPerRow: target * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return Counts(lum: .init(repeating: 0, count: 256),
                          red: .init(repeating: 0, count: 256),
                          green: .init(repeating: 0, count: 256),
                          blue: .init(repeating: 0, count: 256), maxCount: 1)
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let data = context.data else {
            return Counts(lum: .init(repeating: 0, count: 256),
                          red: .init(repeating: 0, count: 256),
                          green: .init(repeating: 0, count: 256),
                          blue: .init(repeating: 0, count: 256), maxCount: 1)
        }
        let buffer = data.bindMemory(to: UInt8.self, capacity: target * target * 4)
        var lum = [Int](repeating: 0, count: 256)
        var red = [Int](repeating: 0, count: 256)
        var green = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256)
        for index in 0..<(target * target) {
            let r = Double(buffer[index * 4])
            let g = Double(buffer[index * 4 + 1])
            let b = Double(buffer[index * 4 + 2])
            let luma = 0.299 * r + 0.587 * g + 0.114 * b
            let bucket = min(255, Int(luma.rounded()))
            red[Int(r)] += 1
            green[Int(g)] += 1
            blue[Int(b)] += 1
            lum[bucket] += 1
        }
        var peak = 1
        for values in [lum, red, green, blue] {
            if let value = values.max(), value > peak { peak = value }
        }
        let maxCount = max(1, peak)
        return Counts(lum: lum, red: red, green: green, blue: blue,
                      maxCount: maxCount)
    }
}
