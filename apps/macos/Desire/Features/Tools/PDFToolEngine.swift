import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// PDF 文件操作引擎（v0.8.33 文档批）：合并 / 拆分 / 旋转 / 导出图片 /
/// 图片合成 PDF。页面级操作走 PDFKit（保留矢量内容与页面属性），渲染走
/// CoreGraphics（PDFRasterizer，可在后台任务里跑）。所有方法不占主线程。
nonisolated enum PDFToolEngine {

    typealias ProgressHandler = @Sendable (_ completed: Int, _ total: Int) -> Void

    struct Info: Sendable {
        var pageCount: Int
        var isLocked: Bool
    }

    enum ImageFormat: String, CaseIterable, Sendable {
        case png, jpeg
        var fileExtension: String { self == .png ? "png" : "jpg" }
        var utType: CFString {
            (self == .png ? UTType.png.identifier : UTType.jpeg.identifier) as CFString
        }
        var displayName: String { self == .png ? "PNG" : "JPEG" }
    }

    enum PageLayout: String, CaseIterable, Sendable {
        case a4, original
    }

    // MARK: - 读取信息

    static func info(for url: URL) async -> Info? {
        await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url) else { return nil }
            return Info(pageCount: document.pageCount, isLocked: document.isLocked)
        }.value
    }

    // MARK: - 合并

    /// 按给定顺序合并；`password` 用于所有加密文件（逐个尝试）。
    /// 返回总页数。保留各源文件的顶层大纲（尽力）。
    static func merge(urls: [URL], password: String?, to destination: URL,
                      progress: ProgressHandler? = nil) async throws -> Int {
        guard !urls.isEmpty else { throw PDFToolError.noPages }
        return try await Task.detached(priority: .userInitiated) {
            let output = PDFDocument()
            let outlineRoot = PDFOutline()
            var total = 0
            for (index, url) in urls.enumerated() {
                let source = try openPDF(url: url, password: password)
                let offset = output.pageCount
                for pageIndex in 0..<source.pageCount {
                    guard let page = source.page(at: pageIndex) else { continue }
                    let copy = (page.copy() as? PDFPage) ?? page
                    output.insert(copy, at: output.pageCount)
                    total += 1
                }
                appendOutline(from: source, to: output, pageOffset: offset, into: outlineRoot)
                progress?(index + 1, urls.count)
            }
            guard total > 0 else { throw PDFToolError.noPages }
            if outlineRoot.numberOfChildren > 0 {
                output.outlineRoot = outlineRoot
            }
            guard output.write(to: destination) else {
                throw PDFToolError.writeFailed(destination.lastPathComponent)
            }
            return total
        }.value
    }

    // MARK: - 拆分

    /// plan.groups 的每个元素写一个 PDF；返回写出的文件。
    static func split(url: URL, plan: PDFToolCore.PagePlan, to directory: URL,
                      password: String?, progress: ProgressHandler? = nil) async throws -> [URL] {
        guard !plan.isEmpty else { throw PDFToolError.invalidPageRange }
        return try await Task.detached(priority: .userInitiated) {
            let source = try openPDF(url: url, password: password)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stem = (url.lastPathComponent as NSString).deletingPathExtension
            var outputs: [URL] = []
            for (index, pages) in plan.groups.enumerated() {
                let output = PDFDocument()
                for pageNumber in pages {
                    guard pageNumber >= 1, pageNumber <= source.pageCount,
                          let page = source.page(at: pageNumber - 1) else { continue }
                    let copy = (page.copy() as? PDFPage) ?? page
                    output.insert(copy, at: output.pageCount)
                }
                guard output.pageCount > 0 else { continue }
                let name = PDFToolCore.rangeFileName(stem: stem, pages: pages)
                let destination = uniqueURL(in: directory, name: name)
                guard output.write(to: destination) else {
                    throw PDFToolError.writeFailed(destination.lastPathComponent)
                }
                outputs.append(destination)
                progress?(index + 1, plan.groups.count)
            }
            guard !outputs.isEmpty else { throw PDFToolError.noPages }
            return outputs
        }.value
    }

    // MARK: - 旋转

    /// quarterTurns：90° 为单位（可负）；pages 为 nil 时全部页面。
    static func rotate(url: URL, pages: [Int]?, quarterTurns: Int,
                       to destination: URL, password: String?) async throws {
        try await Task.detached(priority: .userInitiated) {
            let document = try openPDF(url: url, password: password)
            let pageCount = document.pageCount
            let selected = pages ?? Array(1...max(1, pageCount))
            guard !selected.isEmpty else { throw PDFToolError.invalidPageRange }
            for pageNumber in selected {
                guard pageNumber >= 1, pageNumber <= pageCount,
                      let page = document.page(at: pageNumber - 1) else { continue }
                let turns = quarterTurns * 90
                page.rotation = ((page.rotation + turns) % 360 + 360) % 360
            }
            guard document.write(to: destination) else {
                throw PDFToolError.writeFailed(destination.lastPathComponent)
            }
        }.value
    }

    // MARK: - PDF → 图片

    static func renderImages(url: URL, pages: [Int]?, dpi: Double,
                             format: ImageFormat, to directory: URL,
                             password: String?,
                             progress: ProgressHandler? = nil) async throws -> [URL] {
        try await Task.detached(priority: .userInitiated) {
            let document = try PDFRasterizer.openDocument(url: url, password: password)
            let pageCount = document.numberOfPages
            guard pageCount > 0 else { throw PDFToolError.noPages }
            let selected = pages ?? Array(1...pageCount)
            guard !selected.isEmpty else { throw PDFToolError.invalidPageRange }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stem = (url.lastPathComponent as NSString).deletingPathExtension
            var outputs: [URL] = []
            for (index, pageNumber) in selected.enumerated() {
                guard pageNumber >= 1, pageNumber <= pageCount,
                      let page = document.page(at: pageNumber) else { continue }
                let size = PDFRasterizer.pageSize(page)
                let pixels = PDFToolCore.pixelSize(widthPoints: size.width,
                                                   heightPoints: size.height, dpi: dpi)
                guard let image = PDFRasterizer.render(page: page,
                                                       pixelWidth: pixels.width,
                                                       pixelHeight: pixels.height) else {
                    throw PDFToolError.renderFailed("\(url.lastPathComponent) · \(pageNumber)")
                }
                let name = PDFToolCore.perPageFileName(stem: stem, page: pageNumber,
                                                       total: pageCount,
                                                       fileExtension: format.fileExtension)
                let destination = uniqueURL(in: directory, name: name)
                guard write(image: image, to: destination, format: format) else {
                    throw PDFToolError.writeFailed(destination.lastPathComponent)
                }
                outputs.append(destination)
                progress?(index + 1, selected.count)
            }
            guard !outputs.isEmpty else { throw PDFToolError.noPages }
            return outputs
        }.value
    }

    // MARK: - 图片 → PDF

    /// layout = a4 时按 A4 适配（可留白边）；original 按图片 DPI 换算实际尺寸。
    static func imagesToPDF(urls: [URL], layout: PageLayout, margin: Double,
                            to destination: URL,
                            progress: ProgressHandler? = nil) async throws -> Int {
        guard !urls.isEmpty else { throw PDFToolError.noPages }
        return try await Task.detached(priority: .userInitiated) {
            let a4 = CGSize(width: 595.28, height: 841.89)
            let marginPoints = max(0, min(margin, 200))
            var box = CGRect(origin: .zero, size: a4)
            // CGPDFContext 不会覆盖已存在的文件（另存面板已确认覆盖）。
            try? FileManager.default.removeItem(at: destination)
            guard let context = CGContext(destination as CFURL, mediaBox: &box, nil) else {
                throw PDFToolError.writeFailed(destination.lastPathComponent)
            }
            var written = 0
            for (index, url) in urls.enumerated() {
                guard let image = PDFRasterizer.loadImage(url: url) else {
                    throw PDFToolError.imageLoadFailed(url.lastPathComponent)
                }
                let imageSize = CGSize(width: image.width, height: image.height)
                var pageSize: CGSize
                var contentSize: CGSize
                switch layout {
                case .a4:
                    pageSize = a4
                    contentSize = CGSize(width: max(1, a4.width - marginPoints * 2),
                                         height: max(1, a4.height - marginPoints * 2))
                case .original:
                    let dpi = PDFRasterizer.imageDPI(url: url)
                    contentSize = CGSize(width: CGFloat(image.width) * 72 / dpi,
                                         height: CGFloat(image.height) * 72 / dpi)
                    pageSize = CGSize(width: contentSize.width + marginPoints * 2,
                                      height: contentSize.height + marginPoints * 2)
                }
                let fitted = PDFToolCore.fittedRect(width: imageSize.width,
                                                    height: imageSize.height,
                                                    in: (width: contentSize.width,
                                                         height: contentSize.height))
                let rect = CGRect(x: marginPoints + fitted.x,
                                  y: marginPoints + fitted.y,
                                  width: fitted.width, height: fitted.height)
                let media = CGRect(origin: .zero, size: pageSize)
                context.beginPDFPage([kCGPDFContextMediaBox: mediaBoxData(media)] as CFDictionary)
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.fill(media)
                context.draw(image, in: rect)
                context.endPDFPage()
                written += 1
                progress?(index + 1, urls.count)
            }
            context.closePDF()
            guard written > 0 else { throw PDFToolError.noPages }
            return written
        }.value
    }

    // MARK: - 私有

    private static func openPDF(url: URL, password: String?) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw PDFToolError.cannotOpen(url.lastPathComponent)
        }
        if document.isLocked {
            guard let password, !password.isEmpty else {
                throw PDFToolError.passwordRequired(url.lastPathComponent)
            }
            guard document.unlock(withPassword: password) else {
                throw PDFToolError.wrongPassword(url.lastPathComponent)
            }
        }
        return document
    }

    /// 源文件顶层大纲复制到合并结果；目标页按页偏移映射。
    private static func appendOutline(from source: PDFDocument, to output: PDFDocument,
                                      pageOffset: Int, into root: PDFOutline) {
        guard let sourceRoot = source.outlineRoot else { return }
        func copyChildren(of parent: PDFOutline, into target: PDFOutline) {
            for index in 0..<parent.numberOfChildren {
                guard let item = parent.child(at: index) else { continue }
                let copy = PDFOutline()
                copy.label = item.label
                if let action = item.action {
                    copy.action = action
                } else if let destination = item.destination,
                          let sourcePage = destination.page {
                    let sourceIndex = source.index(for: sourcePage)
                    if sourceIndex >= 0 {
                        let outputIndex = pageOffset + sourceIndex
                        if let outputPage = output.page(at: outputIndex) {
                            copy.destination = PDFDestination(page: outputPage,
                                                              at: destination.point)
                        }
                    }
                }
                target.insertChild(copy, at: target.numberOfChildren)
                copyChildren(of: item, into: copy)
            }
        }
        copyChildren(of: sourceRoot, into: root)
    }

    /// 同名文件已存在时追加 ` 2`、` 3`…（不覆盖用户文件）。
    private static func uniqueURL(in directory: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }

    /// `kCGPDFContextMediaBox` 要求 CFData 包一个按值存储的 CGRect。
    private static func mediaBoxData(_ rect: CGRect) -> CFData {
        var rect = rect
        return Data(bytes: &rect, count: MemoryLayout<CGRect>.size) as CFData
    }

    private static func write(image: CGImage, to url: URL, format: ImageFormat) -> Bool {        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                format.utType, 1, nil) else {
            return false
        }
        let properties: [CFString: Any] = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.9]
            : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
