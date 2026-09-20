import SwiftUI

/// Device-size drag handles rendered at the edges of the responsive
/// viewport: corner (width+height), right edge (width), bottom edge
/// (height). A live size badge appears while dragging.
struct DragHandleOverlay: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @Binding var config: ResponsiveConfig
    let viewportSize: CGSize

    @State private var dragStartW: Int = 0
    @State private var dragStartH: Int = 0
    @State private var activeGrips: GripSet = []

    struct GripSet: OptionSet {
        let rawValue: Int
        static let width = GripSet(rawValue: 1 << 0)
        static let height = GripSet(rawValue: 1 << 1)
    }

    var body: some View {
        let w = viewportSize.width
        let h = viewportSize.height

        ZStack {
            // 右下角柄：宽高同时拖
            HandleGlyph(grips: [.width, .height])
                .position(x: w, y: h)
                .gesture(resizeGesture([.width, .height]))

            // 右缘柄：只拖宽
            HandleGlyph(grips: [.width])
                .position(x: w, y: h / 2)
                .gesture(resizeGesture([.width]))

            // 底缘柄：只拖高
            HandleGlyph(grips: [.height])
                .position(x: w / 2, y: h)
                .gesture(resizeGesture([.height]))

            // 拖动中的实时尺寸徽标（主流设备模式的 size overlay）
            if activeGrips.isEmpty == false {
                Text("\(config.customWidth) × \(config.customHeight)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(appAccent.opacity(0.92)))
                    .position(x: w / 2, y: h + 26)
                    .transition(.opacity)
            }
        }
        .animation(.hoverFast, value: activeGrips)
    }

    private func resizeGesture(_ grips: GripSet) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartW == 0 {
                    dragStartW = config.customWidth
                    dragStartH = config.customHeight
                }
                activeGrips = grips
                config.selectedPresetID = nil
                if grips.contains(.width) {
                    config.customWidth = max(200, dragStartW + Int(value.translation.width))
                }
                if grips.contains(.height) {
                    config.customHeight = max(200, dragStartH + Int(value.translation.height))
                }
            }
            .onEnded { _ in
                dragStartW = 0
                dragStartH = 0
                activeGrips = []
            }
    }
}

/// 把手视觉：accent 实心圆 + 白描边 + 握纹方向随轴。
private struct HandleGlyph: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    var grips: DragHandleOverlay.GripSet

    var body: some View {
        ZStack {
            Circle()
                .fill(appAccent)
                .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
            Group {
                if grips.contains(.width) && grips.contains(.height) {
                    VStack(spacing: 2) {
                        Capsule().frame(width: 9, height: 1.5)
                        Capsule().frame(width: 9, height: 1.5)
                    }
                } else if grips.contains(.width) {
                    VStack(spacing: 2) {
                        Capsule().frame(width: 1.5, height: 4)
                        Capsule().frame(width: 1.5, height: 4)
                    }
                } else {
                    HStack(spacing: 2) {
                        Capsule().frame(width: 4, height: 1.5)
                        Capsule().frame(width: 4, height: 1.5)
                    }
                }
            }
            .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: 18, height: 18)
        .contentShape(Circle().inset(by: -6))
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}
