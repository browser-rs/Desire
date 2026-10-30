import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 扩展工具视图（2026-10-30）：对比/格式化/网络/安全/随机/图片转换等。
// 逻辑全部在 *Core 文件（harness 覆盖），这里只做界面。

// MARK: - 通用小件

private struct ExtraField: View {
    let title: String
    @Binding var text: String
    var width: CGFloat = 220
    var mono = true
    var placeholder: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .frame(width: width)
        }
    }
}

private struct ExtraModePicker<Mode: Hashable & CaseIterable & RawRepresentable>: View
where Mode.RawValue == String, Mode.AllCases: RandomAccessCollection {
    @Binding var mode: Mode
    var title: (Mode) -> String

    var body: some View {
        Picker("", selection: $mode) {
            ForEach(Array(Mode.allCases), id: \.self) { value in
                Text(title(value)).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 360)
    }
}

// MARK: - 文本对比

struct DiffToolView: View {
    @State private var oldText = ""
    @State private var newText = ""
    @State private var rows: [DiffCore.Row] = []
    @State private var compared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ToolEditor(title: String(localized: "Original"), text: $oldText, height: 120)
                ToolEditor(title: String(localized: "Changed"), text: $newText, height: 120)
            }
            HStack(spacing: 10) {
                Button(String(localized: "Compare")) {
                    rows = DiffCore.diff(old: oldText, new: newText)
                    compared = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                if compared {
                    let stats = DiffCore.stats(rows)
                    Text(String(localized: "+\(stats.inserted) · -\(stats.deleted) · =\(stats.equal)"))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if compared {
                if rows.isEmpty {
                    Text(String(localized: "Both texts are empty"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top, spacing: 6) {
                                Text(row.oldLine.map(String.init) ?? "")
                                    .frame(width: 30, alignment: .trailing)
                                Text(row.newLine.map(String.init) ?? "")
                                    .frame(width: 30, alignment: .trailing)
                                Text(prefix(for: row.kind) + row.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(color(for: row.kind))
                            .padding(.vertical, 1)
                            .background(background(for: row.kind))
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                }
            }
        }
    }

    private func prefix(for kind: DiffCore.Kind) -> String {
        switch kind {
        case .equal: return "  "
        case .delete: return "- "
        case .insert: return "+ "
        }
    }

    private func color(for kind: DiffCore.Kind) -> Color {
        switch kind {
        case .equal: return .secondary
        case .delete: return .red
        case .insert: return .green
        }
    }

    private func background(for kind: DiffCore.Kind) -> Color {
        switch kind {
        case .equal: return .clear
        case .delete: return .red.opacity(0.08)
        case .insert: return .green.opacity(0.08)
        }
    }
}

// MARK: - XML / SQL

struct XMLToolView: View {
    @State private var text = ""
    @State private var output = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolEditor(title: "XML", text: $text, height: 160, placeholder: "<root>…</root>")
            HStack(spacing: 8) {
                Button(String(localized: "Format")) { run(XMLCore.format(text)) }
                    .buttonStyle(.bordered)
                Button(String(localized: "Minify")) { run(XMLCore.minify(text)) }
                    .buttonStyle(.bordered)
                Button(String(localized: "Validate")) {
                    if let message = XMLCore.validate(text) {
                        error = message
                        output = ""
                    } else {
                        error = nil
                        output = String(localized: "Valid XML")
                    }
                }
                .buttonStyle(.bordered)
            }
            if let error { ToolErrorText(text: error) }
            ToolOutput(text: output)
        }
    }

    private func run(_ result: Result<String, ToolboxError>) {
        switch result {
        case .success(let value):
            output = value
            error = nil
        case .failure(let failure):
            output = ""
            error = failure.message
        }
    }
}

struct SQLToolView: View {
    @State private var text = ""
    @State private var output = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolEditor(title: "SQL", text: $text, height: 150, placeholder: "select * from users where id = 1")
            HStack(spacing: 8) {
                Button(String(localized: "Format")) {
                    output = SQLToolCore.format(text)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            ToolOutput(text: output)
        }
    }
}

// MARK: - 编码

struct MorseToolView: View {
    var body: some View {
        CodecToolView(
            inputTitle: String(localized: "Text or Morse"),
            placeholder: "... --- ...",
            encode: { MorseCore.encode($0) },
            decode: { MorseCore.decode($0) })
    }
}

struct WidthToolView: View {
    var body: some View {
        CodecToolView(
            inputTitle: String(localized: "Text"),
            placeholder: "ABC 123",
            encode: { WidthCore.toFullWidth($0) },
            decode: { .success(WidthCore.toHalfWidth($0)) })
    }
}

struct DataURIToolView: View {
    private enum Mode: String, CaseIterable { case toURI, fromURI }

    @State private var mode: Mode = .toURI
    @State private var mime = "text/plain"
    @State private var text = ""
    @State private var error: String?
    @State private var output = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExtraModePicker(mode: $mode) { value in
                value == .toURI ? String(localized: "To data URI") : String(localized: "From data URI")
            }
            if mode == .toURI {
                ExtraField(title: String(localized: "MIME"), text: $mime, width: 200)
                ToolEditor(title: String(localized: "Text"), text: $text, height: 110)
                HStack(spacing: 8) {
                    Button(String(localized: "Generate")) {
                        output = text.isEmpty ? "" : DataURICore.make(text: text, mime: mime.isEmpty ? "text/plain" : mime)
                        error = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button(String(localized: "Choose File…")) { chooseFile() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if let error { ToolErrorText(text: error) }
                ToolOutput(text: output)
            } else {
                ToolEditor(title: String(localized: "Data URI"), text: $text, height: 110,
                           placeholder: "data:text/plain;base64,…")
                Button(String(localized: "Decode")) {
                    switch DataURICore.parse(text) {
                    case .success(let parsed):
                        error = nil
                        output = parsed.text ?? String(localized: "Binary payload — \(parsed.data.count) bytes, \(parsed.mime)")
                    case .failure(let failure):
                        output = ""
                        error = failure.message
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                if let error { ToolErrorText(text: error) }
                ToolOutput(text: output)
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let guessed = MIMECore.mime(forExtension: url.pathExtension) ?? "application/octet-stream"
        mime = guessed
        output = DataURICore.make(data: data, mime: guessed)
        error = data.count > 1_000_000
            ? String(localized: "Large file: the URI is long and may be slow to paste")
            : nil
    }
}

struct CSVJSONToolView: View {
    private enum Mode: String, CaseIterable { case csvToJSON, jsonToCSV }

    @State private var mode: Mode = .csvToJSON
    @State private var text = ""
    @State private var output = ""
    @State private var error: String?
    @State private var delimiter = ","

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ExtraModePicker(mode: $mode) { value in
                    value == .csvToJSON ? "CSV → JSON" : "JSON → CSV"
                }
                if mode == .csvToJSON {
                    ExtraField(title: String(localized: "Delimiter"), text: $delimiter, width: 60)
                }
            }
            ToolEditor(title: mode == .csvToJSON ? "CSV" : "JSON", text: $text, height: 150)
            Button(String(localized: "Convert")) { convert() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            if let error { ToolErrorText(text: error) }
            ToolOutput(text: output)
        }
    }

    private func convert() {
        error = nil
        switch mode {
        case .csvToJSON:
            switch CSVJSONCore.csvToJSON(text, delimiter: delimiter.first ?? ",") {
            case .success(let json): output = json
            case .failure(let failure):
                output = ""
                error = failure.message
            }
        case .jsonToCSV:
            switch JSONFormatterCore.parse(text) {
            case .failure(let failure):
                output = ""
                error = failure.message
            case .success(let object):
                if let csv = JSONFormatterCore.csv(from: object) {
                    output = csv
                } else {
                    output = ""
                    error = String(localized: "This JSON has no tabular shape (array of objects/arrays).")
                }
            }
        }
    }
}

// MARK: - 网络 / 查询

struct URLParseToolView: View {
    @State private var input = "https://example.com/path?a=1&b=2#top"

    private var info: URLParseCore.Info? { URLParseCore.parse(input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExtraField(title: "URL", text: $input, width: 460, mono: false)
            if let info {
                VStack(alignment: .leading, spacing: 2) {
                    ToolValueRow(label: "Scheme", value: info.scheme, mono: false)
                    ToolValueRow(label: "Host", value: info.host, mono: false)
                    ToolValueRow(label: "Port", value: info.port.map(String.init) ?? "—", mono: false)
                    ToolValueRow(label: "Path", value: info.path.isEmpty ? "/" : info.path, mono: false)
                    ToolValueRow(label: "Fragment", value: info.fragment.isEmpty ? "—" : info.fragment, mono: false)
                    if !info.query.isEmpty {
                        Divider().padding(.vertical, 4)
                        ForEach(Array(info.query.enumerated()), id: \.offset) { _, item in
                            ToolValueRow(label: item.name, value: item.value, mono: true)
                        }
                    }
                }
            } else {
                ToolErrorText(text: String(localized: "Not a valid URL"))
            }
        }
    }
}

struct CIDRToolView: View {
    @State private var input = "192.168.1.10/24"

    private var result: Result<CIDRCore.Info, ToolboxError> { CIDRCore.parse(input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExtraField(title: "IP / CIDR", text: $input, width: 240)
            switch result {
            case .success(let info):
                VStack(alignment: .leading, spacing: 2) {
                    ToolValueRow(label: String(localized: "Network"), value: "\(info.network)/\(info.prefix)")
                    ToolValueRow(label: String(localized: "Broadcast"), value: info.broadcast)
                    ToolValueRow(label: String(localized: "Mask"), value: info.mask)
                    ToolValueRow(label: String(localized: "Host range"), value: "\(info.firstHost) – \(info.lastHost)")
                    ToolValueRow(label: String(localized: "Hosts"), value: "\(info.hostCount)")
                    ToolValueRow(label: String(localized: "Private"),
                                 value: info.isPrivate ? String(localized: "Yes") : String(localized: "No"),
                                 mono: false)
                }
            case .failure(let failure):
                ToolErrorText(text: failure.message)
            }
        }
    }
}

struct HTTPStatusToolView: View {
    @State private var query = ""

    private var rows: [(code: Int, title: String, description: String)] {
        HTTPStatusCore.search(query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ExtraField(title: String(localized: "Search"), text: $query, width: 220, mono: false)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(row.code)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(color(for: row.code))
                                .frame(width: 36, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title).font(.system(size: 11.5, weight: .medium))
                                Text(row.description).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
    }

    private func color(for code: Int) -> Color {
        switch code / 100 {
        case 2: return .green
        case 3: return .blue
        case 4: return .orange
        default: return .red
        }
    }
}

struct MIMEToolView: View {
    @State private var query = ""

    private var rows: [(ext: String, mime: String)] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = MIMECore.table.sorted { $0.key < $1.key }
            .map { (ext: $0.key, mime: $0.value) }
        guard !needle.isEmpty else { return all }
        return all.filter { $0.ext.contains(needle) || $0.mime.contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ExtraField(title: String(localized: "Search"), text: $query, width: 220, mono: false)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 8) {
                            Text("." + row.ext)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 70, alignment: .leading)
                            Text(row.mime)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
    }
}

struct UserAgentToolView: View {
    @State private var input = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolEditor(title: "User-Agent", text: $input, height: 100)
            if let info = UACore.parse(input) {
                VStack(alignment: .leading, spacing: 2) {
                    ToolValueRow(label: String(localized: "Browser"),
                                 value: info.browserVersion.isEmpty ? info.browser : "\(info.browser) \(info.browserVersion)",
                                 mono: false)
                    ToolValueRow(label: String(localized: "OS"), value: info.os, mono: false)
                    ToolValueRow(label: String(localized: "Engine"), value: info.engine, mono: false)
                }
            } else {
                ToolErrorText(text: String(localized: "Paste a User-Agent string"))
            }
        }
    }
}

// MARK: - Cron

struct CronToolView: View {
    @State private var expression = "0 9 * * 1-5"
    @State private var runs: [Date] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExtraField(title: String(localized: "Expression"), text: $expression, width: 260)
            HStack(spacing: 8) {
                Button(String(localized: "Next runs")) { evaluate() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Text(String(localized: "minute hour day month weekday"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if let error {
                ToolErrorText(text: error)
            } else if !runs.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(runs.enumerated()), id: \.offset) { index, date in
                        Text("\(index + 1). \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .onAppear(perform: evaluate)
    }

    private func evaluate() {
        switch CronCore.nextRuns(expression, count: 5) {
        case .success(let dates):
            runs = dates
            error = nil
        case .failure(let failure):
            runs = []
            error = failure.message
        }
    }
}

// MARK: - 安全

struct AESToolView: View {
    private enum Mode: String, CaseIterable { case encrypt, decrypt }

    @State private var mode: Mode = .encrypt
    @State private var password = ""
    @State private var text = ""
    @State private var output = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExtraModePicker(mode: $mode) { value in
                value == .encrypt ? String(localized: "Encrypt") : String(localized: "Decrypt")
            }
            ExtraField(title: String(localized: "Passphrase"), text: $password, width: 220, mono: false)
            ToolEditor(title: mode == .encrypt ? String(localized: "Plaintext") : String(localized: "Ciphertext"),
                       text: $text, height: 120)
            HStack(spacing: 8) {
                Button(mode == .encrypt ? String(localized: "Encrypt") : String(localized: "Decrypt")) {
                    run()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(password.isEmpty || text.isEmpty || working)
                if working { ProgressView().controlSize(.mini) }
            }
            if let error { ToolErrorText(text: error) }
            ToolOutput(text: output)
            Text(String(localized: "AES-GCM + PBKDF2-SHA256 (60,000 rounds). Keep the passphrase safe — losing it means the data cannot be recovered."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func run() {
        working = true
        error = nil
        let passwordValue = password
        let textValue = text
        let encrypting = mode == .encrypt
        Task { @MainActor in
            let result: Result<String, AESCrypto.Failure> = await Task.detached {
                encrypting ? AESCrypto.encrypt(textValue, password: passwordValue)
                           : AESCrypto.decrypt(textValue, password: passwordValue)
            }.value
            working = false
            switch result {
            case .success(let value):
                output = value
            case .failure(let failure):
                output = ""
                error = failure.message
            }
        }
    }
}

struct HMACToolView: View {
    @State private var text = ""
    @State private var key = ""

    private var signature: String {
        guard !text.isEmpty else { return "" }
        return ToolsCrypto.hmacSHA256(text, key: key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolEditor(title: String(localized: "Text"), text: $text, height: 110)
            ExtraField(title: String(localized: "Key"), text: $key, width: 220)
            ToolOutput(text: signature, title: "HMAC-SHA256")
        }
    }
}

struct FileHashToolView: View {
    @State private var fileURL: URL?
    @State private var algorithm: ToolsCrypto.Algorithm = .sha256
    @State private var digest = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(String(localized: "Choose File…")) { chooseFile() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if let fileURL {
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Picker("", selection: $algorithm) {
                ForEach(ToolsCrypto.Algorithm.allCases, id: \.self) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            Button(String(localized: "Hash")) { hash() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(fileURL == nil || working)
            if working { ProgressView().controlSize(.small) }
            if let error { ToolErrorText(text: error) }
            ToolOutput(text: digest, title: algorithm.title)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileURL = url
        digest = ""
        error = nil
    }

    private func hash() {
        guard let fileURL else { return }
        working = true
        error = nil
        let algorithm = algorithm
        Task { @MainActor in
            let value = await Task.detached {
                ToolsCrypto.hashFile(fileURL, algorithm: algorithm)
            }.value
            working = false
            if let value {
                digest = value
            } else {
                error = String(localized: "Could not read this file")
            }
        }
    }
}

struct IDCardToolView: View {
    @State private var input = ""

    private var result: Result<IDCardCore.Info, ToolboxError> { IDCardCore.validate(input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExtraField(title: String(localized: "ID number"), text: $input, width: 300)
            switch result {
            case .success(let info):
                VStack(alignment: .leading, spacing: 2) {
                    ToolValueRow(label: String(localized: "Birth date"), value: info.birthDate, mono: false)
                    ToolValueRow(label: String(localized: "Gender"),
                                 value: info.gender == "Male" ? String(localized: "Male") : String(localized: "Female"),
                                 mono: false)
                    ToolValueRow(label: String(localized: "Check digit"), value: info.checkDigit)
                }
            case .failure(let failure):
                if input.isEmpty { EmptyView() } else { ToolErrorText(text: failure.message) }
            }
            Text(String(localized: "18-digit Chinese ID numbers. Validation is local and nothing is uploaded."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

struct LuhnToolView: View {
    @State private var input = ""

    private var validation: Result<Bool, ToolboxError> { LuhnCore.validate(input) }
    private var checkDigit: Result<Int, ToolboxError> {
        LuhnCore.checkDigit(for: input)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExtraField(title: String(localized: "Card number"), text: $input, width: 300)
            switch validation {
            case .success(let valid):
                Label(valid ? String(localized: "Valid (Luhn)") : String(localized: "Invalid checksum"),
                      systemImage: valid ? "checkmark.seal" : "xmark.seal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(valid ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
            case .failure(let failure):
                if input.isEmpty { EmptyView() } else { ToolErrorText(text: failure.message) }
            }
            if case .success(let digit) = checkDigit, input.count > 1 {
                ToolValueRow(label: String(localized: "Check digit for the digits you entered"),
                             value: "\(digit)")
            }
        }
    }
}

// MARK: - 随机 / 图片

struct RandomToolView: View {
    private enum Mode: String, CaseIterable { case text, number }

    @State private var mode: Mode = .text
    @State private var length = 16
    @State private var count = 5
    @State private var useLower = true
    @State private var useUpper = true
    @State private var useDigits = true
    @State private var useSymbols = false
    @State private var minValue = "1"
    @State private var maxValue = "100"
    @State private var unique = true
    @State private var output = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExtraModePicker(mode: $mode) { value in
                value == .text ? String(localized: "Text") : String(localized: "Numbers")
            }
            if mode == .text {
                HStack(spacing: 14) {
                    Stepper(String(localized: "Length: \(length)"), value: $length, in: 1...200)
                        .font(.system(size: 11.5))
                    Stepper(String(localized: "Count: \(count)"), value: $count, in: 1...100)
                        .font(.system(size: 11.5))
                }
                HStack(spacing: 12) {
                    ToolToggle(title: String(localized: "lowercase"), isOn: $useLower)
                    ToolToggle(title: String(localized: "UPPERCASE"), isOn: $useUpper)
                    ToolToggle(title: String(localized: "Digits"), isOn: $useDigits)
                    ToolToggle(title: String(localized: "Symbols"), isOn: $useSymbols)
                }
            } else {
                HStack(spacing: 10) {
                    ExtraField(title: String(localized: "Min"), text: $minValue, width: 70)
                    ExtraField(title: String(localized: "Max"), text: $maxValue, width: 70)
                    Stepper(String(localized: "Count: \(count)"), value: $count, in: 1...100)
                        .font(.system(size: 11.5))
                    ToolToggle(title: String(localized: "Unique"), isOn: $unique)
                }
            }
            Button(String(localized: "Generate")) { generate() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            ToolOutput(text: output)
        }
        .onAppear(perform: generate)
    }

    private func generate() {
        if mode == .text {
            var alphabet = ""
            if useLower { alphabet += "abcdefghijklmnopqrstuvwxyz" }
            if useUpper { alphabet += "ABCDEFGHIJKLMNOPQRSTUVWXYZ" }
            if useDigits { alphabet += "0123456789" }
            if useSymbols { alphabet += "!@#$%^&*()-_=+[]{};:,.?/" }
            output = RandomCore.strings(length: length, alphabet: alphabet, count: count)
                .joined(separator: "\n")
        } else {
            let minValueInt = Int(minValue) ?? 0
            let maxValueInt = Int(maxValue) ?? 0
            output = RandomCore.integers(min: minValueInt, max: maxValueInt,
                                         count: count, unique: unique)
                .map(String.init).joined(separator: "\n")
        }
    }
}

struct ImageConvertToolView: View {
    @State private var source: URL?
    @State private var format: ImageConvertCore.Format = .jpeg
    @State private var maxDimension = "1600"
    @State private var note: String?
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(String(localized: "Choose Image…")) { chooseImage() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if let source {
                    Text(source.lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(spacing: 12) {
                Picker("", selection: $format) {
                    Text("PNG").tag(ImageConvertCore.Format.png)
                    Text("JPEG").tag(ImageConvertCore.Format.jpeg)
                    Text("HEIC").tag(ImageConvertCore.Format.heic)
                    Text("TIFF").tag(ImageConvertCore.Format.tiff)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                ExtraField(title: String(localized: "Max side (px)"), text: $maxDimension, width: 80)
            }
            Button(String(localized: "Convert & Save…")) { convert() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(source == nil || working)
            if working { ProgressView().controlSize(.small) }
            if let error { ToolErrorText(text: error) }
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url
        note = nil
        error = nil
    }

    private func convert() {
        guard let source else { return }
        guard let image = ImageTransforms.load(from: source) else {
            error = String(localized: "Could not load this image.")
            return
        }
        let maxDimensionInt = Int(maxDimension).flatMap { $0 > 0 ? $0 : nil }
        let target = ImageConvertCore.targetSize(width: image.width, height: image.height,
                                                 maxDimension: maxDimensionInt)
        let scaled = (target.width == image.width && target.height == image.height)
            ? image
            : (ImageTransforms.resized(image, width: target.width, height: target.height) ?? image)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ImageConvertCore.outputFileName(
            sourceName: source.lastPathComponent, format: format, maxDimension: maxDimensionInt)
        panel.allowedContentTypes = [.init(filenameExtension: format.fileExtension) ?? .data]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        working = true
        do {
            try ImageTransforms.save(scaled, to: dest)
            working = false
            error = nil
            note = String(localized: "Saved \(target.width)×\(target.height) → \(dest.lastPathComponent)")
            RecentLocalFiles.record(url: dest)
        } catch {
            working = false
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 罗马数字

struct RomanToolView: View {
    @State private var numberText = "2026"
    @State private var romanText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExtraField(title: String(localized: "Number (1–3999)"), text: $numberText, width: 160)
            if let value = Int(numberText), let roman = RomanCore.toRoman(value) {
                ToolValueRow(label: String(localized: "Roman"), value: roman)
            } else {
                ExtraField(title: String(localized: "Roman"), text: $romanText, width: 200)
                if !romanText.isEmpty {
                    if let value = RomanCore.fromRoman(romanText) {
                        ToolValueRow(label: String(localized: "Number"), value: "\(value)")
                    } else {
                        ToolErrorText(text: String(localized: "Not a valid Roman numeral"))
                    }
                }
            }
        }
    }
}

// MARK: - Excel 列号

struct ExcelColumnToolView: View {
    @State private var letters = "AA"
    @State private var numberText = "27"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExtraField(title: String(localized: "Letters"), text: $letters, width: 100)
            if let value = ExcelColumnCore.fromLetters(letters) {
                ToolValueRow(label: String(localized: "Number"), value: "\(value)")
            } else if !letters.isEmpty {
                ToolErrorText(text: String(localized: "Not valid column letters"))
            }
            Divider()
            ExtraField(title: String(localized: "Number"), text: $numberText, width: 100)
            if let number = Int(numberText), let result = ExcelColumnCore.toLetters(number) {
                ToolValueRow(label: String(localized: "Letters"), value: result)
            }
        }
    }
}

// MARK: - CRC32

struct CRC32ToolView: View {
    @State private var text = ""
    @State private var output = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolEditor(title: String(localized: "Text"), text: $text, height: 100)
            Button(String(localized: "Calculate")) {
                output = text.isEmpty ? "" : CRC32Core.hex(Data(text.utf8))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            ToolOutput(text: output, title: "CRC-32")
        }
    }
}

// MARK: - SHA3

struct SHA3ToolView: View {
    @State private var text = ""
    @State private var variant: SHA3Core.Variant = .sha3_256

    private var digest: String {
        text.isEmpty ? "" : SHA3Core.hex(Data(text.utf8), variant: variant)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolEditor(title: String(localized: "Text"), text: $text, height: 100)
            Picker("", selection: $variant) {
                ForEach(SHA3Core.Variant.allCases, id: \.self) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            ToolOutput(text: digest, title: variant.rawValue)
        }
    }
}

// MARK: - Base58

struct Base58ToolView: View {
    var body: some View {
        CodecToolView(
            inputTitle: String(localized: "Text or Base58"),
            placeholder: "hello world",
            encode: { Base58Core.encode($0) },
            decode: { Base58Core.decode($0) })
    }
}

// MARK: - 正则替换

struct RegexReplaceToolView: View {
    @State private var pattern = "(\\d+)-(\\d+)"
    @State private var template = "[$1–$2]"
    @State private var text = "Pages 3-7 and 12-15."
    @State private var output = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExtraField(title: String(localized: "Pattern"), text: $pattern, width: 300)
            ExtraField(title: String(localized: "Template"), text: $template, width: 300)
            ToolEditor(title: String(localized: "Text"), text: $text, height: 110)
            HStack(spacing: 8) {
                Button(String(localized: "Replace")) { run() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if let error { ToolErrorText(text: error) }
            ToolOutput(text: output)
        }
        .onChange(of: pattern) { _, _ in run() }
        .onChange(of: template) { _, _ in run() }
        .onChange(of: text) { _, _ in run() }
    }

    private func run() {
        switch RegexToolCore.replace(pattern: pattern, template: template, in: text) {
        case .success(let value):
            output = value
            error = nil
        case .failure(let failure):
            output = ""
            error = failure.message
        }
    }
}

// MARK: - Markdown → HTML

struct MarkdownToolView: View {
    @State private var text = "# Hello\n\nSome **bold** text."

    private var html: String {
        text.isEmpty ? "" : MarkdownHTMLCore.html(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolEditor(title: "Markdown", text: $text, height: 150)
            HStack(spacing: 8) {
                Button(String(localized: "Copy HTML")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(html, forType: .string)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(text.isEmpty)
            }
            ToolOutput(text: html, title: "HTML")
        }
    }
}

// MARK: - ASCII 表

struct ASCIIToolView: View {
    @State private var query = ""

    private var rows: [ASCIIInfoCore.Entry] { ASCIIInfoCore.search(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ExtraField(title: String(localized: "Search"), text: $query, width: 220, mono: false)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 10) {
                            Text("\(entry.decimal)")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 36, alignment: .leading)
                            Text(entry.hex)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 36, alignment: .leading)
                            Text(entry.character)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 30, alignment: .center)
                            Text(entry.description)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
    }
}

// MARK: - 占位文本

struct LoremToolView: View {
    @State private var count = 3
    @State private var chinese = false
    @State private var output = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Stepper(String(localized: "Paragraphs: \(count)"), value: $count, in: 1...20)
                    .font(.system(size: 11.5))
                ToolToggle(title: String(localized: "Chinese"), isOn: $chinese)
            }
            Button(String(localized: "Generate")) {
                output = LoremCore.paragraphs(count: count, chinese: chinese)
                    .joined(separator: "\n\n")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            ToolOutput(text: output, minHeight: 140)
        }
        .onAppear(perform: { output = LoremCore.paragraphs(count: count, chinese: chinese).joined(separator: "\n\n") })
    }
}

// MARK: - HTTP 头

struct HTTPHeadersToolView: View {
    @State private var query = ""

    private var rows: [HTTPHeadersCore.Header] { HTTPHeadersCore.search(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ExtraField(title: String(localized: "Search"), text: $query, width: 220, mono: false)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, header in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(header.name)
                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                Text(header.direction)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(header.description)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
    }
}

// MARK: - 文件信息

struct FileInfoToolView: View {
    @State private var fileURL: URL?
    @State private var info: [(String, String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(String(localized: "Choose File…")) { chooseFile() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if let fileURL {
                Text(fileURL.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            if !info.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(info.enumerated()), id: \.offset) { _, pair in
                        ToolValueRow(label: pair.0, value: pair.1, mono: false)
                    }
                }
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        var rows: [(String, String)] = []
        rows.append((String(localized: "Name"), url.lastPathComponent))
        if let size = attributes[.size] as? Int64 {
            rows.append((String(localized: "Size"), ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
        }
        if let created = attributes[.creationDate] as? Date {
            rows.append((String(localized: "Created"), created.formatted(date: .long, time: .shortened)))
        }
        if let modified = attributes[.modificationDate] as? Date {
            rows.append((String(localized: "Modified"), modified.formatted(date: .long, time: .shortened)))
        }
        let ext = url.pathExtension.lowercased()
        if let mime = MIMECore.mime(forExtension: ext) {
            rows.append((String(localized: "MIME"), mime))
        }
        // 图片尺寸 + EXIF 摘要
        if ["png", "jpg", "jpeg", "heic", "tiff", "webp"].contains(ext),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            if let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
               let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
                rows.append((String(localized: "Dimensions"), "\(width) × \(height)"))
            }
            if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
               let dateTime = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                rows.append((String(localized: "Taken"), dateTime))
            }
        }
        info = rows
    }
}

// MARK: - 折扣 / AA

struct DiscountToolView: View {
    @State private var priceText = "100"
    @State private var percentText = "88"

    private var discounted: Double? {
        guard let price = Double(priceText), let percent = Double(percentText) else { return nil }
        return ShoppingCalcCore.discounted(price: price, percent: percent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                TextField("100", text: $priceText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 120)
                Text(String(localized: "at"))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                TextField("88", text: $percentText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 80)
                Text("%").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Text("=")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Text(discounted.map { ToolFormat.money($0) } ?? "—")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
        }
    }
}

struct BillSplitToolView: View {
    @State private var totalText = "200"
    @State private var peopleCount = 4
    @State private var tipPercent = 10

    private var perPerson: Double? {
        guard let total = Double(totalText) else { return nil }
        return ShoppingCalcCore.splitBill(total: total, people: peopleCount, tipPercent: Double(tipPercent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ExtraField(title: String(localized: "Total"), text: $totalText, width: 120)
                Stepper(String(localized: "\(peopleCount) people"), value: $peopleCount, in: 1...50)
                    .font(.system(size: 11.5))
                Stepper(String(localized: "Tip: \(tipPercent)%"), value: $tipPercent, in: 0...50)
                    .font(.system(size: 11.5))
            }
            if let perPerson {
                HStack(spacing: 6) {
                    Text(String(localized: "Each person pays"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(ToolFormat.money(perPerson))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}

// MARK: - 条码

struct BarcodeToolView: View {
    @State private var text = "DESIRE-2026"
    @State private var image: NSImage?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolEditor(title: String(localized: "Text"), text: $text, height: 60,
                       placeholder: "DESIRE-2026")
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
            if let error { ToolErrorText(text: error) }
            if let image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 80)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white))
            }
        }
        .onAppear(perform: generate)
        .onChange(of: text) { _, _ in generate() }
    }

    private func generate() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { image = nil; error = nil; return }
        switch BarcodeCore.widths(for: trimmed) {
        case .failure(let failure):
            image = nil
            error = failure.message
        case .success(let widths):
            error = nil
            // 渲染：每字符 1 模块宽 = 2px，高 60px
            let moduleWidth = 2
            let totalModules = widths.reduce(0) { $0 + Int(String($1))! }
            let width = totalModules * moduleWidth
            let height = 60
            guard let context = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                error = String(localized: "Render failed")
                return
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            var x = 0
            var isBar = true
            for character in widths {
                let w = Int(String(character))! * moduleWidth
                if isBar { context.fill(CGRect(x: x, y: 0, width: w, height: height)) }
                isBar.toggle()
                x += w
            }
            guard let cg = context.makeImage() else {
                error = String(localized: "Could not render the barcode")
                return
            }
            image = NSImage(cgImage: cg, size: NSSize(width: width, height: height))
        }
    }

    private func savePNG() {
        guard let image, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "barcode.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? png.write(to: dest)
    }
}
