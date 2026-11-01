import Foundation

/// PDF 工具的纯逻辑（v0.8.33 文档批）：页码范围、输出命名、DPI 像素尺寸。
/// 全部 Foundation、进 tests/run.sh；PDFKit 操作在 PDFToolEngine。
nonisolated enum PDFToolCore {

    /// 页码表达式解析结果：groups 的每个元素 = 一个输出文件包含的页码（1 基）。
    struct PagePlan: Equatable, Sendable {
        var groups: [[Int]]

        /// 按书写顺序展平（保留重复页的只第一次出现——同一文件里重复插入意义不大）。
        var flat: [Int] {
            var seen = Set<Int>()
            var result: [Int] = []
            for page in groups.flatMap({ $0 }) where seen.insert(page).inserted {
                result.append(page)
            }
            return result
        }

        var isEmpty: Bool { groups.allSatisfy(\.isEmpty) }
    }

    /// 解析页码表达式（如 `1-3,5,8-`）：
    /// - 1 基；逗号分组，每组生成一个输出文件
    /// - `N-M` 闭区间；`N-` 到末页；`-M` 从第 1 页；显式逆序（`5-3`）自动纠正
    /// - 显式上界越界钳制到末页；起点越界/空组视为语法错误（返回 nil）
    /// - 组内与组间去重（保留首次出现）
    static func parsePagePlan(_ raw: String, pageCount: Int) -> PagePlan? {
        guard pageCount > 0 else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var groups: [[Int]] = []
        for token in trimmed.components(separatedBy: ",") {
            guard let pages = parseToken(token, pageCount: pageCount), !pages.isEmpty else {
                return nil
            }
            groups.append(pages)
        }
        guard !groups.isEmpty else { return nil }
        return PagePlan(groups: groups)
    }

    /// 只要一条扁平页码序列（合并/旋转/导出图片用）。
    static func parsePageNumbers(_ raw: String, pageCount: Int) -> [Int]? {
        parsePagePlan(raw, pageCount: pageCount)?.flat
    }

    /// 单个 token → 页码（升序）；非法/空 → nil。
    private static func parseToken(_ token: String, pageCount: Int) -> [Int]? {
        let text = token.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.contains("-") {
            let parts = text.components(separatedBy: "-")
            guard parts.count == 2 else { return nil }
            let lower = parts[0].trimmingCharacters(in: .whitespaces)
            let upper = parts[1].trimmingCharacters(in: .whitespaces)
            guard !lower.isEmpty || !upper.isEmpty else { return nil }
            guard lower.isEmpty || Int(lower) != nil,
                  upper.isEmpty || Int(upper) != nil else { return nil }
            var start = lower.isEmpty ? 1 : (Int(lower) ?? 1)
            var end = upper.isEmpty ? pageCount : (Int(upper) ?? pageCount)
            // 只有显式两端才纠正逆序；`8-` 的 8 大于末页是越界，不是逆序。
            if !lower.isEmpty, !upper.isEmpty, start > end {
                swap(&start, &end)
            }
            start = max(1, start)
            end = min(pageCount, end)
            guard start <= pageCount, end >= 1, start <= end else { return nil }
            return Array(start...end)
        }
        guard let value = Int(text), value >= 1, value <= pageCount else { return nil }
        return [value]
    }

    /// 页码描述：`1,2,3,5` → `1-3,5`（按给定顺序压缩连续段）。
    static func describePages(_ pages: [Int]) -> String {
        guard !pages.isEmpty else { return "" }
        var parts: [String] = []
        var runStart = pages[0]
        var previous = pages[0]
        for page in pages.dropFirst() {
            if page == previous + 1 {
                previous = page
                continue
            }
            parts.append(runStart == previous ? "\(runStart)" : "\(runStart)-\(previous)")
            runStart = page
            previous = page
        }
        parts.append(runStart == previous ? "\(runStart)" : "\(runStart)-\(previous)")
        return parts.joined(separator: ",")
    }

    /// 范围输出文件名：`doc` + `[1,2,3,5]` → `doc-p1-3_5.pdf`。
    static func rangeFileName(stem: String, pages: [Int]) -> String {
        let described = describePages(pages).replacingOccurrences(of: ",", with: "_")
        return "\(safeStem(stem))-p\(described).pdf"
    }

    /// 逐页输出文件名：120 页时第 7 页 → `doc-p007.pdf`。
    static func perPageFileName(stem: String, page: Int, total: Int,
                                fileExtension: String = "pdf") -> String {
        let width = paddedWidth(for: total)
        let ext = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        return "\(safeStem(stem))-p\(String(format: "%0\(width)d", page))\(ext)"
    }

    /// 等比缩放并居中到目标矩形（图片合成 PDF 用）；输入非法时返回零矩形。
    static func fittedRect(width: Double, height: Double, in target: (width: Double, height: Double)) -> (
        x: Double, y: Double, width: Double, height: Double
    ) {
        guard width > 0, height > 0, target.width > 0, target.height > 0 else {
            return (0, 0, 0, 0)
        }
        let scale = min(target.width / width, target.height / height)
        let fittedWidth = width * scale
        let fittedHeight = height * scale
        return ((target.width - fittedWidth) / 2, (target.height - fittedHeight) / 2,
                fittedWidth, fittedHeight)
    }

    /// 数字补零宽度（按总页数的位数）。
    static func paddedWidth(for total: Int) -> Int {
        max(1, String(max(1, total)).count)
    }

    /// 文件名主干清洗：去掉路径分隔符/冒号/控制字符，空则回退 `output`。
    static func safeStem(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\")
            .union(.controlCharacters)
            .union(.newlines)
        let cleaned = raw.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "output" : cleaned
    }

    /// 页面点尺寸 → 目标 DPI 像素尺寸；长边超过 maxDimension 时等比缩小。
    static func pixelSize(widthPoints: Double, heightPoints: Double, dpi: Double,
                          maxDimension: Int = 20000) -> (width: Int, height: Int) {
        guard widthPoints > 0, heightPoints > 0, dpi > 0 else { return (1, 1) }
        let scale = dpi / 72.0
        var width = widthPoints * scale
        var height = heightPoints * scale
        let largest = max(width, height)
        let cap = Double(max(1, maxDimension))
        if largest > cap {
            let shrink = cap / largest
            width *= shrink
            height *= shrink
        }
        return (max(1, Int(width.rounded())), max(1, Int(height.rounded())))
    }
}
