import Foundation

/// 地址栏多行批量打开纯逻辑（v0.8.31 批次二）：粘贴文本拆行、归一化、
/// 判定"是不是一组 URL"。进 tests/run.sh。
nonisolated enum URLBatch {

    /// 把多行文本拆成 URL 字符串列表：
    /// - 按换行切分（容忍 CRLF），去空行、# 注释行、首尾空白
    /// - 每行无 scheme 时补 https://（本地路径/搜索词不认——批量场景
    ///   是"复制一组链接"，含空格或非 URL 字符的行丢弃）
    /// - scheme 相对行（//example.com）补 https:
    /// 单结果时返回空数组（调用方走正常导航，不弹确认）。
    static func parse(_ text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var candidate = line
            if candidate.hasPrefix("//") {
                candidate = "https:" + candidate
            } else if !candidate.contains("://") {
                guard looksLikeHost(candidate) else { continue }
                candidate = "https://" + candidate
            }
            guard let url = URL(string: candidate),
                  let host = url.host, host.contains(".") else { continue }
            guard seen.insert(candidate).inserted else { continue }
            out.append(candidate)
        }
        return out.count > 1 ? out : []
    }

    /// 无 scheme 的行是否像主机名（有一处点、无空格、ASCII 域名字符）。
    static func looksLikeHost(_ line: String) -> Bool {
        guard !line.contains(" "), !line.contains("\t") else { return false }
        guard line.contains(".") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/?#[]@!$&'()*+,;=%")
        return line.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
