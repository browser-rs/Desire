import Foundation

/// 页码范围规格解析（readPdf 的 pages 参数 / extractPdfPages 已有同语义）：
/// "1-5,8,12-" → 有序页下标数组（0-based，去重、越界裁掉、开放区间补到页数）。
/// Foundation-only，进 tests/run.sh。
nonisolated enum PageRangeParser {

    /// 解析失败（无法识别的片段 / 空串）返回 nil；调用方回退全量。
    nonisolated static func parse(_ spec: String, pageCount: Int) -> [Int]? {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, pageCount > 0 else { return nil }
        var seen = Set<Int>()
        var result: [Int] = []
        func push(_ n: Int) {
            guard n >= 1, n <= pageCount, !seen.contains(n) else { return }
            seen.insert(n)
            result.append(n - 1)
        }
        for part in trimmed.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { return nil }
            // 开放区间 "N-" = 到末尾。
            if piece.hasSuffix("-") {
                let head = piece.dropLast()
                guard let start = Int(head.trimmingCharacters(in: .whitespaces)), start >= 1 else { return nil }
                for n in start...pageCount { push(n) }
                continue
            }
            let components = piece.split(separator: "-", omittingEmptySubsequences: false)
            if components.count == 1 {
                guard let n = Int(piece) else { return nil }
                push(n)
            } else if components.count == 2 {
                guard let a = Int(components[0].trimmingCharacters(in: .whitespaces)),
                      let b = Int(components[1].trimmingCharacters(in: .whitespaces)),
                      a >= 1, b >= a else { return nil }
                for n in a...b { push(n) }
            } else {
                return nil
            }
        }
        return result.isEmpty ? nil : result
    }
}
