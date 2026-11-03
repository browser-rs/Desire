import SwiftUI

/// 曲线草稿（迭代 1）：RGB 总曲线 + 分通道。
nonisolated struct ImageCurveDraft: Codable, Equatable {
    var rgb: [ImageAdjustParams.CurvePoint] = []
    var red: [ImageAdjustParams.CurvePoint] = []
    var green: [ImageAdjustParams.CurvePoint] = []
    var blue: [ImageAdjustParams.CurvePoint] = []

    var isEmpty: Bool {
        rgb.isEmpty && red.isEmpty && green.isEmpty && blue.isEmpty
    }
}

/// 曲线编辑器（v0.8.41）：拖拽移动锚点、点按添加、双击删除。
struct ImageCurveEditorView: View {
    @Binding var draft: ImageCurveDraft
    @State private var channel: Channel = .rgb
    @State private var draggingIndex: Int?
    @State private var lastTap: (time: Date, location: CGPoint)?

    enum Channel: String, CaseIterable, Identifiable {
        case rgb, red, green, blue
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rgb: return String(localized: "RGB")
            case .red: return String(localized: "Red")
            case .green: return String(localized: "Green")
            case .blue: return String(localized: "Blue")
            }
        }
        var color: Color {
            switch self {
            case .rgb: return .white
            case .red: return .red
            case .green: return .green
            case .blue: return .blue
            }
        }
        var points: WritableKeyPath<ImageCurveDraft, [ImageAdjustParams.CurvePoint]> {
            switch self {
            case .rgb: return \.rgb
            case .red: return \.red
            case .green: return \.green
            case .blue: return \.blue
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $channel) {
                ForEach(Channel.allCases) { channel in
                    Text(channel.title).tag(channel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    Rectangle()
                        .fill(Color.black.opacity(0.75))
                    gridOverlay(size: size)
                    diagonalPath(size: size)
                    curvePath(size: size)
                    pointsLayer(size: size)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(size: size))
                .simultaneousGesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            handleTap(value.location, size: size)
                        })
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Button(String(localized: "Reset Channel")) {
                    draft[keyPath: channel.points] = []
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                Text(String(localized: "Tap to add · drag to move · double-tap to remove"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var activePoints: [ImageAdjustParams.CurvePoint] {
        draft[keyPath: channel.points]
    }

    private func gridOverlay(size: CGSize) -> some View {
        Path { path in
            for fraction in [0.25, 0.5, 0.75] {
                path.move(to: CGPoint(x: size.width * fraction, y: 0))
                path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                path.move(to: CGPoint(x: 0, y: size.height * fraction))
                path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
            }
        }
        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
    }

    private func diagonalPath(size: CGSize) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: CGPoint(x: size.width, y: 0))
        }
        .stroke(Color.white.opacity(0.25),
                style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
    }

    private func curvePath(size: CGSize) -> Path {
        let points = activePoints
        guard points.count >= 2 else { return Path() }
        var path = Path()
        let steps = 64
        for step in 0...steps {
            let x = Double(step) / Double(steps)
            let y = ImageAdjustParams.curveValue(points, at: x)
            let point = CGPoint(x: size.width * x, y: size.height * (1 - y))
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    @ViewBuilder
    private func pointsLayer(size: CGSize) -> some View {
        ForEach(Array(activePoints.enumerated()), id: \.offset) { index, point in
            Circle()
                .fill(channel.color)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
                .position(x: size.width * point.x,
                          y: size.height * (1 - point.y))
        }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let location = value.location
                if draggingIndex == nil {
                    draggingIndex = nearestPoint(at: location, size: size,
                                                 maxDistance: 18)
                }
                guard let index = draggingIndex,
                      activePoints.indices.contains(index) else { return }
                var x = (location.x / size.width).clamped(0, 1)
                let y = (1 - location.y / size.height).clamped(0, 1)
                if index == 0, activePoints.count > 1 {
                    x = min(x, activePoints[1].x - 0.01)
                }
                if index == activePoints.count - 1, activePoints.count > 1 {
                    x = max(x, activePoints[activePoints.count - 2].x + 0.01)
                }
                draft[keyPath: channel.points][index] = .init(
                    x: x.clamped(0.001, 0.999), y: y.clamped(0, 1))
            }
            .onEnded { _ in
                draggingIndex = nil
                draft[keyPath: channel.points] = ImageAdjustParams.sanitizeCurve(
                    draft[keyPath: channel.points])
            }
    }

    private func nearestPoint(at location: CGPoint, size: CGSize,
                              maxDistance: CGFloat) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, point) in activePoints.enumerated() {
            let position = CGPoint(x: size.width * point.x,
                                   y: size.height * (1 - point.y))
            let dx = position.x - location.x
            let dy = position.y - location.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < maxDistance,
               best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    /// 单击加锚点；0.35s 内二次单击同处 = 删除最近锚点。
    private func handleTap(_ location: CGPoint, size: CGSize) {
        let now = Date()
        if let last = lastTap,
           now.timeIntervalSince(last.time) < 0.35,
           abs(last.location.x - location.x) < 20,
           abs(last.location.y - location.y) < 20 {
            lastTap = nil
            removeNearestPoint(at: location, size: size)
            return
        }
        lastTap = (now, location)
        addPoint(at: location, size: size)
    }

    private func addPoint(at location: CGPoint, size: CGSize) {
        guard nearestPoint(at: location, size: size, maxDistance: 14) == nil else {
            return
        }
        let x = (location.x / size.width).clamped(0.01, 0.99)
        let y = (1 - location.y / size.height).clamped(0, 1)
        draft[keyPath: channel.points].append(.init(x: x, y: y))
        draft[keyPath: channel.points] = ImageAdjustParams.sanitizeCurve(
            draft[keyPath: channel.points])
    }

    private func removeNearestPoint(at location: CGPoint, size: CGSize) {
        guard let index = nearestPoint(at: location, size: size, maxDistance: 14),
              activePoints.count > 2 else {
            return
        }
        draft[keyPath: channel.points].remove(at: index)
        draft[keyPath: channel.points] = ImageAdjustParams.sanitizeCurve(
            draft[keyPath: channel.points])
    }
}
