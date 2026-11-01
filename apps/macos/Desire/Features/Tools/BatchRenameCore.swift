import Foundation

/// 批量重命名纯逻辑（v0.8.33 文件批）：规则 → 新文件名、冲突检测（大小写不敏感）。
/// 两阶段改名在 BatchRenameEngine。纯 Foundation、进 tests/run.sh。
nonisolated enum BatchRenameCore {

    struct Rule: Equatable, Sendable {
        var find = ""
        var replacement = ""
        var useRegex = false
        var caseInsensitive = false
        var prefix = ""
        var suffix = ""
        var appendNumber = false
        var numberStart = 1
        var numberStep = 1
        var numberPadding = 2
        var appendDate = false
        var newExtension = ""
    }

    enum Conflict: String, Equatable, Sendable {
        case duplicate
        case exists
        case empty
        case invalidExtension
    }

    struct Item: Identifiable, Equatable, Sendable {
        var source: URL
        var originalName: String
        var proposedName: String
        var conflict: Conflict?
        var id: URL { source }
        var finalURL: URL {
            source.deletingLastPathComponent().appendingPathComponent(proposedName)
        }
    }

    enum RenameError: LocalizedError, Equatable {
        case invalidRegex(String)
        case conflict
        case fileOperation(String)

        var errorDescription: String? {
            switch self {
            case .invalidRegex(let message):
                return String(localized: "Invalid regular expression: \(message)")
            case .conflict:
                return String(localized: "Some names conflict. Fix them before renaming.")
            case .fileOperation(let message):
                return String(localized: "Rename failed: \(message)")
            }
        }
    }

    /// 生成改名计划。`existingNamesByDirectory` 按目录给出已有文件名（建议小写）；
    /// 批次内源文件名视为"将被释放"，不参与冲突（两阶段改名保证）。
    static func plan(urls: [URL], rule: Rule,
                     existingNamesByDirectory: [URL: Set<String>],
                     date: Date = Date()) -> Result<[Item], RenameError> {
        var items: [Item] = []
        for (index, url) in urls.enumerated() {
            let original = url.lastPathComponent
            var proposed: String
            do {
                proposed = try proposedName(for: url, rule: rule, index: index, date: date)
            } catch let error as RenameError {
                return .failure(error)
            } catch {
                return .failure(.fileOperation(error.localizedDescription))
            }
            let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
            var conflict: Conflict?
            if trimmed.isEmpty {
                conflict = .empty
            } else if !rule.newExtension.trimmingCharacters(in: .whitespaces).isEmpty,
                      normalizedExtension(rule.newExtension) == nil {
                conflict = .invalidExtension
            }
            items.append(Item(source: url, originalName: original,
                              proposedName: trimmed, conflict: conflict))
        }

        // 同目录内重名才算冲突；不同目录可以同名。
        var counts: [String: Int] = [:]
        for item in items where item.conflict == nil {
            counts[directoryKey(item.source) + "\u{1F}" + item.proposedName.lowercased(),
                   default: 0] += 1
        }
        var sourcesByDirectory: [String: Set<String>] = [:]
        for item in items {
            sourcesByDirectory[directoryKey(item.source), default: []]
                .insert(item.originalName.lowercased())
        }
        var existingByDirectory: [String: Set<String>] = [:]
        for (directory, names) in existingNamesByDirectory {
            existingByDirectory[directory.standardizedFileURL.path] =
                Set(names.map { $0.lowercased() })
        }
        for index in items.indices {
            guard items[index].conflict == nil else { continue }
            let directory = directoryKey(items[index].source)
            let key = items[index].proposedName.lowercased()
            if counts[directory + "\u{1F}" + key, default: 0] > 1 {
                items[index].conflict = .duplicate
            } else {
                let occupied = existingByDirectory[directory] ?? []
                let released = sourcesByDirectory[directory] ?? []
                if occupied.contains(key), !released.contains(key) {
                    items[index].conflict = .exists
                }
            }
        }
        return .success(items)
    }

    private static func directoryKey(_ url: URL) -> String {
        url.deletingLastPathComponent().standardizedFileURL.path
    }

    /// 单个文件的新文件名（不含路径）；正则非法时抛错。
    static func proposedName(for url: URL, rule: Rule, index: Int,
                             date: Date = Date()) throws -> String {
        var base = url.deletingPathExtension().lastPathComponent
        if !rule.find.isEmpty {
            if rule.useRegex {
                let options: NSRegularExpression.Options = rule.caseInsensitive
                    ? [.caseInsensitive] : []
                let regex: NSRegularExpression
                do {
                    regex = try NSRegularExpression(pattern: rule.find, options: options)
                } catch {
                    throw RenameError.invalidRegex(error.localizedDescription)
                }
                let range = NSRange(base.startIndex..., in: base)
                base = regex.stringByReplacingMatches(
                    in: base, options: [], range: range, withTemplate: rule.replacement)
            } else {
                base = base.replacingOccurrences(
                    of: rule.find, with: rule.replacement,
                    options: rule.caseInsensitive ? [.caseInsensitive] : [])
            }
        }
        base = rule.prefix + base + rule.suffix
        if rule.appendNumber {
            let number = rule.numberStart + index * rule.numberStep
            let padding = max(1, min(rule.numberPadding, 10))
            base += "-" + String(format: "%0\(padding)d", number)
        }
        if rule.appendDate {
            base += "-" + dateStamp(date)
        }
        base = sanitize(base)
        if base.isEmpty { return "" }
        let extensionRaw = rule.newExtension.trimmingCharacters(in: .whitespaces)
        let ext: String
        if extensionRaw.isEmpty {
            ext = url.pathExtension
        } else if let normalized = normalizedExtension(extensionRaw) {
            ext = normalized
        } else {
            ext = url.pathExtension
        }
        return ext.isEmpty ? base : base + "." + ext
    }

    /// `20261101`。
    static func dateStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    /// 去掉路径分隔符、冒号与控制字符。
    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
            .union(.controlCharacters)
            .union(.newlines)
        return name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 扩展名归一（去前导点）；非法返回 nil。
    static func normalizedExtension(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix(".") { value.removeFirst() }
        guard !value.isEmpty, !value.contains("/"), !value.contains(":"),
              !value.contains("\\") else { return nil }
        return value
    }
}

