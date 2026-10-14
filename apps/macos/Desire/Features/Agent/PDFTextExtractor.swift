import Foundation
import PDFKit

/// 本地 PDF 取文（PDFKit，端上）：合同、报告、论文直接读文本层——
/// 不必在页面里翻，也不用截图 OCR（有文本层时更快更准）。
/// 结构化富文本/表格不在本工具范围（那是 DPP pageExtract 的活）；
/// 拿不到文本层的扫描件请配合 ocrImage 用截图识别。
enum PDFTextExtractor {

    /// 逐页取文本（最多 maxChars）；打不开或无文本层返回 nil。
    static func extractText(from url: URL, maxChars: Int = 60_000) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var out = ""
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index), let text = page.string, !text.isEmpty else { continue }
            out += text
            out += "\n"
            if out.count >= maxChars { break }
        }
        guard !out.isEmpty else { return nil }
        return out.count > maxChars ? String(out.prefix(maxChars)) + "…[truncated]" : out
    }

    /// 页数（给模型一个规模感；打不开返回 nil）。
    static func pageCount(of url: URL) -> Int? {
        PDFDocument(url: url)?.pageCount
    }
}
