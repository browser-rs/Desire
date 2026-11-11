import CoreFoundation
import Foundation

/// 批量纯工具（v0.8.51 批 4）：对文件批量执行正则替换 / 摘要 / 编码转换。
/// Foundation-only、进 tests/run.sh。**绝不改动源文件**——结果写到
/// `outputDirectory`（给了的话）或源文件旁带后缀的新文件。
nonisolated enum BatchToolAction: String, CaseIterable, Sendable {
    case regexReplace
    case hash
    case encoding

    var title: String {
        switch self {
        case .regexReplace: return String(localized: "Regex Replace")
        case .hash: return String(localized: "Hash")
        case .encoding: return String(localized: "Encoding Convert")
        }
    }
}

/// 批量执行参数。正则替换按 `textEncoding` 解码文本；编码转换用
/// `fromEncoding → toEncoding`；哈希不需要编码参数。
nonisolated struct BatchToolOptions: Equatable, Sendable {
    var pattern = ""
    var template = ""
    var caseInsensitive = false
    var multiline = false
    var algorithm: ToolsCrypto.Algorithm = .sha256
    var fromEncoding = "utf-8"
    var toEncoding = "utf-8"
    var textEncoding = "utf-8"
    var outputDirectory: URL? = nil
}

nonisolated struct BatchToolFileResult: Equatable, Sendable {
    let file: URL
    var output: URL? = nil
    /// 哈希结果（只有 hash 动作有）。
    var value: String? = nil
    var error: String? = nil

    var isSuccess: Bool { error == nil }
}

/// 解析后的一次批量请求（Agent 工具与桥共用同一份解析）。
nonisolated struct BatchToolRequest: Equatable, Sendable {
    let action: BatchToolAction
    let files: [URL]
    let options: BatchToolOptions
}

