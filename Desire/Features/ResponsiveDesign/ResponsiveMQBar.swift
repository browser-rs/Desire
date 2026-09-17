import SwiftUI

/// 视口上方的断点分段条（Chrome 签名元素）：每个断点一个彩色区段，
/// 当前视口宽度命中的区段高亮描边；点击区段把视口宽度设为该断点。
struct ResponsiveMQBar: View {
    let viewportWidth: CGFloat
    let onTap: (CGFloat) -> Void

    /// 标准断点（与主流框架对齐）。
    private static let breakpoints: [(label: String, min: CGFloat)] = [
        ("base", 0), ("sm", 576), ("md", 768), ("lg", 1024), ("xl", 1400),
    ]
    private static let maxRepresented: CGFloat = 1600
    private static let colors: [Color] = [
        Color(red: 0.54, green: 0.71, blue: 0.97),
        Color(red: 0.99, green: 0.84, blue: 0.39),
        Color(red: 0.51, green: 0.79, blue: 0.58),
        Color(red: 0.95, green: 0.55, blue: 0.51),
        Color(red: 0.54, green: 0.71, blue: 0.97),
    ]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Self.breakpoints.indices, id: \.self) { i in
                    let bp = Self.breakpoints[i]
                    // 最后一段覆盖到 maxRepresented，避免索引越界
                    let nextMin: CGFloat = i + 1 < Self.breakpoints.count
                        ? Self.breakpoints[i + 1].min
                        : Self.maxRepresented
                    seg(min: bp.min, max: nextMin, color: Self.colors[i % Self.colors.count])
                }
            }
        }
        .frame(height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help("点击区段切换视口宽度")
    }

    private func seg(min: CGFloat, max: CGFloat, color: Color) -> some View {
        let isActive = viewportWidth >= min && viewportWidth < max
        return ZStack {
            Rectangle().fill(color.opacity(isActive ? 0.95 : 0.45))
            if isActive {
                Text(min == 0 ? "base · \(Int(viewportWidth))px" : "\(Int(min))px+ · \(Int(viewportWidth))px")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.black.opacity(0.75))
            } else {
                Text("\(Int(min))px+")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.black.opacity(0.45))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture { onTap(Swift.max(min, 200)) }
    }
}
