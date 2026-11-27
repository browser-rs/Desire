import Foundation

/// 定时任务链的**输出交接**（v0.8.80 批 5）：上一轮成功后的最终回答与其中出现的
/// 产物路径，可被链上下一任务的提示词引用。纯逻辑（Foundation-only），harness 直测。
///
/// 占位符（缺省不注入——旧链语义不变）：
/// - `{{prev.task}}`            上一轮任务名
/// - `{{prev.output}}`          上一轮最终回答（上限 12k 字符）
/// - `{{prev.output:1200}}`     取前 N 字符（N 上限 20k）
/// - `{{prev.artifacts}}`       回答里识别出的产物路径（每行一个；没有则 `(none)`）
nonisolated enum TaskChainTemplate {
    static let maxOutputChars = 12_000
    static let maxRequestedChars = 20_000
    static let maxArtifacts = 20

    static let placeholders = ["{{prev.task}}", "{{prev.output}}", "{{prev.artifacts}}"]

    static func hasPlaceholder(_ prompt: String) -> Bool {
        if placeholders.contains(where: { prompt.contains($0) }) { return true }
        return !outputPattern.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)).isEmpty
    }

    /// 渲染链上提示词。没有占位符时原样返回；`previousOutput` 超长先截断。
    static func render(prompt: String, previousTask: String, previousOutput: String) -> String {
        guard hasPlaceholder(prompt) else { return prompt }
        let output = String(previousOutput.prefix(maxOutputChars))
        var rendered = prompt
            .replacingOccurrences(of: "{{prev.task}}", with: previousTask)
            .replacingOccurrences(of: "{{prev.output}}", with: output)
        let artifacts = artifacts(in: previousOutput)
        let artifactText = artifacts.isEmpty ? "(none)" : artifacts.joined(separator: "\n")
        rendered = rendered.replacingOccurrences(of: "{{prev.artifacts}}", with: artifactText)
        // {{prev.output:N}}：逐个替换（N 有上限，非法数字不动）。
        let pattern = try! NSRegularExpression(pattern: #"\{\{prev\.output:(\d{1,6})\}\}"#)
        let matches = pattern.matches(in: rendered, range: NSRange(rendered.startIndex..., in: rendered))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: rendered),
                  let numberRange = Range(match.range(at: 1), in: rendered),
                  let requested = Int(rendered[numberRange]) else { continue }
            let limit = min(max(0, requested), maxRequestedChars)
            rendered.replaceSubrange(range, with: String(output.prefix(limit)))
        }
        return rendered
    }

    /// 从回答里识别产物路径：只认 ASCII 路径字符（中文标点/正文自然截断），
    /// 绝对路径、带扩展名或位于用户/临时目录。正文里的 `/api/v1` 这类接口
    /// 路径不算产物。
    static func artifacts(in text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let matches = artifactPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            var token = String(text[range])
            token = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}\"'"))
            guard token.hasPrefix("/"), token.count > 3, !token.hasPrefix("//") else { continue }
            guard !token.contains("{{"), !token.contains("}}") else { continue }
            let file = (token as NSString).lastPathComponent
            let hasExtension = file.contains(".") && !file.hasPrefix(".")
            let knownRoot = token.hasPrefix("/Users/") || token.hasPrefix("/Volumes/")
                || token.hasPrefix("/tmp/") || token.hasPrefix("/private/")
            guard hasExtension || knownRoot else { continue }
            guard seen.insert(token).inserted else { continue }
            out.append(token)
            if out.count >= maxArtifacts { break }
        }
        return out
    }

    private static let artifactPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"(?<![\w:])/[A-Za-z0-9@%+._~\-/]+"#)
    }()

    private static let outputPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\{\{prev\.output:\d{1,6}\}\}"#)
    }()
}
