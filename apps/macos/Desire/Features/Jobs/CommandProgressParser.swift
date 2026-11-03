import Foundation

/// 后台命令的轻量进度协议（v0.8.40）：
/// `@@desire:progress {"percent":42,"message":"compiling"}`
/// `@@desire:artifact {"path":"/…/out.mp4"}`
/// `@@desire:link {"url":"https://…","title":"CI run"}`
/// `@@desire:phase {"name":"tests"}`
///
/// 控制行不写入日志正文；非法 JSON 返回 nil，由调用方忽略（并计数）。
nonisolated enum CommandProgressEvent: Equatable {
    case progress(percent: Double, message: String?)
    case artifact(path: String)
    case link(url: String, title: String?)
    case phase(name: String)
}

nonisolated enum CommandProgressParser {
    static let prefix = "@@desire:"

    static func parse(line: String) -> CommandProgressEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix) else { return nil }
        let body = trimmed.dropFirst(prefix.count)
        let split = body.firstIndex(where: { $0 == ":" || $0.isWhitespace })
            ?? body.endIndex
        let kind = body[..<split].trimmingCharacters(in: .whitespaces).lowercased()
        var jsonText = body[split...].trimmingCharacters(in: .whitespaces)
        if jsonText.first == ":" {
            jsonText = jsonText.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        switch kind {
        case "progress":
            guard let raw = object["percent"] as? NSNumber else { return nil }
            let value = raw.doubleValue
            guard value.isFinite else { return nil }
            let percent = value > 1 ? value / 100 : value
            return .progress(percent: min(1, max(0, percent)),
                             message: object["message"] as? String)
        case "artifact":
            guard let path = object["path"] as? String, !path.isEmpty else { return nil }
            return .artifact(path: path)
        case "link":
            guard let url = object["url"] as? String, !url.isEmpty else { return nil }
            return .link(url: url, title: object["title"] as? String)
        case "phase":
            guard let name = object["name"] as? String, !name.isEmpty else { return nil }
            return .phase(name: name)
        default:
            return nil
        }
    }
}
