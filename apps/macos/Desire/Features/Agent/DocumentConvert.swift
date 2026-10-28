import AppKit
import Foundation
import PDFKit
import WebKit

/// 一体文档转换（v0.8.15 融合）：UI「转换为…」菜单与 Agent convertDocument
/// 工具共用的管道。路由按源类型：
/// - pdf → md/txt/docx/rtf/html（PDFTextExtractor 取文；富格式走 exportDocument）
/// - docx/doc/rtf/odt/html → pdf（textutil 取 HTML → 离屏 WKWebView pdf()）
/// - 图片 png/jpg/heic/tiff/gif/webp → pdf（多路径按序合成一份）
/// - csv/tsv/xlsx → md/csv/tsv（SpreadsheetReader 读 + SpreadsheetBuffer 序列化）
/// 全部端上完成，无网络；产物写入白名单路径由调用方 resolve。
@MainActor
enum DocumentConvert {

    struct Outcome {
        let ok: Bool
        let message: String
    }

    /// 允许的目标格式全集（工具描述里按源类型收窄）。
    static let formats = ["md", "txt", "docx", "rtf", "html", "pdf", "csv", "tsv", "xlsx"]

    static func convert(sources: [URL], format: String, to dest: URL) async -> Outcome {
        let fmt = format.lowercased()
        guard !sources.isEmpty else { return Outcome(ok: false, message: "no source") }
        let primary = sources[0]
        switch primary.pathExtension.lowercased() {
        case "pdf":
            return convertPDF(primary, format: fmt, to: dest)
        case "docx", "doc", "rtf", "rtfd", "odt", "html", "htm":
            if fmt == "pdf" {
                let ok = await htmlToPDF(from: primary, to: dest)
                return Outcome(ok: ok, message: ok ? "document → pdf" : "html→pdf conversion failed")
            }
            return Outcome(ok: false, message: "documents convert to pdf only (use exportDocument for md/docx/rtf output)")
        case "png", "jpg", "jpeg", "heic", "tiff", "gif", "webp":
            if fmt == "pdf" {
                let ok = imagesToPDF(sources, to: dest)
                return Outcome(ok: ok, message: ok ? "\(sources.count) image(s) → pdf" : "image → pdf failed (unreadable image?)")
            }
            return Outcome(ok: false, message: "images convert to pdf only")
        case "csv", "tsv", "xlsx":
            return convertTable(primary, format: fmt, to: dest)
        default:
            return Outcome(ok: false, message: "unsupported source type .\(primary.pathExtension)")
        }
    }

    // MARK: - PDF → 文本/文档

