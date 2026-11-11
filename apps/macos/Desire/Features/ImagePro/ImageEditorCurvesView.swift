import SwiftUI

/// 交互式曲线编辑器（v0.8.54 批 1）：RGB 总曲线 + R/G/B 分通道，
/// 拖拽控制点（0…1 归一化坐标）、点击空白添加点、双击移除最近点。
/// 数据写入 `ImageAdjustParams.curvePoints` / `curveRed` / `curveGreen` /
/// `curveBlue`——实时预览走既有 `document.setPreview(adjust:)` 管线。
struct ImageEditorCurvesView: View {
    /// 绑定到面板的 params（实时预览由面板 onChange 驱动）。
    @Binding var params: ImageAdjustParams
    /// 背景直方图（nil = 不显示）。
    let histogram: (r: [Int], g: [Int], b: [Int])?

    enum Channel: String, CaseIterable {
        case rgb = "RGB"
        case red = "R"
        case green = "G"
        case blue = "B"

        var color: Color {
            switch self {
            case .rgb: return .white
            case .red: return .red
            case .green: return .green
            case .blue: return .blue
            }
        }
    }

    @State private var channel: Channel = .rgb
    /// 正在拖拽的控制点索引（nil = 没有拖拽中）。
    @State private var draggingIndex: Int?
    /// 双击移除用的最后点击时间（区分拖拽结束 vs 双击第二击）。
    @State private var lastTapEnd: Date = .distantPast

