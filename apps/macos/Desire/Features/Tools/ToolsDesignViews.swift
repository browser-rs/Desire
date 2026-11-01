import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 设计与识别工具视图（v0.8.33 批次三）：颜色对比度、二维码/条码识别。
// 逻辑在 ContrastCore / BarcodeCore / BarcodeScanEngine。

private struct DesignField: View {
    let title: String
    @Binding var text: String
    var width: CGFloat = 120

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: width)
        }
    }
}

// MARK: - 对比度

struct ContrastToolView: View {
    @State private var foregroundHex = "#1A1A1A"
    @State private var backgroundHex = "#FFFFFF"

    private var foreground: ContrastCore.RGB? { ContrastCore.parseHex(foregroundHex) }
    private var background: ContrastCore.RGB? { ContrastCore.parseHex(backgroundHex) }

    private var ratio: Double? {
        guard let foreground, let background else { return nil }
        return ContrastCore.ratio(foreground, background)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                DesignField(title: String(localized: "Text color"), text: $foregroundHex)
                DesignField(title: String(localized: "Background"), text: $backgroundHex)
                Button(String(localized: "Swap")) {
                    let old = foregroundHex
                    foregroundHex = backgroundHex
                    backgroundHex = old
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if let ratio, let foreground, let background {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(red: background.red, green: background.green,
                                        blue: background.blue))
                        Text("Aa 你好")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Color(red: foreground.red,
                                                   green: foreground.green,
                                                   blue: foreground.blue))
                    }
                    .frame(width: 220, height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.2f : 1", ratio))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                        let rating = ContrastCore.rating(ratio)
                        labelRow("AA", large: false, passes: rating.aaNormal)
                        labelRow("AA Large", large: true, passes: rating.aaLarge)
                        labelRow("AAA", large: false, passes: rating.aaaNormal)
                        labelRow("AAA Large", large: true, passes: rating.aaaLarge)
                    }
                }
                HStack(spacing: 8) {
                    Text(String(localized: "Suggested text"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(ContrastCore.bestTextColor(on: background))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                    Button(String(localized: "Use")) {
                        foregroundHex = ContrastCore.bestTextColor(on: background)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                paletteView(base: foreground)
            } else {
                ToolErrorText(text: String(localized: "Enter colors as #RRGGBB."))
            }
        }
    }

    private func labelRow(_ name: String, large: Bool, passes: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: passes ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(passes ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            Text(name)
                .font(.system(size: 11))
            if large {
                Text(String(localized: "large text"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private func paletteView(base: ContrastCore.RGB) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Palette"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(Array(ContrastCore.palette(base: base).enumerated()), id: \.offset) { _, hex in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(color(hex))
                            .frame(width: 44, height: 30)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                        Text(hex)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func color(_ hex: String) -> Color {
        guard let rgb = ContrastCore.parseHex(hex) else { return .gray }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

// MARK: - 二维码识别

struct QRDecodeToolView: View {
    @State private var source: URL?
    @State private var preview: NSImage?
    @State private var items: [BarcodeScanEngine.Item] = []
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(String(localized: "Choose Image…")) { chooseImage() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(String(localized: "From Clipboard")) { scanClipboard() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if let source {
                    Text(source.lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if working {
                    ProgressView().controlSize(.small)
                }
            }
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor)))
            }
            if let error {
                ToolErrorText(text: error)
            }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Decoded"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(items) { item in
                        itemRow(item)
                    }
                }
            }
            Text(String(localized: "Decoding happens on this Mac."))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func itemRow(_ item: BarcodeScanEngine.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(kindName(BarcodeCore.kind(of: item.payload)))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                Text(item.symbology)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button(String(localized: "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.payload, forType: .string)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                if let url = BarcodeCore.link(from: item.payload) {
                    Button(String(localized: "Open")) {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }
            Text(item.payload)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(4)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    private func kindName(_ kind: BarcodeCore.Kind) -> String {
        switch kind {
        case .link: return String(localized: "Link")
        case .email: return String(localized: "Email")
        case .phone: return String(localized: "Phone")
        case .wifi: return String(localized: "Wi-Fi")
        case .contact: return String(localized: "Contact card")
        case .text: return String(localized: "Text")
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url
        preview = NSImage(contentsOf: url)
        error = nil
        items = []
        working = true
        Task {
            do {
                items = try await BarcodeScanEngine.scan(url: url)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }

    private func scanClipboard() {
        guard let data = NSPasteboard.general.data(forType: .tiff),
              let image = NSImage(data: data) else {
            error = String(localized: "No image in the clipboard.")
            return
        }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            error = String(localized: "No image in the clipboard.")
            return
        }
        source = nil
        preview = image
        error = nil
        items = []
        working = true
        Task {
            do {
                items = try await BarcodeScanEngine.scan(cgImage: cgImage)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
