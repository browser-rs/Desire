import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// OCR 工具引擎（v0.8.33 文档批）：图片 / PDF（按页渲染）→ 文本。
/// 复用 VisionOCRService 的识别配置（zh-Hans + en-US、精确档）；全部在
/// 后台任务里跑，页面图像不跨线程共享。
nonisolated enum OCRToolEngine {

    typealias ProgressHandler = @Sendable (_ completed: Int, _ total: Int) -> Void

    struct Page: Sendable {
        var number: Int
        var text: String
    }

    struct Result: Sendable {
        var pages: [Page]
        var text: String
    }

    /// 识别本地文件。PDF 用 pages 选页（nil = 全部），其它文件按单张图片。
    static func recognize(url: URL, pages: [Int]?, password: String?,
                          dpi: Double = 200,
                          progress: ProgressHandler? = nil) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let isPDF = url.pathExtension.lowercased() == "pdf"
            if isPDF {
                return try await recognizePDF(url: url, pages: pages, password: password,
                                              dpi: dpi, progress: progress)
            }
            guard let image = PDFRasterizer.loadImage(url: url) else {
                throw PDFToolError.imageLoadFailed(url.lastPathComponent)
            }
            progress?(0, 1)
            guard let text = try await recognizeText(in: image) else {
                progress?(1, 1)
                return Result(pages: [], text: "")
            }
            progress?(1, 1)
            return Result(pages: [Page(number: 1, text: text)], text: text)
        }.value
    }

    private static func recognizePDF(url: URL, pages: [Int]?, password: String?,
                                     dpi: Double,
                                     progress: ProgressHandler?) async throws -> Result {
        let document = try PDFRasterizer.openDocument(url: url, password: password)
        let pageCount = document.numberOfPages
        guard pageCount > 0 else { throw PDFToolError.noPages }
        let selected = pages ?? Array(1...pageCount)
        guard !selected.isEmpty else { throw PDFToolError.invalidPageRange }
        var results: [Page] = []
        for (index, number) in selected.enumerated() {
            guard number >= 1, number <= pageCount,
                  let page = document.page(at: number) else { continue }
            let size = PDFRasterizer.pageSize(page)
            let pixels = PDFToolCore.pixelSize(widthPoints: size.width,
                                               heightPoints: size.height, dpi: dpi)
            guard let image = PDFRasterizer.render(page: page,
                                                   pixelWidth: pixels.width,
                                                   pixelHeight: pixels.height) else {
                throw PDFToolError.renderFailed("\(url.lastPathComponent) · \(number)")
            }
            let text = (try await recognizeText(in: image)) ?? ""
            results.append(Page(number: number, text: text))
            progress?(index + 1, selected.count)
        }
        let combined = results
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.text)
            .joined(separator: "\n\n")
        return Result(pages: results, text: combined)
    }

    /// 单页识别；Vision 无文本时返回 nil（多页 PDF 不应因此整批失败）。
    private static func recognizeText(in image: CGImage) async throws -> String? {
        do {
            let result = try await VisionOCRService.recognize(cgImage: image)
            return result.text
        } catch let error as VisionOCRService.OCRError {
            if case .noText = error { return nil }
            throw error
        }
    }
}