    private let size: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            channelPicker
            ZStack {
                gridBackdrop
                histogramBars
                curveStroke
                controlDots
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onTapGesture(count: 2) { location in
                removeNearest(location)
            }
            HStack {
                Button("Reset") { setCurve([]) }
                    .font(.system(size: 10))
                    .buttonStyle(.borderless)
                    .disabled(currentCurve.isEmpty)
                Spacer()
                Text("\(pointCount) pt")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var pointCount: Int { currentCurve.count }

    // MARK: - 曲线数据读写

    private var currentCurve: [ImageAdjustParams.CurvePoint] {
        switch channel {
        case .rgb: return params.curvePoints
        case .red: return params.curveRed
        case .green: return params.curveGreen
        case .blue: return params.curveBlue
        }
    }

    private func setCurve(_ points: [ImageAdjustParams.CurvePoint]) {
        let sanitized = ImageAdjustParams.sanitizeCurve(points)
        switch channel {
        case .rgb: params.curvePoints = sanitized
        case .red: params.curveRed = sanitized
        case .green: params.curveGreen = sanitized
        case .blue: params.curveBlue = sanitized
        }
    }

    // MARK: - 坐标转换

    private func toScreen(_ point: ImageAdjustParams.CurvePoint) -> CGPoint {
        CGPoint(x: point.x * size, y: size - point.y * size)
    }

    private func toCurvePoint(_ location: CGPoint) -> ImageAdjustParams.CurvePoint {
        ImageAdjustParams.CurvePoint(
            x: (location.x / size).clamped(0, 1),
            y: ((size - location.y) / size).clamped(0, 1)
        )
    }

    /// 曲线在任意 x 的 y 屏幕坐标（与 pipeline 的线性插值一致）。
    private func screenY(at x: Double) -> CGFloat {
        let y = ImageAdjustParams.curveValue(currentCurve, at: x)
        return size - CGFloat(y) * size
    }

    // MARK: - 视图层

    private var channelPicker: some View {
        Picker("", selection: $channel) {
            ForEach(Channel.allCases, id: \.self) { ch in
                Text(ch.rawValue).tag(ch)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
    }

    private var gridBackdrop: some View {
        Canvas { ctx, canvasSize in
            for i in 1...3 {
                let t = canvasSize.width * CGFloat(i) / 4
                ctx.stroke(Path { $0.move(to: CGPoint(x: t, y: 0)); $0.addLine(to: CGPoint(x: t, y: canvasSize.height)) },
                           with: .color(.white.opacity(0.08)), lineWidth: 0.5)
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: t)); $0.addLine(to: CGPoint(x: canvasSize.width, y: t)) },
                           with: .color(.white.opacity(0.08)), lineWidth: 0.5)
            }
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: canvasSize.height)); $0.addLine(to: CGPoint(x: canvasSize.width, y: 0)) },
                       with: .color(.white.opacity(0.15)), lineWidth: 1)
        }
        .background(Color.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.15), lineWidth: 0.5))
    }

    @ViewBuilder
    private var histogramBars: some View {
        if let hist = histogram, hist.r.count > 0 {
            let maxCount = max(hist.r.max() ?? 0, hist.g.max() ?? 0, hist.b.max() ?? 0)
            Canvas { ctx, canvasSize in
                let barCount = hist.r.count
                let barWidth = canvasSize.width / CGFloat(barCount)
                for (values, color) in [(hist.r, Color.red), (hist.g, Color.green), (hist.b, Color.blue)] {
                    for (i, count) in values.enumerated() {
                        guard count > 0, maxCount > 0 else { continue }
                        let height = min(canvasSize.height, CGFloat(count) / CGFloat(maxCount) * canvasSize.height * 0.85)
                        let bar = CGRect(x: CGFloat(i) * barWidth,
                                         y: canvasSize.height - height,
                                         width: barWidth, height: height)
                        ctx.fill(Path(bar), with: .color(color.opacity(0.25)))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var curveStroke: some View {
        if currentCurve.count >= 2 {
            Path { p in
                for step in 0...60 {
                    let t = Double(step) / 60
                    p.addLine(to: CGPoint(x: CGFloat(t) * size, y: screenY(at: t)))
                }
            }
            .stroke(channel.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }

    @ViewBuilder
    private var controlDots: some View {
        ForEach(Array(currentCurve.enumerated()), id: \.offset) { _, point in
            let screen = toScreen(point)
            Circle()
                .fill(channel.color)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(.white, lineWidth: 1))
                .position(screen)
        }
    }

    // MARK: - 手势

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let curve = currentCurve
                if let idx = draggingIndex, idx < curve.count {
                    // 拖动现有控制点（x 保持顺序：与前/后控制点之间）
                    var newPoint = toCurvePoint(value.location)
                    let minXP = idx > 0 ? curve[idx - 1].x + 0.02 : 0
                    let maxXP = idx < curve.count - 1 ? curve[idx + 1].x - 0.02 : 1
                    newPoint.x = newPoint.x.clamped(minXP, maxXP)
                    newPoint.y = newPoint.y.clamped(0, 1)
                    var updated = curve
                    updated[idx] = newPoint
                    setCurve(updated)
                } else {
                    // 首次按下：找到最近控制点（<16pt）开始拖拽；否则添加新点
                    let location = value.location
                    var nearestIdx: Int?
                    var nearestDist = CGFloat(16)
                    for (i, point) in curve.enumerated() {
                        let screen = toScreen(point)
                        let dist = hypot(screen.x - location.x, screen.y - location.y)
                        if dist < nearestDist {
                            nearestDist = dist
                            nearestIdx = i
                        }
                    }
                    if let idx = nearestIdx {
                        draggingIndex = idx
                    } else {
                        // 点击空白 → 添加新控制点
                        let newPoint = toCurvePoint(location)
                        var updated = curve
                        let insertAt = updated.firstIndex(where: { $0.x > newPoint.x }) ?? updated.count
                        updated.insert(newPoint, at: insertAt)
                        setCurve(updated)
                        draggingIndex = insertAt
                    }
                }
            }
            .onEnded { _ in
                // 双击移除在 onTapGesture(count: 2) 里处理；这里只重置拖拽。
                draggingIndex = nil
            }
    }

    private func removeNearest(_ location: CGPoint) {
        let now = Date()
        guard now.timeIntervalSince(lastTapEnd) > 0.3 else { return } // 防拖拽结束误触发
        lastTapEnd = now
        let curve = currentCurve
        guard curve.count > 2 else { return } // 至少保留 2 个控制点
        let tapPoint = toCurvePoint(location)
        if let nearest = curve.nearest(to: tapPoint),
           nearest.distance < 0.06 {
            var updated = curve
            updated.remove(at: nearest.index)
            setCurve(updated)
        }
    }
}

// MARK: - 最近点查找

extension [ImageAdjustParams.CurvePoint] {
    func nearest(to point: ImageAdjustParams.CurvePoint) -> (index: Int, distance: Double)? {
        var best: (Int, Double)?
        for (i, p) in enumerated() {
            let dist = hypot(p.x - point.x, p.y - point.y)
            if best == nil || dist < best!.1 {
                best = (i, dist)
            }
        }
        return best
    }
}
