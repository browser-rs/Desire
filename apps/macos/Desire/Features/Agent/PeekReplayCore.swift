import Foundation

/// 接管回放（v0.8.25）：用户在 Peek 期间点过/输入过/跳到哪，去敏后交还 Agent。
/// 只记**字段名与元素文字**，绝不记录输入值。
nonisolated struct PeekReplayEntry: Codable, Equatable, Sendable {
    /// click / input / navigate
    var kind: String
    var label: String
}

nonisolated enum PeekReplayCore {
    /// 渲染成一行摘要：`clicked 登录 → typed in password → went to …`。
    /// 连续重复事件合并；最多 `limit` 条（默认 8）。
    static func format(_ entries: [PeekReplayEntry], limit: Int = 8) -> String {
        var lines: [String] = []
        var last = ""
        for entry in entries {
            let line: String
            switch entry.kind {
            case "click": line = "clicked \(entry.label)"
            case "input": line = "typed in \(entry.label)"
            case "navigate": line = "went to \(entry.label)"
            default: line = "\(entry.kind) \(entry.label)"
            }
            guard !line.isEmpty else { continue }
            if line == last { continue }
            last = line
            lines.append(line)
            if lines.count >= max(1, limit) { break }
        }
        return lines.joined(separator: " → ")
    }
}