    private static func convertPDF(_ src: URL, format: String, to dest: URL) -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else {
            return Outcome(ok: false, message: "source not found")
        }
        var scannedNote = ""
        let text: String
        if let extracted = PDFTextExtractor.extractText(from: src, maxChars: 200_000) {
            text = extracted
        } else if let ocr = PDFTextExtractor.ocrText(from: src, maxChars: 100_000) {
            text = ocr
            scannedNote = " [scanned — OCR, first 20 pages]"
        } else {
            return Outcome(ok: false, message: "no text layer and OCR found nothing (image-only PDF?)")
        }
        _ = scannedNote
        switch format {
        case "md", "txt":
            do {
                try text.write(to: dest, atomically: true, encoding: .utf8)
                return Outcome(ok: true, message: "pdf → \(format) (\(text.count) chars)\(scannedNote)")
            } catch {
                return Outcome(ok: false, message: "write failed: \(error.localizedDescription)")
            }
        case "docx", "rtf", "html":
            guard DocumentText.exportDocument(content: text, format: format, to: dest) else {
                return Outcome(ok: false, message: "textutil conversion failed")
            }
            return Outcome(ok: true, message: "pdf → \(format) (\(text.count) chars)\(scannedNote)")
        default:
            return Outcome(ok: false, message: "PDF converts to md/txt/docx/rtf/html only")
        }
    }

    // MARK: - 文档 → PDF（离屏 WKWebView）

    private static func htmlToPDF(from src: URL, to dest: URL) async -> Bool {
        guard let html = DocumentText.htmlContent(from: src) else { return false }
        return await renderHTMLToPDF(html, to: dest)
    }

    /// A4 宽（794pt @96dpi）纵向渲染；高度按 scrollHeight 自适应分页。
    /// WKWebView macOS 版：loadHTMLString 返回 WKNavigation（无 completion
    /// 包装）、pdf() 用无参 async 版——加载完成经 navigationDelegate 等待。
    static func renderHTMLToPDF(_ html: String, to dest: URL) async -> Bool {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123))
        let loadDelegate = LoadFinishCoordinator()
        webView.navigationDelegate = loadDelegate   // WKWebView 持 weak，局部强引用保活到函数尾
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            loadDelegate.onFinish = { cont.resume() }
            webView.loadHTMLString(html, baseURL: nil)
        }
        try? await Task.sleep(for: .milliseconds(400))   // 字体/布局稳定
        let height: CGFloat = await withCheckedContinuation { cont in
            webView.evaluateJavaScript("document.body.scrollHeight") { value, _ in
                cont.resume(returning: (value as? CGFloat) ?? 1123)
            }
        }
        let config = WKPDFConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: 794, height: max(height, 100))
        guard let data = try? await webView.pdf() else { return false }
        return (try? data.write(to: dest)) != nil
    }

    private final class LoadFinishCoordinator: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFinish?() }
    }

    // MARK: - 图片 → PDF（多图按序合成）

    private static func imagesToPDF(_ sources: [URL], to dest: URL) -> Bool {
        let doc = PDFDocument()
        var inserted = 0
        for src in sources {
            guard let image = NSImage(contentsOf: src), let page = PDFPage(image: image) else { continue }
            doc.insert(page, at: inserted)
            inserted += 1
        }
        guard inserted > 0 else { return false }
        return doc.write(to: dest)
    }

    // MARK: - 表格 → md/csv/tsv

    private static func convertTable(_ src: URL, format: String, to dest: URL) -> Outcome {
        let ext = src.pathExtension.lowercased()
        let sheet: SpreadsheetReader.Sheet?
        if ext == "xlsx" {
            sheet = SpreadsheetReader.readXLSX(from: src, maxRows: 20_000, maxCols: 200)
        } else {
            sheet = SpreadsheetReader.readCSV(from: src, maxRows: 20_000, maxCols: 200)
        }
        guard let sheet, !sheet.rows.isEmpty else {
            return Outcome(ok: false, message: "could not read table (empty or malformed)")
        }
        switch format {
        case "csv", "tsv":
            let delim = format == "tsv" ? "\t" : ","
            let body = sheet.rows.map { row in
                row.map { field in
                    delim == "\t"
                        ? field.replacingOccurrences(of: "\t", with: " ")
                        : SpreadsheetBuffer.csvLine([field])
                }
                .joined(separator: delim)
            }
            .joined(separator: "\n")
            do {
                try (body + "\n").write(to: dest, atomically: true, encoding: .utf8)
                return Outcome(ok: true, message: "\(ext) → \(format) (\(sheet.rows.count) row(s))")
            } catch {
                return Outcome(ok: false, message: "write failed: \(error.localizedDescription)")
            }
        case "xlsx":
            let name = sheet.name == src.lastPathComponent ? "Sheet1" : sheet.name
            guard SpreadsheetXLSXWriter.write(rows: sheet.rows, sheetName: name, to: dest) else {
                return Outcome(ok: false, message: "xlsx write failed")
            }
            return Outcome(ok: true, message: "\(ext) → xlsx (\(sheet.rows.count) row(s), values only)")
        case "md":
            let header = sheet.rows[0]
            var md = "| " + header.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |\n"
            md += "|" + header.map { _ in " --- " }.joined(separator: "|") + "|\n"
            for row in sheet.rows.dropFirst() {
                let padded = row + Array(repeating: "", count: max(0, header.count - row.count))
                md += "| " + padded.prefix(header.count)
                    .map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
                    .joined(separator: " | ") + " |\n"
            }
            do {
                try md.write(to: dest, atomically: true, encoding: .utf8)
                return Outcome(ok: true, message: "\(ext) → md (\(max(0, sheet.rows.count - 1)) data row(s))")
            } catch {
                return Outcome(ok: false, message: "write failed: \(error.localizedDescription)")
            }
        default:
            return Outcome(ok: false, message: "tables convert to md/csv/tsv only")
        }
    }
}
