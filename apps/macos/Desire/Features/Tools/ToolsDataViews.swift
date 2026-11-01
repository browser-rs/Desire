import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// 开发与数据工具视图（v0.8.33 批次二）：Base32 / TOTP / JSONPath /
// 结构化数据 / chmod / IEEE 754 / ULID。逻辑全部在对应 *Core。

// MARK: - 共用小件

private struct DataToolField: View {
    let title: String
    @Binding var text: String
    var width: CGFloat = 200
    var mono = true

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .frame(width: width)
        }
    }
}

private struct DataToolRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Base32

private enum Base32Mode: String, CaseIterable, Identifiable {
    case encode, decode
    var id: String { rawValue }
}

struct Base32ToolView: View {
    @State private var mode: Base32Mode = .encode
    @State private var input = ""
    @State private var output = ""
    @State private var note: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $mode) {
                Text(String(localized: "Encode")).tag(Base32Mode.encode)
                Text(String(localized: "Decode")).tag(Base32Mode.decode)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            ToolEditor(title: String(localized: "Input"), text: $input, height: 120)
            Button(String(localized: "Convert")) { convert() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(input.isEmpty)
            if let error {
                ToolErrorText(text: error)
            }
            if let note {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            ToolOutput(text: output)
        }
        .onChange(of: mode) { _, _ in
            output = ""
            error = nil
            note = nil
        }
    }

    private func convert() {
        error = nil
        note = nil
        switch mode {
        case .encode:
            output = Base32Core.encode(Data(input.utf8))
        case .decode:
            guard let data = Base32Core.decode(input) else {
                output = ""
                error = String(localized: "Not valid Base32.")
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                output = text
            } else {
                output = data.map { String(format: "%02x", $0) }.joined()
                note = String(localized: "The result is binary and is shown as hex.")
            }
        }
    }
}

// MARK: - TOTP