nonisolated enum BatchToolCore {
    /// 单次批量的文件上限（大目录误选不该卡死应用）。
    static let maxFiles = 500

    static let encodingNames = [
        "utf-8", "utf-16", "utf-16le", "utf-16be",
        "iso-8859-1", "ascii", "gb18030", "gbk", "big5", "shift-jis",
    ]

    static func encoding(named name: String) -> String.Encoding? {
        switch name.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "utf-16", "utf16": return .utf16
        case "utf-16le", "utf16le": return .utf16LittleEndian
        case "utf-16be", "utf16be": return .utf16BigEndian
        case "iso-8859-1", "latin1": return .isoLatin1
        case "ascii": return .ascii
        case "gb18030":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "gbk":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GBK_95.rawValue)))
        case "big5":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)))
        case "shift-jis", "shiftjis", "sjis":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.shiftJIS.rawValue)))
        default: return nil
        }
    }

    /// 解析参数（Agent 工具与桥同源）：action/paths 必填，其余按动作取。
    static func parseRequest(_ body: [String: Any]) -> Result<BatchToolRequest, ToolboxError> {
        guard let raw = body["action"] as? String,
              let action = BatchToolAction(rawValue: raw) else {
            return .failure(ToolboxError(message: "action must be regexReplace | hash | encoding"))
        }
        var paths: [String] = []
        if let list = body["paths"] as? [String] {
            paths = list
        } else if let single = body["path"] as? String {
            paths = [single]
        }
        guard !paths.isEmpty else {
            return .failure(ToolboxError(message: "paths required (files or directories)"))
        }
        var options = BatchToolOptions()
        if let pattern = body["pattern"] as? String { options.pattern = pattern }
        if let template = body["template"] as? String { options.template = template }
        if let flag = body["caseInsensitive"] as? Bool { options.caseInsensitive = flag }
        if let flag = body["multiline"] as? Bool { options.multiline = flag }
        if let name = body["algorithm"] as? String,
           let algorithm = ToolsCrypto.Algorithm(rawValue: name.lowercased()) {
            options.algorithm = algorithm
        }
        if let name = body["fromEncoding"] as? String,
           encoding(named: name) != nil {
            options.fromEncoding = name
        }
        if let name = body["toEncoding"] as? String,
           encoding(named: name) != nil {
            options.toEncoding = name
        }
        if let name = body["textEncoding"] as? String,
           encoding(named: name) != nil {
            options.textEncoding = name
        }
        if let directory = body["outputDir"] as? String, !directory.isEmpty {
            let url = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return .failure(ToolboxError(message: "outputDir is not an existing directory"))
            }
            options.outputDirectory = url
        }
        if action == .regexReplace, options.pattern.isEmpty {
            return .failure(ToolboxError(message: "pattern required for regexReplace"))
        }
        let files = expand(paths: paths)
        guard !files.isEmpty else {
            return .failure(ToolboxError(message: "no readable files found in the given paths"))
        }
        return .success(BatchToolRequest(action: action, files: files, options: options))
    }

    /// 输出文件名（不改源文件）：`stem.<后缀>.ext`。
    static func outputURL(for file: URL, action: BatchToolAction,
                          options: BatchToolOptions) -> URL {
        let directory = options.outputDirectory ?? file.deletingLastPathComponent()
        let ext = file.pathExtension
        let stem = file.deletingPathExtension().lastPathComponent
        let suffix: String
        switch action {
        case .regexReplace: suffix = "batch"
        case .encoding: suffix = options.toEncoding.lowercased()
        case .hash: suffix = "hash"
        }
        let name = "\(stem).\(suffix)" + (ext.isEmpty ? "" : ".\(ext)")
        return directory.appendingPathComponent(name)
    }

    static func process(file: URL, action: BatchToolAction,
                        options: BatchToolOptions) -> BatchToolFileResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
            return BatchToolFileResult(file: file, error: "file not found")
        }
        guard !isDirectory.boolValue else {
            return BatchToolFileResult(file: file, error: "is a directory")
        }

        switch action {
        case .hash:
            guard let digest = ToolsCrypto.hashFile(file, algorithm: options.algorithm) else {
                return BatchToolFileResult(file: file, error: "cannot read file")
            }
            return BatchToolFileResult(file: file, value: digest)

        case .regexReplace:
            guard !options.pattern.isEmpty else {
                return BatchToolFileResult(file: file, error: "pattern is empty")
            }
            guard let encoding = encoding(named: options.textEncoding) else {
                return BatchToolFileResult(file: file,
                                           error: "unknown encoding \(options.textEncoding)")
            }
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: encoding) else {
                return BatchToolFileResult(file: file,
                                           error: "cannot decode as \(options.textEncoding)")
            }
            let replaced: String
            switch RegexToolCore.replace(pattern: options.pattern,
                                         template: options.template,
                                         in: text,
                                         caseInsensitive: options.caseInsensitive,
                                         multiline: options.multiline) {
            case .success(let value): replaced = value
            case .failure(let error): return BatchToolFileResult(file: file, error: error.message)
            }
            let output = outputURL(for: file, action: action, options: options)
            return write(replaced, encoding: encoding, to: output, file: file)

        case .encoding:
            guard let from = encoding(named: options.fromEncoding) else {
                return BatchToolFileResult(file: file,
                                           error: "unknown encoding \(options.fromEncoding)")
            }
            guard let to = encoding(named: options.toEncoding) else {
                return BatchToolFileResult(file: file,
                                           error: "unknown encoding \(options.toEncoding)")
            }
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: from) else {
                return BatchToolFileResult(file: file,
                                           error: "cannot decode as \(options.fromEncoding)")
            }
            guard let converted = text.data(using: to) else {
                return BatchToolFileResult(file: file,
                                           error: "cannot encode as \(options.toEncoding)")
            }
            let output = outputURL(for: file, action: action, options: options)
            do {
                try ensureDirectory(output.deletingLastPathComponent())
                try converted.write(to: output, options: .atomic)
            } catch {
                return BatchToolFileResult(file: file, error: error.localizedDescription)
            }
            return BatchToolFileResult(file: file, output: output)
        }
    }

    private static func write(_ text: String, encoding: String.Encoding, to output: URL,
                              file: URL) -> BatchToolFileResult {
        guard let data = text.data(using: encoding) else {
            return BatchToolFileResult(file: file, error: "cannot encode result")
        }
        do {
            try ensureDirectory(output.deletingLastPathComponent())
            try data.write(to: output, options: .atomic)
        } catch {
            return BatchToolFileResult(file: file, error: error.localizedDescription)
        }
        return BatchToolFileResult(file: file, output: output)
    }

    private static func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            if isDirectory.boolValue { return }
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// 目录展开（非递归，只取普通文件），最多 `maxFiles` 个。
    static func expand(paths: [String]) -> [URL] {
        var urls: [URL] = []
        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles])) ?? []
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let regular = (try? child.resourceValues(forKeys: [.isRegularFileKey]))?
                        .isRegularFile ?? false
                    if regular { urls.append(child) }
                    if urls.count >= maxFiles { return urls }
                }
            } else {
                urls.append(url)
                if urls.count >= maxFiles { return urls }
            }
        }
        return urls
    }

    /// 作业回执：逐文件结果（成功行带输出/摘要，失败行带原因），多行截断。
    static func summary(action: BatchToolAction, results: [BatchToolFileResult],
                        maxLines: Int = 100) -> String {
        let succeeded = results.filter(\.isSuccess).count
        var lines = ["Batch \(action.title): \(succeeded)/\(results.count) ok"]
        for result in results.prefix(maxLines) {
            let name = result.file.lastPathComponent
            if let error = result.error {
                lines.append("✗ \(name) — \(error)")
            } else if let value = result.value {
                lines.append("✓ \(name) — \(value)")
            } else if let output = result.output {
                lines.append("✓ \(name) → \(output.path)")
            } else {
                lines.append("✓ \(name)")
            }
        }
        if results.count > maxLines {
            lines.append("…and \(results.count - maxLines) more")
        }
        return lines.joined(separator: "\n")
    }
}
