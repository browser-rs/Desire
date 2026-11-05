import SwiftUI

/// 直方图面板（迭代 16）：RGB 三通道，跟随 revision 重算。
struct ImageEditorHistogramPanel: View {
    @ObservedObject private var session: ImageEditorSession
    @ObservedObject private var document: ImageEditorDocument
    @State private var r: [Int] = []
    @State private var g: [Int] = []
    @State private var b: [Int] = []

    init(session: ImageEditorSession) {
        _session = ObservedObject(wrappedValue: session)
        _document = ObservedObject(wrappedValue: session.document)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if r.isEmpty {
                Text(String(localized: "No data"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else {
                chart(color: .red, bins: r)
                chart(color: .green, bins: g)
                chart(color: .blue, bins: b)
            }
            Spacer()
        }
        .padding(10)
        .task(id: document.revision) {
            guard let image = document.composite(),
                  let hist = ImageEditorRaster.histogram(image) else { return }
            r = hist.r; g = hist.g; b = hist.b
        }
    }

    private func chart(color: Color, bins: [Int]) -> some View {
        let maxValue = max(1, bins.max() ?? 1)
        return GeometryReader { geo in
            Path { path in
                path.move(to: CGPoint(x: 0, y: geo.size.height))
                for (index, value) in bins.enumerated() {
                    let x = geo.size.width * CGFloat(index) / 255
                    let y = geo.size.height * (1 - CGFloat(value) / CGFloat(maxValue))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                path.closeSubpath()
            }
            .fill(color.opacity(0.45))
        }
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.25)))
    }
}