struct TOTPToolView: View {
    @State private var secret = ""
    @State private var algorithm: TOTPCore.Algorithm = .sha1
    @State private var digits = 6
    @State private var period = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DataToolField(title: String(localized: "Base32 secret"), text: $secret, width: 300)
            HStack(spacing: 16) {
                Picker("", selection: $algorithm) {
                    ForEach(TOTPCore.Algorithm.allCases) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
                Picker("", selection: $digits) {
                    Text(verbatim: "6").tag(6)
                    Text(verbatim: "8").tag(8)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 90)
                Picker("", selection: $period) {
                    Text(verbatim: "30s").tag(30)
                    Text(verbatim: "60s").tag(60)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 100)
            }
            Text(String(localized: "The secret stays in memory only and is never saved."))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let code = TOTPCore.code(secret: secret, date: context.date,
                                         period: period, digits: digits,
                                         algorithm: algorithm)
                let remaining = TOTPCore.secondsRemaining(for: context.date, period: period)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        Text(code.map(formatted) ?? "—")
                            .font(.system(size: 30, weight: .semibold, design: .monospaced))
                            .foregroundStyle(code == nil
                                ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                            .textSelection(.enabled)
                        if let code {
                            Button(String(localized: "Copy")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    if !secret.isEmpty && code == nil {
                        ToolErrorText(text: String(localized: "Not a valid Base32 secret."))
                    }
                    ProgressView(value: Double(remaining), total: Double(period))
                        .frame(maxWidth: 260)
                    Text(verbatim: "\(remaining)s")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func formatted(_ code: String) -> String {
        let middle = code.count / 2
        return String(code.prefix(middle)) + " " + String(code.suffix(from: code.index(code.startIndex, offsetBy: middle)))
    }
}

// MARK: - JSONPath

struct JSONPathToolView: View {
    @State private var jsonText = "{\n  \"items\": [\n    { \"name\": \"alpha\", \"count\": 1 },\n    { \"name\": \"beta\", \"count\": 2 }\n  ]\n}"
    @State private var path = "$.items[0].name"
    @State private var output = ""
    @State private var error: String?
    @State private var matches = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolEditor(title: String(localized: "JSON"), text: $jsonText, height: 170)
            HStack(spacing: 10) {
                DataToolField(title: String(localized: "Path"), text: $path, width: 240)
                Button(String(localized: "Query")) { query() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Text(String(localized: "Examples: $.a.b, $.items[0], $.items[*], $..id, $['key.with.dots']"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            if let error {
                ToolErrorText(text: error)
            }
            if !output.isEmpty {
                Text(verbatim: "\(matches) match(es)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            ToolOutput(text: output, title: String(localized: "Result"))
        }
    }

    private func query() {
        error = nil
        output = ""
        matches = 0
        guard let data = jsonText.data(using: .utf8) else { return }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            self.error = String(localized: "Invalid JSON.")
            return
        }
        guard let values = JSONPathCore.query(root, path: path) else {
            error = String(localized: "Invalid JSONPath expression.")
            return
        }
        matches = values.count
        output = JSONPathCore.display(values) ?? ""
    }
}

// MARK: - 结构化数据

private enum StructuredDataMode: String, CaseIterable, Identifiable {
    case jsonToXML, jsonToBinary, plistToJSON, yamlToJSON
    var id: String { rawValue }

    var title: String {
        switch self {
        case .jsonToXML: return String(localized: "JSON → plist (XML)")
        case .jsonToBinary: return String(localized: "JSON → plist (Binary)")
        case .plistToJSON: return String(localized: "plist → JSON")
        case .yamlToJSON: return String(localized: "YAML → JSON")
        }
    }
}

struct StructuredDataToolView: View {
    @State private var mode: StructuredDataMode = .jsonToXML
    @State private var input = "{\n  \"name\": \"Desire\",\n  \"tags\": [\"tools\", \"pdf\"]\n}"
    @State private var output = ""
    @State private var binaryData: Data?
    @State private var inputFile: URL?
    @State private var inputFileData: Data?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $mode) {
                ForEach(StructuredDataMode.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 260)
            if mode == .plistToJSON {
                HStack(spacing: 8) {
                    Button(String(localized: "Choose plist File…")) { chooseFile() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    if let file = inputFile {
                        Text(file.lastPathComponent)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(String(localized: "Clear")) {
                            inputFile = nil
                            inputFileData = nil
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if inputFileData == nil {
                ToolEditor(title: String(localized: "Input"), text: $input, height: 150)
            }
            HStack(spacing: 8) {
                Button(String(localized: "Convert")) { convert() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                if binaryData != nil {
                    Button(String(localized: "Save Binary plist…")) { saveBinary() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if !output.isEmpty {
                    Button(String(localized: "Save Output…")) { saveText() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if let error {
                ToolErrorText(text: error)
            }
            if !output.isEmpty {
                ToolOutput(text: output, title: String(localized: "Output"))
            }
        }
        .onChange(of: mode) { _, _ in
            output = ""
            binaryData = nil
            error = nil
        }
    }

    private func convert() {
        error = nil
        output = ""
        binaryData = nil
        do {
            switch mode {
            case .jsonToXML:
                let data = try StructuredDataCore.jsonToPlist(input, format: .xml)
                output = String(data: data, encoding: .utf8) ?? ""
            case .jsonToBinary:
                let data = try StructuredDataCore.jsonToPlist(input, format: .binary)
                binaryData = data
                output = String(localized: "Binary plist ready (\(data.count) bytes).")
            case .plistToJSON:
                let data = inputFileData ?? Data(input.utf8)
                output = try StructuredDataCore.plistToJSON(data)
            case .yamlToJSON:
                output = try StructuredDataCore.yamlToJSON(input)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        inputFile = url
        inputFileData = try? Data(contentsOf: url)
        output = ""
        binaryData = nil
        error = nil
    }

    private func saveBinary() {
        guard let binaryData else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.propertyList]
        panel.nameFieldStringValue = "Output.plist"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try binaryData.write(to: url)
            RecentLocalFiles.record(url: url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveText() {
        let panel = NSSavePanel()
        let ext = mode == .jsonToXML ? "plist" : "json"
        panel.allowedContentTypes = [mode == .jsonToXML ? .propertyList : .json]
        panel.nameFieldStringValue = "Output.\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
            RecentLocalFiles.record(url: url)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - chmod

struct ChmodToolView: View {
    @State private var permissions = ChmodCore.Permissions(
        ownerRead: true, ownerWrite: true, ownerExecute: true,
        groupRead: true, groupWrite: false, groupExecute: true,
        otherRead: true, otherWrite: false, otherExecute: true)
    @State private var octalText = "755"
    @State private var symbolicText = "rwxr-xr-x"
    @State private var syncing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                permissionColumn(title: String(localized: "Owner"),
                                 read: $permissions.ownerRead,
                                 write: $permissions.ownerWrite,
                                 execute: $permissions.ownerExecute)
                permissionColumn(title: String(localized: "Group"),
                                 read: $permissions.groupRead,
                                 write: $permissions.groupWrite,
                                 execute: $permissions.groupExecute)
                permissionColumn(title: String(localized: "Other"),
                                 read: $permissions.otherRead,
                                 write: $permissions.otherWrite,
                                 execute: $permissions.otherExecute)
            }
            HStack(spacing: 16) {
                Toggle(String(localized: "Setuid"), isOn: $permissions.setuid)
                    .toggleStyle(.checkbox)
                Toggle(String(localized: "Setgid"), isOn: $permissions.setgid)
                    .toggleStyle(.checkbox)
                Toggle(String(localized: "Sticky"), isOn: $permissions.sticky)
                    .toggleStyle(.checkbox)
            }
            .font(.system(size: 11.5))
            HStack(spacing: 16) {
                DataToolField(title: String(localized: "Octal"), text: $octalText, width: 80)
                DataToolField(title: String(localized: "Symbolic"), text: $symbolicText, width: 120)
            }
            DataToolRow(label: String(localized: "Command"),
                        value: "chmod \(ChmodCore.octalString(permissions)) <file>")
            DataToolRow(label: String(localized: "Absolute"),
                        value: ChmodCore.absoluteSymbolic(permissions))
        }
        .onChange(of: permissions) { _, value in
            guard !syncing else { return }
            syncing = true
            octalText = ChmodCore.octalString(value)
            symbolicText = ChmodCore.symbolicString(value)
            syncing = false
        }
        .onChange(of: octalText) { _, value in
            guard !syncing, let parsed = ChmodCore.parseOctal(value) else { return }
            syncing = true
            permissions = parsed
            symbolicText = ChmodCore.symbolicString(parsed)
            syncing = false
        }
    }

    private func permissionColumn(title: String, read: Binding<Bool>,
                                  write: Binding<Bool>, execute: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Toggle(isOn: read) { Text(verbatim: "Read (r)") }
                .toggleStyle(.checkbox)
            Toggle(isOn: write) { Text(verbatim: "Write (w)") }
                .toggleStyle(.checkbox)
            Toggle(isOn: execute) { Text(verbatim: "Execute (x)") }
                .toggleStyle(.checkbox)
        }
        .font(.system(size: 11.5))
        .frame(width: 120, alignment: .leading)
    }
}

// MARK: - IEEE 754

private enum FloatBitsMode: String, CaseIterable, Identifiable {
    case decimal, hex
    var id: String { rawValue }
}

struct FloatBitsToolView: View {
    @State private var mode: FloatBitsMode = .decimal
    @State private var input = "1.0"
    @State private var width = 32
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Picker("", selection: $mode) {
                    Text(String(localized: "Decimal → bits")).tag(FloatBitsMode.decimal)
                    Text(String(localized: "Bits → decimal")).tag(FloatBitsMode.hex)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
                Picker("", selection: $width) {
                    Text(verbatim: "float32").tag(32)
                    Text(verbatim: "float64").tag(64)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 180)
            }
            DataToolField(title: mode == .decimal
                          ? String(localized: "Value")
                          : String(localized: "Hex bits"),
                          text: $input, width: 260)
            if let error {
                ToolErrorText(text: error)
            }
            if let result = result {
                VStack(alignment: .leading, spacing: 2) {
                    DataToolRow(label: String(localized: "Decimal"), value: result.decimal)
                    DataToolRow(label: String(localized: "Hex"), value: result.hex)
                    DataToolRow(label: String(localized: "Little-endian"), value: result.littleEndian)
                    DataToolRow(label: String(localized: "Sign"), value: result.sign)
                    DataToolRow(label: String(localized: "Exponent"), value: result.exponent)
                    DataToolRow(label: String(localized: "Mantissa"), value: result.mantissa)
                }
            }
        }
        .onChange(of: input) { _, _ in error = nil }
        .onChange(of: width) { _, _ in error = nil }
        .onChange(of: mode) { _, _ in
            error = nil
            input = mode == .decimal ? "1.0" : "0x3f800000"
        }
    }

    private struct Result {
        var decimal: String
        var hex: String
        var littleEndian: String
        var sign: String
        var exponent: String
        var mantissa: String
    }

    private var result: Result? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        switch mode {
        case .decimal:
            guard let value = FloatBitsCore.parseDecimal(trimmed) else { return nil }
            let bits = width == 32
                ? UInt64(FloatBitsCore.float32Bits(value))
                : FloatBitsCore.float64Bits(value)
            return makeResult(bits: bits)
        case .hex:
            guard let bits = FloatBitsCore.parseHex(trimmed, width: width) else {
                return nil
            }
            return makeResult(bits: bits)
        }
    }

    private func makeResult(bits: UInt64) -> Result {
        let fields = width == 32
            ? FloatBitsCore.decompose32(UInt32(truncatingIfNeeded: bits))
            : FloatBitsCore.decompose64(bits)
        let value: Double = width == 32
            ? FloatBitsCore.float32(fromBits: UInt32(truncatingIfNeeded: bits))
            : FloatBitsCore.float64(fromBits: bits)
        let special = fields.isNaN ? "NaN" : (fields.isInfinite ? "Infinity" : "—")
        return Result(
            decimal: value.isNaN ? "NaN" : String(format: "%.17g", value),
            hex: FloatBitsCore.hex(bits, width: width),
            littleEndian: FloatBitsCore.hex(
                FloatBitsCore.littleEndianBits(bits, width: width), width: width),
            sign: fields.negative ? "1 (−)" : "0 (+)",
            exponent: "\(fields.exponent) (bias \(fields.bias), unbiased "
                + "\(FloatBitsCore.unbiasedExponent(fields).map(String.init) ?? "—"))"
                + (special == "—" ? "" : " · \(special)"),
            mantissa: String(format: width == 32 ? "0x%06llx" : "0x%013llx",
                             fields.mantissa))
    }
}

// MARK: - ULID

@MainActor
private final class ULIDMinter: ObservableObject {
    private var lastMilliseconds: UInt64 = 0
    private var randomness = [UInt8](repeating: 0, count: 10)
    private var initialized = false

    func next(at date: Date = Date()) -> String? {
        let milliseconds = UInt64(max(0, date.timeIntervalSince1970) * 1000)
        if initialized, milliseconds == lastMilliseconds {
            randomness = ULIDCore.increment(randomness: randomness)
        } else {
            var generator = SystemRandomNumberGenerator()
            randomness = (0..<10).map { _ in UInt8.random(in: 0...255, using: &generator) }
            lastMilliseconds = milliseconds
            initialized = true
        }
        return ULIDCore.encode(milliseconds: milliseconds, randomness: randomness)
    }
}

struct ULIDToolView: View {
    @State private var count = 5
    @State private var values: [String] = []
    @StateObject private var minter = ULIDMinter()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Stepper(String(localized: "Count: \(count)"), value: $count, in: 1...50)
                    .font(.system(size: 11.5))
                Button(String(localized: "Generate")) {
                    values = (0..<count).compactMap { _ in minter.next() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(String(localized: "Copy All")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(values.joined(separator: "\n"),
                                                   forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(values.isEmpty)
            }
            if values.isEmpty {
                Text(String(localized: "Press Generate to create ULIDs"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ToolOutput(text: values.joined(separator: "\n"),
                           title: String(localized: "ULIDs"))
            }
        }
        .onAppear {
            if values.isEmpty { values = (0..<count).compactMap { _ in minter.next() } }
        }
    }
}
