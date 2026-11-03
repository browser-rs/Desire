import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 导出面板（v0.8.41）：格式/质量/长边 + 复制到剪贴板 / 另存为。
/// 渲染 = 基础位图 + 非破坏管线（与 ⌘S 同一语义）。
struct ImageExportPanel: View {
    let base: CGImage?
    let pipeline: ImageEditPipeline
    let fileName: String

    enum Format: String, CaseIterable, Identifiable {
        case jpeg, png, heic
        var id: String { rawValue }
        var title: String { rawValue.uppercased() }
        var utType: UTType {
            switch self {
            case .jpeg: .jpeg
            case .png: .png
            case .heic: UTType(filenameExtension: "heic") ?? .data
            }
        }
    }

    @State private var format: Format = .jpeg
    @State private var quality: Double = 0.9
    @State private var longEdgeText = ""
    @State private var isWorking = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Export Image"))
                .font(.system(size: 14, weight: .semibold))
            Picker("", selection: $format) {
                ForEach(Format.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if format != .png {
                sliderRow(String(localized: "Quality"), value: $quality, range: 0.3...1)
            }
            TextField(String(localized: "Long edge px (empty = original)"),
                      text: $longEdgeText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            HStack {
                Button(String(localized: "Copy to Clipboard")) { export(toClipboard: true) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(base == nil || isWorking)
                Button(String(localized: "Save As…")) { export(toClipboard: false) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(base == nil || isWorking)
                if isWorking { ProgressView().controlSize(.small) }
                if let message {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(16)
        .frame(width: 320)
    }

    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10.5))
                .frame(width: 70, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    private func renderedOutput() async -> CGImage? {
        let source = base ?? placeholder()
        let rendered = await Task.detached(priority: .userInitiated) {
            ImageEditorDocument.renderFinal(base: source, pipeline: pipeline)
        }.value
        guard var output = rendered else { return nil }
        if let edge = Int(longEdgeText.trimmingCharacters(in: .whitespaces)),
           edge >= 16 {
            let long = max(output.width, output.height)
            if long > edge {
                let scale = Double(edge) / Double(long)
                let width = max(1, Int((Double(output.width) * scale).rounded()))
                let height = max(1, Int((Double(output.height) * scale).rounded()))
                output = ImageTransforms.resized(output, width: width,
                                                 height: height) ?? output
            }
        }
        return output
    }

    private func placeholder() -> CGImage {
        let context = CGContext(data: nil, width: 1, height: 1,
                                bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context?.makeImage() ?? CGImage.createEmpty()
    }

    private func export(toClipboard: Bool) {
        guard base != nil else { return }
        isWorking = true
        message = nil
        Task { @MainActor in
            defer { isWorking = false }
            guard let output = await renderedOutput() else {
                message = String(localized: "Render failed")
                return
            }
            if toClipboard {
                let nsImage = NSImage(cgImage: output,
                                      size: NSSize(width: output.width,
                                                   height: output.height))
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([nsImage])
                message = String(localized: "Copied")
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format.utType]
            let stem = (fileName as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(stem).\(format.rawValue)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try ImageTransforms.save(output, to: url, quality: quality)
                message = String(localized: "Saved")
                dismiss()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

nonisolated extension CGImage {
    static func createEmpty() -> CGImage {
        let context = CGContext(data: nil, width: 1, height: 1,
                                bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context!.makeImage()!
    }
}
