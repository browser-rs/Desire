import SwiftUI

/// 调整面板（v0.8.46 重写）：调节参数 + 滤镜预设，作用于**当前图层**，
/// 有选区时只作用选区（羽化/反选生效）。
struct ImageEditorAdjustmentsPanel: View {
    @ObservedObject private var session: ImageEditorSession
    @ObservedObject private var document: ImageEditorDocument

    @State private var params = ImageAdjustParams()
    @State private var filter: ImageFilterPreset = .none

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
                    header(String(localized: "Detail"))
                    slider(String(localized: "Sharpen"), \.sharpen, 0...2, format: "%.2f")
                    slider(String(localized: "Clarity"), \.clarity, 0...1, format: "%.2f")
                    slider(String(localized: "Vignette"), \.vignette, 0...1, format: "%.2f")

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
        .onChange(of: params) { _, newValue in
            document.setPreview(adjust: newValue, filter: filter)
        }
        .onChange(of: filter) { _, newValue in
            document.setPreview(adjust: params, filter: newValue)
        }
        .onDisappear {
            document.clearPreview()
        }
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
