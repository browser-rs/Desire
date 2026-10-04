import Foundation

/// 插件 i18n（2026-10-02 审查补齐）：_locales/<locale>/messages.json 从插件
/// 包资源目录读（PluginResources）。Chrome 语义的取舍：
/// - **getMessage 是同步 API**（不返回 Promise）——宿主在注入 prologue 里
///   把整张表内联成 `window.__desireI18N`，JS 侧查表零延迟；
/// - locale 选择：UI 语言精确 → 语言前缀 → en → 首个可用目录；
/// - manifest 的 `__MSG_key__` 占位随装载替换（MSExInstaller 用
///   default_locale 的表）。
/// 占位替换纯函数进 tests/run.sh。
enum PluginI18N {
    struct MessageEntry: Codable {
        let message: String
    }

    /// 装载缓存：key = resourcesPath。重装/卸载由 PluginResources 调 invalidate。
    private nonisolated(unsafe) static var cache: [String: [String: String]] = [:]

    static func invalidate(resourcesPath: String?) {
        guard let resourcesPath else { return }
        cache.removeValue(forKey: resourcesPath)
    }

    /// 运行时消息表（按 UI 语言挑 locale）。无资源/无 _locales 返回空表
    /// ——JS 侧空表保持旧的"返回 key 本身"降级。
    static func table(resourcesPath: String?) -> [String: String] {
        guard let resourcesPath, !resourcesPath.isEmpty else { return [:] }
        if let cached = cache[resourcesPath] { return cached }
        guard let dir = PluginResources.directory(for: resourcesPath) else { return [:] }
        let localesURL = dir.appendingPathComponent("_locales", isDirectory: true)
        var tables: [String: [String: String]] = [:]
        let dirNames = (try? FileManager.default.contentsOfDirectory(atPath: localesURL.path)) ?? []
        for entry in dirNames {
            let file = localesURL
                .appendingPathComponent(entry, isDirectory: true)
                .appendingPathComponent("messages.json")
            if let data = try? Data(contentsOf: file),
               let decoded = try? JSONDecoder().decode([String: MessageEntry].self, from: data) {
                tables[entry.lowercased()] = decoded.mapValues(\.message)
            }
        }
        guard !tables.isEmpty else { return [:] }
        let result = pickTable(from: tables, preferred: Locale.preferredLanguages)
        cache[resourcesPath] = result
        return result
    }

    /// locale 选择顺序（纯函数，可测）：UI 语言精确 → 语言前缀 → en → 首个。
    static func pickTable(from tables: [String: [String: String]],
                          preferred: [String]) -> [String: String] {
        for pref in preferred {
            let normalized = pref.replacingOccurrences(of: "_", with: "-").lowercased()
            if let exact = tables[normalized] { return exact }
            let prefix = normalized.split(separator: "-").first.map(String.init) ?? ""
            if let byPrefix = tables[prefix] { return byPrefix }
        }
        if let en = tables["en"] { return en }
        return tables.values.first ?? [:]
    }

    /// Chrome 位置占位：`$1`/`$10`。**正则匹配一次收集**（`$1` 是 `$10` 的
    /// 前缀，顺序 replaceSubrange 会互吃——按 span 一次拼接）。
    static func substitute(_ template: String, _ substitutions: [String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\$(\d+)"#) else { return template }
        let ns = template as NSString
        var result = ""
        var cursor = template.startIndex
        let matches = regex.matches(in: template, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            guard let full = Range(match.range, in: template),
                  let digitsRange = Range(match.range(at: 1), in: template),
                  let index = Int(String(template[digitsRange])) else { continue }
            result += template[cursor..<full.lowerBound]
            if index >= 1, index <= substitutions.count {
                result += substitutions[index - 1]
            } else {
                result += String(template[full]) // 无对应实参保留原文
            }
            cursor = full.upperBound
        }
        result += template[cursor...]
        return result
    }

    /// 注入 prologue 片段（`window.__desireI18N = {...};\n`；无表 = 空串）。
    static func prologue(resourcesPath: String?) -> String {
        let table = table(resourcesPath: resourcesPath)
        guard !table.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: table, options: []),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return "window.__desireI18N = \(json);\n"
    }
}
