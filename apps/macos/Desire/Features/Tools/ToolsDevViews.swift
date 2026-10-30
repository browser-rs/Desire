import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

// 现有工具视图（v0.8.27 从 ToolsPageView 拆出）：摘要/时间戳/Base64/URL/JSON/
// 文本/进制/UUID/颜色/二维码/密码/JWT。

// MARK: - Hash

struct HashToolView: View {
    @State private var text = ""
    @State private var algorithm: ToolsCrypto.Algorithm = .sha256

    private var digest: String {
        text.isEmpty ? "" : ToolsCrypto.hash(text, algorithm: algorithm)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolEditor(title: String(localized: "Text"), text: $text,
                       height: 120, placeholder: String(localized: "Type or paste text…"))
            Picker("", selection: $algorithm) {
                ForEach(ToolsCrypto.Algorithm.allCases, id: \.self) { algorithm in
                    Text(algorithm.title).tag(algorithm)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            ToolOutput(text: digest, title: algorithm.title)
            Text(String(localized: "\(text.utf8.count) bytes"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Timestamp

struct TimestampToolView: View {
    @State private var input = String(ToolboxCore.unixSeconds(Date()))
    @State private var date = Date()

    private var parsed: (date: Date, unit: ToolboxCore.UnixUnit)? {
        ToolboxCore.parseUnix(input)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                TextField(String(localized: "Unix timestamp"), text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: 260)
                Button(String(localized: "Now")) {
                    input = String(ToolboxCore.unixSeconds(Date()))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text(String(localized: "Seconds or milliseconds — detected automatically"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if let parsed {
                VStack(alignment: .leading, spacing: 2) {
                    ToolValueRow(label: String(localized: "Local time"),
                                 value: ToolboxCore.formatted(parsed.date))
                    ToolValueRow(label: String(localized: "UTC"),
                                 value: ToolboxCore.formatted(parsed.date, timeZone: TimeZone(identifier: "UTC") ?? .current))
                    ToolValueRow(label: "ISO 8601", value: ToolboxCore.iso8601(parsed.date))
                    ToolValueRow(label: String(localized: "Relative"), value: ToolboxCore.relative(parsed.date))
                    ToolValueRow(label: String(localized: "Detected"), value: parsed.unit == .milliseconds ? "ms" : "s", mono: false)
                }
            } else {
                ToolErrorText(text: String(localized: "Not a valid Unix timestamp"))
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Date → timestamp"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                ToolValueRow(label: String(localized: "Seconds"),
                             value: String(ToolboxCore.unixSeconds(date)))
                ToolValueRow(label: String(localized: "Milliseconds"),
                             value: String(ToolboxCore.unixMilliseconds(date)))
            }
        }
    }
}

// MARK: - Base64

struct Base64ToolView: View {
    private enum Mode: String, CaseIterable { case encode, decode }

    @State private var text = ""
    @State private var mode: Mode = .encode
    @State private var urlSafe = false

    private var result: Result<String, ToolboxError> {
        switch mode {
        case .encode:
            return .success(text.isEmpty ? "" : ToolboxCore.base64Encode(text, urlSafe: urlSafe))
        case .decode:
            guard !text.isEmpty else { return .success("") }
            return ToolboxCore.base64Decode(text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("", selection: $mode) {
                    Text(String(localized: "Encode")).tag(Mode.encode)
                    Text(String(localized: "Decode")).tag(Mode.decode)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                if mode == .encode {
                    ToolToggle(title: String(localized: "URL-safe"), isOn: $urlSafe)
                }
            }
            ToolEditor(title: String(localized: "Input"), text: $text,
                       height: 120, placeholder: String(localized: "Text or Base64…"))
            switch result {
            case .success(let output):
                ToolOutput(text: output)
            case .failure(let error):
                ToolErrorText(text: error.message)
            }
        }
    }
}

// MARK: - URL

struct URLCodecToolView: View {
    private enum Mode: String, CaseIterable { case encode, decode }

    @State private var text = ""
    @State private var mode: Mode = .encode

    private var result: Result<String, ToolboxError> {
        switch mode {
        case .encode: return .success(text.isEmpty ? "" : ToolboxCore.urlEncode(text))
        case .decode:
            guard !text.isEmpty else { return .success("") }
            return ToolboxCore.urlDecode(text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $mode) {
                Text(String(localized: "Encode")).tag(Mode.encode)
                Text(String(localized: "Decode")).tag(Mode.decode)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            ToolEditor(title: String(localized: "Input"), text: $text,
                       height: 110, placeholder: String(localized: "URL or text…"))
            switch result {
            case .success(let output):
                ToolOutput(text: output)
            case .failure(let error):
                ToolErrorText(text: error.message)
            }
        }
    }
}

// MARK: - JSON

struct JSONToolView: View {
    @State private var text = ""
    @State private var output = ""
    @State private var error: String?
    @State private var indent = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolEditor(title: String(localized: "JSON"), text: $text, height: 150,
                       placeholder: "{\"hello\": \"world\"}")
            HStack(spacing: 8) {
                Button(String(localized: "Format")) { run { JSONFormatterCore.format($0, indent: indent) } }
                    .buttonStyle(.bordered)
                Button(String(localized: "Minify")) { run { JSONFormatterCore.format($0, minify: true) } }
                    .buttonStyle(.bordered)
                Button(String(localized: "Sort Keys")) { run { JSONFormatterCore.format($0, indent: indent, sortKeys: true) } }
                    .buttonStyle(.bordered)
                Button(String(localized: "To CSV")) {
                    switch JSONFormatterCore.parse(text) {
                    case .failure(let failure):
                        error = "\(failure.message) (line \(failure.line), column \(failure.column))"
                        output = ""
                    case .success(let object):
                        if let csv = JSONFormatterCore.csv(from: object) {
                            output = csv
                            error = nil
                        } else {
                            error = String(localized: "This JSON has no tabular shape (array of objects/arrays).")
                            output = ""
                        }
                    }
                }
                .buttonStyle(.bordered)
                Button(String(localized: "Validate")) {
                    if let failure = JSONFormatterCore.validate(text) {
                        error = "\(failure.message) (line \(failure.line), column \(failure.column))"
                        output = ""
                    } else {
                        error = nil
                        output = String(localized: "Valid JSON")
                    }
                }
                .buttonStyle(.bordered)
                Picker("", selection: $indent) {
                    Text("2").tag(2)
                    Text("4").tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 64)
            }
            if let error {
                ToolErrorText(text: error)
            }
            ToolOutput(text: output)
        }
    }

    private func run(_ transform: (String) -> Result<String, JSONFormatterCore.Failure>) {
        switch transform(text) {
        case .success(let formatted):
            output = formatted
            error = nil
        case .failure(let failure):
            output = ""
            error = "\(failure.message) (line \(failure.line), column \(failure.column))"
        }
    }
}

// MARK: - Text

struct TextToolView: View {
    @State private var text = ""
    @State private var output = ""

    private var stats: (characters: Int, words: Int, lines: Int) {
        ToolboxCore.stats(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolEditor(title: String(localized: "Text"), text: $text, height: 130,
                       placeholder: String(localized: "Type or paste text…"))
            let grid = [
                GridItem(.adaptive(minimum: 96), spacing: 6),
            ]
            LazyVGrid(columns: grid, alignment: .leading, spacing: 6) {
                transformButton(String(localized: "UPPER")) { ToolboxCore.upper($0) }
                transformButton(String(localized: "lower")) { ToolboxCore.lower($0) }
                transformButton(String(localized: "Title Case")) { ToolboxCore.titleCase($0) }
                transformButton(String(localized: "snake_case")) { ToolboxCore.snakeCase($0) }
                transformButton(String(localized: "kebab-case")) { ToolboxCore.kebabCase($0) }
                transformButton(String(localized: "Sort Lines")) { ToolboxCore.processLines($0, mode: .sort) }
                transformButton(String(localized: "Sort Desc.")) { ToolboxCore.processLines($0, mode: .sortDescending) }
                transformButton(String(localized: "Dedupe Lines")) { ToolboxCore.processLines($0, mode: .dedupe) }
                transformButton(String(localized: "Reverse Lines")) { ToolboxCore.processLines($0, mode: .reverse) }
                transformButton(String(localized: "Number Lines")) { ToolboxCore.processLines($0, mode: .numbered) }
            }
            HStack(spacing: 14) {
                statChip(String(localized: "\(stats.characters) chars"))
                statChip(String(localized: "\(stats.words) words"))
                statChip(String(localized: "\(stats.lines) lines"))
            }
            if !output.isEmpty {
                ToolOutput(text: output)
            }
        }
    }

    private func transformButton(_ title: String,
                                 _ transform: @escaping (String) -> String) -> some View {
        Button(title) { output = transform(text) }
            .font(.system(size: 11))
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func statChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Numbers

struct NumberToolView: View {
    @State private var input = ""
    @State private var base: Int = 0   // 0 = auto

    private var value: Int64? {
        ToolboxCore.parseInteger(input, base: base == 0 ? nil : base)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField(String(localized: "Number (e.g. 255, 0xFF, 0b1010)"), text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: 300)
                Picker("", selection: $base) {
                    Text(String(localized: "Auto")).tag(0)
                    Text("10").tag(10)
                    Text("16").tag(16)
                    Text("2").tag(2)
                    Text("8").tag(8)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            if let value {
                let bases = ToolboxCore.bases(for: value)
                VStack(alignment: .leading, spacing: 2) {
                    ToolValueRow(label: String(localized: "Decimal"), value: bases.decimal)
                    ToolValueRow(label: String(localized: "Hexadecimal"), value: bases.hexadecimal)
                    ToolValueRow(label: String(localized: "Binary"), value: bases.binary)
                    ToolValueRow(label: String(localized: "Octal"), value: bases.octal)
                }
            } else if !input.isEmpty {
                ToolErrorText(text: String(localized: "Not a valid integer for that base"))
            }
        }
    }
}

// MARK: - UUID

struct UUIDToolView: View {
    @State private var count = 5
    @State private var values: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Stepper(String(localized: "Count: \(count)"), value: $count, in: 1...50)
                    .font(.system(size: 11.5))
                Button(String(localized: "Generate")) {
                    values = (0..<count).map { _ in UUID().uuidString }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(String(localized: "Copy All")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(values.joined(separator: "\n"), forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(values.isEmpty)
            }
            if values.isEmpty {
                Text(String(localized: "Press Generate to create UUIDs"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ToolOutput(text: values.joined(separator: "\n"), title: String(localized: "UUIDs"))
            }
        }
        .onAppear {
            if values.isEmpty { values = (0..<count).map { _ in UUID().uuidString } }
        }
    }
}

// MARK: - Color

struct ColorToolView: View {
    @State private var hex = "#6699FF"

    private var parsed: (red: Int, green: Int, blue: Int, alpha: Double)? {
        ToolboxCore.parseHexColor(hex)
    }

    private var color: Color {
        guard let parsed else { return .gray }
        return Color(red: Double(parsed.red) / 255,
                     green: Double(parsed.green) / 255,
                     blue: Double(parsed.blue) / 255,
                     opacity: parsed.alpha)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("#RRGGBB", text: $hex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 140)
                    .onSubmit { normalize() }
                ColorPicker("", selection: Binding(
                    get: { color },
                    set: { newValue in
                        let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? .gray
                        hex = ToolboxCore.hexColor(red: Int(ns.redComponent * 255),
                                                   green: Int(ns.greenComponent * 255),
                                                   blue: Int(ns.blueComponent * 255),
                                                   alpha: ns.alphaComponent)
                    }))
                    .labelsHidden()
                RoundedRectangle(cornerRadius: 6)
                    .fill(color)
                    .frame(width: 48, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            }
            if let parsed {
                VStack(alignment: .leading, spacing: 2) {
                    ToolValueRow(label: "HEX", value: ToolboxCore.hexColor(
                        red: parsed.red, green: parsed.green, blue: parsed.blue, alpha: parsed.alpha))
                    ToolValueRow(label: "RGB", value: "\(parsed.red), \(parsed.green), \(parsed.blue)")
                    ToolValueRow(label: "RGBA", value: "\(parsed.red), \(parsed.green), \(parsed.blue), \(String(format: "%.2f", parsed.alpha))")
                }
            } else {
                ToolErrorText(text: String(localized: "Use #RRGGBB or #RRGGBBAA"))
            }
        }
    }

    private func normalize() {
        guard let parsed else { return }
        hex = ToolboxCore.hexColor(red: parsed.red, green: parsed.green,
                                   blue: parsed.blue, alpha: parsed.alpha)
    }
}

// MARK: - QR Code

struct QRCodeToolView: View {
    @State private var text = ""
    @State private var image: NSImage?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolEditor(title: String(localized: "Text or URL"), text: $text, height: 90,
                       placeholder: "https://example.com")
            HStack(spacing: 8) {
                Button(String(localized: "Generate")) { generate() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(String(localized: "Copy Image")) {
                    if let image {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(image == nil)
                Button(String(localized: "Save PNG…")) { savePNG() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(image == nil)
            }
            if let error {
                ToolErrorText(text: error)
            } else if let image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white))
                    .padding(4)
            }
        }
        .onChange(of: text) { _, _ in generate() }
        .onAppear { generate() }
    }

    private func generate() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            image = nil
            error = nil
            return
        }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            error = String(localized: "QR generator unavailable")
            return
        }
        filter.setValue(Data(trimmed.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else {
            error = String(localized: "Could not generate a QR code")
            return
        }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
            error = String(localized: "Could not render the QR code")
            return
        }
        error = nil
        image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func savePNG() {
        guard let image, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "qr-code.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? png.write(to: dest)
    }
}

// MARK: - Password

struct PasswordToolView: View {
    @State private var length = 20
    @State private var useDigits = true
    @State private var useSymbols = true
    @State private var useUppercase = true
    @State private var avoidAmbiguous = false
    @State private var password = ToolboxCore.generatePassword()

    private var strength: Int { ToolboxCore.passwordStrength(password) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Stepper(String(localized: "Length: \(length)"), value: $length, in: 6...128)
                    .font(.system(size: 11.5))
                ToolToggle(title: String(localized: "Uppercase"), isOn: $useUppercase)
                ToolToggle(title: String(localized: "Digits"), isOn: $useDigits)
                ToolToggle(title: String(localized: "Symbols"), isOn: $useSymbols)
                ToolToggle(title: String(localized: "Avoid look-alikes"), isOn: $avoidAmbiguous)
            }
            HStack(spacing: 8) {
                Button(String(localized: "Generate")) {
                    password = ToolboxCore.generatePassword(length: length,
                                                            useDigits: useDigits,
                                                            useSymbols: useSymbols,
                                                            useUppercase: useUppercase,
                                                            useAvoidAmbiguous: avoidAmbiguous)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(String(localized: "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(password, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule()
                            .fill(index < strength ? strengthColor : Color.secondary.opacity(0.18))
                            .frame(width: 26, height: 4)
                    }
                }
            }
            ToolOutput(text: password, title: String(localized: "Password"))
        }
        .onChange(of: length) { _, _ in regenerate() }
        .onChange(of: useDigits) { _, _ in regenerate() }
        .onChange(of: useSymbols) { _, _ in regenerate() }
        .onChange(of: useUppercase) { _, _ in regenerate() }
        .onChange(of: avoidAmbiguous) { _, _ in regenerate() }
    }

    private var strengthColor: Color {
        switch strength {
        case 0, 1: return .red
        case 2: return .orange
        case 3: return .yellow
        default: return .green
        }
    }

    private func regenerate() {
        password = ToolboxCore.generatePassword(length: length, useDigits: useDigits,
                                                useSymbols: useSymbols,
                                                useUppercase: useUppercase,
                                                useAvoidAmbiguous: avoidAmbiguous)
    }
}

// MARK: - JWT

struct JWTToolView: View {
    @State private var token = ""
    @State private var header = ""
    @State private var payload = ""
    @State private var error: String?
    @State private var expiry: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolEditor(title: String(localized: "JWT"), text: $token, height: 100,
                       placeholder: "eyJhbGciOi…")
            Button(String(localized: "Decode")) { decode() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            if let error {
                ToolErrorText(text: error)
            } else {
                if !header.isEmpty {
                    ToolOutput(text: header, title: String(localized: "Header"))
                    ToolOutput(text: payload, title: String(localized: "Payload"))
                }
                if let expiry {
                    ToolValueRow(label: String(localized: "Expires"),
                                 value: "\(ToolboxCore.formatted(expiry)) · \(ToolboxCore.relative(expiry))",
                                 mono: false)
                }
            }
            Text(String(localized: "Decoding only — the signature is not verified."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .onChange(of: token) { _, _ in decode() }
    }

    private func decode() {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            header = ""; payload = ""; error = nil; expiry = nil
            return
        }
        guard let parts = ToolboxCore.jwtParts(token) else {
            header = ""; payload = ""; expiry = nil
            error = String(localized: "Not a valid JWT (expected header.payload.signature)")
            return
        }
        error = nil
        header = parts.header
        payload = parts.payload
        expiry = parts.expiry
    }
}
