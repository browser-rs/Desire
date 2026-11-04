import SwiftUI
import UniformTypeIdentifiers

/// 水印面板（v0.8.42 批 2）：文字/图片水印的参数编辑 + 应用/保存预设。
struct ImageWatermarkPanel: View {
    let image: CGImage?
    var onApply: ((CGImage) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent: Color

    @State private var kind: Kind = .text
    @State private var text = ""
    @State private var imagePath = ""
    @State private var position = 8
    @State private var opacity: Double = 0.6
    @State private var scale: Double = 0.04
    @State private var rotation: Double = 0
    @State private var tile = false
    @State private var tileSpacing: Double = 0.25
    @State private var colorHex = "#FFFFFF"
    @State private var message: String?
    @State private var showImagePicker = false
    @State private var previewImage: CGImage?

    enum Kind: String, CaseIterable, Identifiable {
        case text, image
        var id: String { rawValue }
        var title: String {
            switch self {
            case .text: return String(localized: "Text Watermark")
            case .image: return String(localized: "Image Watermark")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "Watermark"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(String(localized: "Close")) { dismiss() }
                    .buttonStyle(.borderless)
            }
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: kind) { _, _ in
                updatePreview()
            }

            if kind == .text {
                TextField(String(localized: "Watermark text"), text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
                    .onChange(of: text) { _, _ in updatePreview() }
                HStack(spacing: 6) {
                    Text(String(localized: "Color"))
                        .font(.system(size: 10))
                    ColorPicker("", selection: Binding(
                        get: {
                            Color(hexToNSColor(hex: colorHex))
                        },
                        set: { color in
                            if let cg = NSColor(color).usingColorSpace(.deviceRGB) {
                                colorHex = String(format: "#%02X%02X%02X",
                                                  Int(cg.redComponent * 255),
                                                  Int(cg.greenComponent * 255),
                                                  Int(cg.blueComponent * 255))
                            }
                        }), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 26)
                }
            } else {
                HStack(spacing: 6) {
                    Button(String(localized: "Choose Image…")) { showImagePicker = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    if !imagePath.isEmpty {
                        Text((imagePath as NSString).lastPathComponent)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            slider("Opacity", $opacity, 0.05...1) { updatePreview() }
            slider("Scale", $scale, 0.02...0.15) { updatePreview() }
            slider("Rotation", $rotation, -180...180) { updatePreview() }

            Toggle(String(localized: "Tile (repeat)"), isOn: $tile)
                .font(.system(size: 11))
                .onChange(of: tile) { _, _ in updatePreview() }
            if tile {
                slider("Tile spacing", $tileSpacing, 0.1...0.5) { updatePreview() }
            }

            // 九宫格位置选择
            if !tile {
                Text(String(localized: "Position"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 3),
                          spacing: 4) {
                    ForEach(0..<9, id: \.self) { index in
                        Button {
                            position = index
                            updatePreview()
                        } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(position == index ? appAccent.opacity(0.35)
                                                        : Color.secondary.opacity(0.08))
                                .frame(width: 28, height: 22)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // 预览
            if let previewImage, let nsImage = makeNSImage(previewImage) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button(String(localized: "Apply")) { apply() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isNeutral)
                if let message {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 320, height: 560)
        .fileImporter(isPresented: $showImagePicker,
                      allowedContentTypes: [.image]) { result in
            if case .success(let url) = result,
               url.startAccessingSecurityScopedResource() {
                imagePath = url.path
                url.stopAccessingSecurityScopedResource()
                updatePreview()
            }
        }
        .onAppear(perform: updatePreview)
    }

    private var isNeutral: Bool {
        kind == .text && text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var params: ImageWatermarkParams {
        ImageWatermarkParams(
            kind: kind == .text ? .text : .image,
            text: text,
            imagePath: imagePath,
            position: position,
            opacity: opacity,
            scale: scale,
            rotation: rotation,
            tile: tile,
            tileSpacing: tileSpacing,
            colorHex: colorHex)
    }

    private func slider(_ title: String, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, onChange: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10))
                .frame(width: 70, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
                .onChange(of: value.wrappedValue) { _, _ in onChange() }
        }
    }

    private func updatePreview() {
        guard let image else { return }
        previewImage = ImageWatermarkRenderer.render(image, params: params)
    }

    private func apply() {
        guard let image else { return }
        if let error = ImageWatermarkValidation.error(params) {
            message = error
            return
        }
        guard let output = ImageWatermarkRenderer.render(image, params: params) else {
            message = String(localized: "Render failed")
            return
        }
        onApply?(output)
        dismiss()
    }

    private func makeNSImage(_ cg: CGImage) -> NSImage? {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

nonisolated private func hexToNSColor(hex: String) -> CGColor {
    var clean = hex.trimmingCharacters(in: .whitespaces)
    if clean.hasPrefix("#") { clean.removeFirst() }
    guard clean.count == 6, let value = UInt64(clean, radix: 16) else {
        return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    }
    return CGColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                   green: CGFloat((value >> 8) & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}
