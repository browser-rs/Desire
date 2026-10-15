import Foundation

/// PDF 页号选择串解析（纯逻辑，进 tests/run.sh）：`splitPDF` 的 `pages`
/// 参数（如 "3-5,8"）→ 排序去重后的 1 基页号数组。
/// 容忍全角逗号/空白；空段忽略；**倒序区间与 0 视为无效**（整体拒绝而不是
/// 猜——用户`3-1`多半想写`1-3`，但工具不该替用户重新解释）。
nonisolated enum PDFPageSpec {

    /// 解析成功返回升序去重的 1 基页号；任何一段无效返回 nil。
    static func parse(_ raw: String) -> [Int]? {
        let normalized = raw
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
        let pieces = normalized.split(separator: ",")
        var pages = Set<Int>()
        for piece in pieces {
            let segment = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if segment.isEmpty { continue }
            if let dash = segment.firstIndex(of: "-") {
                let lowerText = segment[segment.startIndex..<dash].trimmingCharacters(in: .whitespaces)
                let upperText = segment[segment.index(after: dash)...].trimmingCharacters(in: .whitespaces)
                guard let lower = Int(lowerText), let upper = Int(upperText),
                      lower >= 1, upper >= lower else { return nil }
                for page in lower...upper { pages.insert(page) }
            } else {
                guard let page = Int(segment), page >= 1 else { return nil }
                pages.insert(page)
            }
        }
        guard !pages.isEmpty else { return nil }
        return pages.sorted()
    }
}
