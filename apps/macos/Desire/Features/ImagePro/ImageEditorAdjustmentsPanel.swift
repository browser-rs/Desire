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
    /// 渐变映射（v0.8.54 批 6）：暗部/亮部颜色（两个 stop）。
    @State private var gmShadow: Color = Color(red: 0.12, green: 0.07, blue: 0.25)
    @State private var gmHighlight: Color = Color(red: 1.0, green: 0.92, blue: 0.75)
    @State private var gmEnabled = false
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
                    header(String(localized: "Gradient Map"))
                    Toggle(isOn: $gmEnabled) {
                        Text(String(localized: "Enable Gradient Map"))
                            .font(.system(size: 10.5))
                    }
                    .toggleStyle(.checkbox)
                    HStack(spacing: 12) {
                        ColorPicker(String(localized: "Shadows"), selection: $gmShadow,
                                    supportsOpacity: false)
                            .font(.system(size: 10.5))
                        ColorPicker(String(localized: "Highlights"), selection: $gmHighlight,
                                    supportsOpacity: false)
                            .font(.system(size: 10.5))
                    }
                    HStack(spacing: 6) {
                        duotoneButton(shadow: Color(red: 0.17, green: 0.06, blue: 0.33),
                                      highlight: Color(red: 1.0, green: 0.62, blue: 0.37),
                                      name: "Sunset")
                        duotoneButton(shadow: Color(red: 0.06, green: 0.13, blue: 0.15),
                                      highlight: Color(red: 0.17, green: 0.33, blue: 0.39),
                                      name: "Deep Sea")
                        duotoneButton(shadow: Color(red: 0.25, green: 0.16, blue: 0.35),
                                      highlight: Color(red: 0.18, green: 0.5, blue: 0.93),
                                      name: "Violet")
                        duotoneButton(shadow: Color(red: 0.23, green: 0.11, blue: 0.44),
                                      highlight: Color(red: 0.84, green: 0.43, blue: 0.47),
                                      name: "Retro")
                        Spacer(minLength: 2)
                    }
                    .onChange(of: gmEnabled) { _, on in
                        syncGradientMap(enabled: on)
                    }
                    .onChange(of: gmShadow) { _, _ in
                        if gmEnabled { syncGradientMap(enabled: true) }
                    }
                    .onChange(of: gmHighlight) { _, _ in
                        if gmEnabled { syncGradientMap(enabled: true) }
                    }

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

    private func duotoneButton(shadow: Color, highlight: Color, name: String) -> some View {
        Button {
            gmShadow = shadow
            gmHighlight = highlight
            gmEnabled = true
            syncGradientMap(enabled: true)
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [shadow, highlight],
                                     startPoint: .bottom, endPoint: .top))
                .frame(width: 34, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(.white.opacity(0.2), lineWidth: 0.5))
                .help(name)
        }
        .buttonStyle(.plain)
    }

    private func hexString(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB)
        let r = Int(round((ns?.redComponent ?? 0) * 255))
        let g = Int(round((ns?.greenComponent ?? 0) * 255))
        let b = Int(round((ns?.blueComponent ?? 0) * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private func syncGradientMap(enabled: Bool) {
        params.gradientMapStops = enabled
            ? [ImageAdjustParams.GradientMapStop.shadow(hexString(gmShadow)),
               ImageAdjustParams.GradientMapStop.highlight(hexString(gmHighlight))]
            : []
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
