import SwiftUI

/// 调整面板（v0.8.46 重写）：调节参数 + 滤镜预设，作用于**当前图层**，
/// 有选区时只作用选区（羽化/反选生效）。
struct ImageEditorAdjustmentsPanel: View {
    @ObservedObject private var session: ImageEditorSession
    @ObservedObject private var document: ImageEditorDocument

    @State private var params = ImageAdjustParams()
    @State private var filter: ImageFilterPreset = .none
    /// 专业滤镜（v0.8.54 专项）。
    @State private var proFilter = ImageProFilter(kind: .gaussianBlur)
    /// 曲线编辑器的直方图背景（onAppear 从活动图层位图计算）。
    @State private var histogram: (r: [Int], g: [Int], b: [Int])?

    init(session: ImageEditorSession) {
        _session = ObservedObject(wrappedValue: session)
        _document = ObservedObject(wrappedValue: session.document)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header(String(localized: "Lighting"))
                    slider(String(localized: "Brightness"), \.brightness, -0.3...0.3, format: "%.2f")
                    slider(String(localized: "Contrast"), \.contrast, 0.5...1.8, format: "%.2f")
                    slider(String(localized: "Exposure"), \.exposure, -2...2, format: "%.1f")
                    slider(String(localized: "Temperature"), \.temperature, -100...100, format: "%.0f")
                    slider(String(localized: "Tint"), \.tint, -100...100, format: "%.0f")

                    Divider().padding(.vertical, 2)
                    header(String(localized: "Color"))
                    slider(String(localized: "Saturation"), \.saturation, 0...2, format: "%.2f")
                    slider(String(localized: "Vibrance"), \.vibrance, -1...1, format: "%.2f")
                    slider(String(localized: "Highlights"), \.highlights, -1...1, format: "%.2f")
                    slider(String(localized: "Shadows"), \.shadows, -1...1, format: "%.2f")

                    Divider().padding(.vertical, 2)
                    header(String(localized: "Color Balance"))
                    slider(String(localized: "Red Balance"), \.redBalance, -0.3...0.3, format: "%.2f")
                    slider(String(localized: "Green Balance"), \.greenBalance, -0.3...0.3, format: "%.2f")
                    slider(String(localized: "Blue Balance"), \.blueBalance, -0.3...0.3, format: "%.2f")

                    Divider().padding(.vertical, 2)
                    header(String(localized: "Detail"))
                    slider(String(localized: "Sharpen"), \.sharpen, 0...2, format: "%.2f")
                    slider(String(localized: "Clarity"), \.clarity, 0...1, format: "%.2f")
                    slider(String(localized: "Vignette"), \.vignette, 0...1, format: "%.2f")

                    Divider().padding(.vertical, 2)
                    header(String(localized: "Curves"))
                    ImageEditorCurvesView(params: $params, histogram: histogram)
                        .padding(.horizontal, 2)

                    Divider().padding(.vertical, 2)
                    header(String(localized: "Levels"))
                    slider(String(localized: "Black Point"), \.blackPoint, 0...0.4, format: "%.2f")
                    slider(String(localized: "Gamma"), \.gamma, 0.2...5, format: "%.2f")
                    slider(String(localized: "White Point"), \.whitePoint, 0.6...1, format: "%.2f")

                    Divider().padding(.vertical, 2)
                    header(String(localized: "Pro Filters"))
                    Picker("", selection: $proFilter.kind) {
                        ForEach(ImageProFilter.Kind.allCases, id: \.rawValue) { kind in
                            Text(kind.localizedTitle).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .onChange(of: proFilter.kind) { _, newKind in
                        proFilter.radius = newKind.defaultRadius
                        applyProFilter()
                    }
                    HStack(spacing: 8) {
                        Text(String(localized: "Radius"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .frame(width: 78, alignment: .leading)
                        Slider(value: $proFilter.radius,
                               in: proFilter.kind.radiusRange)
                            .controlSize(.mini)
                        Text(verbatim: String(format: "%.0f", proFilter.radius))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, alignment: .trailing)
                    }
                    .onChange(of: proFilter.radius) { _, _ in
                        applyProFilter()
                    }
                    Divider().padding(.vertical, 2)
                    header(String(localized: "Filter Effect"))
                    Picker("", selection: $filter) {
                        ForEach(ImageFilterPreset.allCases) { preset in
                            Text(preset.localizedTitle).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                .padding(10)
            }
            Divider()
            VStack(spacing: 6) {
                Button {
                    document.clearPreview()
                    if !params.isNeutral { document.applyAdjust(params) }
                    if filter != .none { document.applyFilter(filter) }
                    session.flash(String(localized: "Adjustment applied"))
                } label: {
                    Label(String(localized: "Apply to Layer"), systemImage: "checkmark.circle")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(params.isNeutral && filter == .none)
                HStack(spacing: 8) {
                    Button(String(localized: "Cancel")) {
                        params = ImageAdjustParams()
                        filter = .none
                        document.clearPreview()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    Button(String(localized: "Reset")) {
                        params = ImageAdjustParams()
                        filter = .none
                        document.clearPreview()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                Text(String(localized: "Live preview · active layer · selection respected"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
        }
        .onAppear {
            // 载入活动层已落的非破坏参数（面板打开即可微调）
            if let layer = document.activeLayer {
                params = layer.adjust ?? ImageAdjustParams()
                filter = layer.filter ?? .none
            }
        }
        .onChange(of: params) { _, newValue in
            document.setPreview(adjust: newValue, filter: filter)
        }
        .onChange(of: filter) { _, newValue in
            document.setPreview(adjust: params, filter: newValue)
        }
        .onChange(of: document.activeLayerID) { _, _ in
            computeHistogram()
        }
        .onAppear { computeHistogram() }
        .onDisappear {
            document.clearPreview()
        }
    }

    /// 曲线编辑器的直方图背景（活动图层位图 → RGB 计数）。
    private func computeHistogram() {
        if let image = document.bitmap(for: document.activeLayerID) {
            histogram = ImageEditorRaster.histogram(image)
        }
    }

    /// 应用专业滤镜到活动图层。
    private func applyProFilter() {
        document.setLayerProFilter(id: session.document.activeLayerID, filter: proFilter)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func slider(_ label: String,
                        _ keyPath: WritableKeyPath<ImageAdjustParams, Double>,
                        _ range: ClosedRange<Double>,
                        format: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Slider(value: Binding(
                get: { params[keyPath: keyPath] },
                set: { params[keyPath: keyPath] = $0 }
            ), in: range)
            .controlSize(.mini)
            Text(verbatim: String(format: format, params[keyPath: keyPath]))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}
