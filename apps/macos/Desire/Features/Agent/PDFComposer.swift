import Foundation
import PDFKit

/// PDF 合并 / 抽页（PDFKit，端上）：文档整理类硬活的核心。
/// 只做"结构级"操作——不改页面内容、不栅格化，文本层原样保留。
enum PDFComposer {

    /// 自有的成功/失败壳（`Result` 要求错误类型符合 Error——这里只是一段
    /// 给模型看的文案，不值得造 Error 类型）。
    enum Outcome {
        case success(Int)
        case failure(String)
    }

    /// 目标已存在时自动加 -1/-2… 后缀（不覆盖既有文件）。
    static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension()
        let ext = url.pathExtension
        for index in 1...999 {
            let candidate = URL(fileURLWithPath: "\(base.path)-\(index)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    /// 依序合并，返回总页数；任一路径打不开整单失败。
    static func merge(urls: [URL], output: URL) -> Outcome {
        guard urls.count >= 2 else { return .failure("need at least 2 PDFs to merge") }
        let merged = PDFDocument()
        var insertAt = 0
        for url in urls {
            guard let document = PDFDocument(url: url) else {
                return .failure("cannot open \(url.lastPathComponent)（可能不是 PDF 或已损坏）")
            }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                merged.insert(page, at: insertAt)
                insertAt += 1
            }
        }
        guard insertAt > 0 else { return .failure("merged document has no pages") }
        guard merged.write(to: output) else { return .failure("write failed: \(output.path)") }
        return .success(insertAt)
    }

    /// 抽取指定 1 基页号（升序）为新 PDF，返回抽取页数。
    static func extractPages(url: URL, pages: [Int], output: URL) -> Outcome {
        guard let document = PDFDocument(url: url) else {
            return .failure("cannot open \(url.lastPathComponent)（可能不是 PDF 或已损坏）")
        }
        let total = document.pageCount
        let invalid = pages.filter { $0 < 1 || $0 > total }
        guard invalid.isEmpty else {
            return .failure("页码超出范围：\(invalid.map(String.init).joined(separator: ","))（该 PDF 共 \(total) 页）")
        }
        let extracted = PDFDocument()
        var insertAt = 0
        for pageNumber in pages {
            guard let page = document.page(at: pageNumber - 1) else { continue }
            extracted.insert(page, at: insertAt)
            insertAt += 1
        }
        guard insertAt > 0 else { return .failure("no pages extracted") }
        guard extracted.write(to: output) else { return .failure("write failed: \(output.path)") }
        return .success(insertAt)
    }
}
