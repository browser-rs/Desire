import AppKit
import Foundation
import PDFKit
import Vision

/// 本地 PDF 取文（PDFKit，端上）：合同、报告、论文直接读文本层——
/// 不必在页面里翻，也不用截图 OCR（有文本层时更快更准）。
/// 结构化富文本/表格不在本工具范围（那是 DPP pageExtract 的活）；
/// 拿不到文本层的扫描件请配合 ocrImage 用截图识别。
enum PDFTextExtractor {

    /// 逐页取文本，按页分节带 `[p3]` 标记（模型引用可溯源）；可选页码范围
    /// （"1-5,8"，1-based——解析交给 PageRangeParser）。打不开或无文本层返回 nil。
    static func extractText(from url: URL, maxChars: Int = 60_000, pages spec: String? = nil) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let indices: [Int]
        if let spec, !spec.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let parsed = PageRangeParser.parse(spec, pageCount: doc.pageCount) else { return nil }
            indices = parsed
        } else {
            indices = Array(0..<doc.pageCount)
        }
        var out = ""
        var wroteAnyPage = false
        for index in indices {
            guard let page = doc.page(at: index), let text = page.string, !text.isEmpty else { continue }
            out += "[p\(index + 1)] "
            out += text
            out += "\n"
            wroteAnyPage = true
            if out.count >= maxChars { break }
        }
        guard wroteAnyPage else { return nil }
        return out.count > maxChars ? String(out.prefix(maxChars)) + "…[truncated]" : out
    }

    /// 页数（给模型一个规模感；打不开返回 nil）。
    static func pageCount(of url: URL) -> Int? {
        PDFDocument(url: url)?.pageCount
    }

    // MARK: - 扫描件 OCR（v0.8.16 基础件 4）

    /// 无文本层时按页渲染 → Vision 识别（页数上限 20，长扫描件请分次拆）。
    /// 每页带 [pN] 标记；识别失败/空的页跳过。全空返回 nil（真无文字）。
    static func ocrText(from url: URL, maxPages: Int = 20, maxChars: Int = 60_000) -> String? {
        guard let doc = PDFDocument(url: url), !doc.isLocked else { return nil }
        var out = ""
        let pageCap = min(doc.pageCount, maxPages)
        for index in 0..<pageCap {
            guard let page = doc.page(at: index) else { continue }
            let scale: CGFloat = 2
            let size = CGSize(width: page.bounds(for: .mediaBox).width * scale,
                              height: page.bounds(for: .mediaBox).height * scale)
            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out += "[p\(index + 1)] \(text)\n"
            if out.count >= maxChars { break }
        }
        guard !out.isEmpty else { return nil }
        return out.count > maxChars ? String(out.prefix(maxChars)) + "…[truncated]" : out
    }
}
