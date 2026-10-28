import Foundation

/// 工具回执里的产物路径提取（v0.8.16 基础件 10：会话产物气泡）。
/// convertDocument/exportDocument/zipFiles/crew 报告等回执里的落盘路径
/// 识别为产物 chip。Foundation-only，进 tests/run.sh。
nonisolated enum ArtifactPaths {

    /// 产物扩展名（与本地文件打开路由一致的白名单）。
    static let extensions: Set<String> = [
        "pdf", "docx", "doc", "rtf", "html", "htm", "md", "txt",
        "csv", "tsv", "xlsx", "png", "jpg", "jpeg", "heic", "tiff", "gif", "zip",
    ]

    /// 全文扫描绝对产物路径（无空格路径；带空格的路径只命中"路径在行首"
    /// 的形态——由调用方 sourceLink 兜底）。去重保序，cap 防刷屏。
    nonisolated static func paths(in text: String, cap: Int = 6) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        guard let regex = try? NSRegularExpression(
            pattern: #"/[^\s"'`<>|]{1,600}"#) else { return out }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard out.count < cap else { break }
            guard let range = Range(match.range, in: text) else { continue }
            let candidate = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)"))
            let ext = (candidate as NSString).pathExtension.lowercased()
            guard extensions.contains(ext), !seen.contains(candidate) else { continue }
            // 排除常见误报：URL 里的路径段、临时目录中转件。
            if candidate.contains("temporaryDirectory") || candidate.hasPrefix("/Applications/") { continue }
            seen.insert(candidate)
            out.append(candidate)
        }
        return out
    }
}