/// 两阶段批量改名（先全部改成隐藏临时名，再落到目标名），失败尽量回滚。
nonisolated enum BatchRenameEngine {

    static func apply(_ items: [BatchRenameCore.Item]) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        guard items.allSatisfy({ $0.conflict == nil }) else {
            throw BatchRenameCore.RenameError.conflict
        }
        return try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            var staged: [(temp: URL, final: URL, source: URL)] = []
            do {
                for item in items {
                    let temp = item.source.deletingLastPathComponent()
                        .appendingPathComponent(".desire-rename-\(UUID().uuidString)")
                    try manager.moveItem(at: item.source, to: temp)
                    staged.append((temp, item.finalURL, item.source))
                }
            } catch {
                for entry in staged.reversed() {
                    try? manager.moveItem(at: entry.temp, to: entry.source)
                }
                throw BatchRenameCore.RenameError.fileOperation(error.localizedDescription)
            }

            var completed: [(final: URL, source: URL)] = []
            do {
                for entry in staged {
                    try manager.moveItem(at: entry.temp, to: entry.final)
                    completed.append((entry.final, entry.source))
                }
            } catch {
                for entry in completed.reversed() {
                    try? manager.moveItem(at: entry.final, to: entry.source)
                }
                for entry in staged where manager.fileExists(atPath: entry.temp.path) {
                    try? manager.moveItem(at: entry.temp, to: entry.source)
                }
                throw BatchRenameCore.RenameError.fileOperation(error.localizedDescription)
            }
            return completed.count
        }.value
    }
}
