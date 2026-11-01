import CoreGraphics
import Foundation
import ImageIO

/// PDF 栅格化与图片读取（v0.8.33 文档批）：CGPDFDocument + ImageIO，
/// 不依赖 PDFKit 的渲染（可在后台任务里跑，页面对象不跨线程共享）。
nonisolated enum PDFRasterizer {

    /// 打开 PDF（可带密码）；加密且密码缺失/错误时抛 PDFToolError。
    static func openDocument(url: URL, password: String?) throws -> CGPDFDocument {
        guard let document = CGPDFDocument(url as CFURL) else {
            throw PDFToolError.cannotOpen(url.lastPathComponent)
        }
        if document.isEncrypted {
            guard let password, !password.isEmpty else {
                throw PDFToolError.passwordRequired(url.lastPathComponent)
            }
            guard document.unlockWithPassword(password) else {
                throw PDFToolError.wrongPassword(url.lastPathComponent)
            }
        }
        return document
    }

    /// 读取图片（按 EXIF 方向摆正；超过 maxPixelSize 时等比缩小）。
    static func loadImage(url: URL, maxPixelSize: Int = 12000) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 图片的 DPI（缺省 72）。
    static func imageDPI(url: URL) -> Double {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else { return 72 }
        let width = properties[kCGImagePropertyDPIWidth] as? Double
        let height = properties[kCGImagePropertyDPIHeight] as? Double
        let dpi = width ?? height ?? 72
        return dpi > 1 ? dpi : 72
    }

    /// 渲染单页到指定像素尺寸（白底、RGB；保留页面旋转）。
    static func render(page: CGPDFPage, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: pixelWidth,
                                      height: pixelHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        // getDrawingTransform 处理 cropBox 原点与页面 /Rotate。
        let transform = page.getDrawingTransform(.cropBox, rect: rect, rotate: 0,
                                                 preserveAspectRatio: true)
        context.concatenate(transform)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// 页面在 cropBox 下的点尺寸（回退 mediaBox）。
    static func pageSize(_ page: CGPDFPage) -> CGSize {
        var box = page.getBoxRect(.cropBox)
        if box.width <= 0 || box.height <= 0 {
            box = page.getBoxRect(.mediaBox)
        }
        return box.size
    }
}
