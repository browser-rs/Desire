import Foundation

/// 精确文本替换（Foundation-only，进 tests/run.sh）：editFile 工具的核心——
/// 找到唯一匹配才替换；匹配 0 次或多次（未开 all）都拒绝动手，
/// 防住"改错地方"这类难回滚的事故。替换只动 `find` 命中的区间，
/// 其余内容逐字节保留（不做任何重新排版）。
nonisolated enum FileEdit {
    enum Outcome: Equatable {
        case replaced(text: String, count: Int)
        case notFound
        case ambiguous(count: Int)
    }

    static func apply(content: String, find: String, replace: String, all: Bool = false) -> Outcome {
        guard !find.isEmpty else { return .notFound }

        var occurrences = 0
        var searchRange = content.startIndex..<content.endIndex
        while let r = content.range(of: find, range: searchRange) {
            occurrences += 1
            searchRange = r.upperBound..<content.endIndex
        }
        // 空匹配（find 非空但逻辑上无推进，如搜索已被吞掉）——range(of:) 对
        // 非空 find 一定推进，这里只做防御。
        if occurrences == 0 { return .notFound }
        if occurrences > 1 && !all { return .ambiguous(count: occurrences) }

        if all {
            return .replaced(text: content.replacingOccurrences(of: find, with: replace),
                             count: occurrences)
        }
        guard let r = content.range(of: find) else { return .notFound }
        var text = content
        text.replaceSubrange(r, with: replace)
        return .replaced(text: text, count: 1)
    }
}
