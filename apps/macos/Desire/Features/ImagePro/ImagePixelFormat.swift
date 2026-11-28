import CoreGraphics
import CoreImage
import Foundation

/// 文档像素格式（v0.8.85 批 1 件 1）：**工作色域 + 位深的唯一真相**。
///
/// 规矩：
/// 1. 凡是产生"文档像素"的 CGContext 一律经 `makeContext` 创建——不再有
///    `CGColorSpaceCreateDeviceRGB()` 硬编码（设备色域 ≈ sRGB 且无标记，
///    P3/Adobe RGB/16 位源图一编辑即降质）；
/// 2. 选区/图层蒙版这类**灰色 alpha 通道**保持 8 位 DeviceGray（不参与色彩
///    管理，8 位足够羽化）；
/// 3. CoreImage 输出用 `render(_:from:context:)` 按目标格式显式渲染——
///    裸 `CIContext.createCGImage` 默认 8 位 sRGB，会静默降位。
nonisolated struct ImagePixelFormat: Equatable, Sendable {

    enum WorkingSpace: String, CaseIterable, Codable, Sendable {
        case sRGB
        case displayP3

        var cgColorSpace: CGColorSpace {
            // 内置色彩空间常量在本平台恒可用（nil 只在自定义 profile 失败时出现）。
            switch self {
            case .sRGB:
                return CGColorSpace(name: CGColorSpace.sRGB)!
            case .displayP3:
                return CGColorSpace(name: CGColorSpace.displayP3)!
            }
        }

        var displayName: String {
            switch self {
            case .sRGB: return "sRGB"
            case .displayP3: return "Display P3"
            }
        }

        /// 归类：广色域（P3 / Adobe RGB）按 Display P3 工作（P3 超集覆盖
        /// Adobe RGB 的常用范围；保住广色域比逐点精确更务实）。
        static func inferred(from space: CGColorSpace?) -> WorkingSpace {
            guard let space else { return .sRGB }
            return space.isWideGamutRGB ? .displayP3 : .sRGB
        }
    }

    var space: WorkingSpace = .sRGB
    /// 8 或 16（clamp 到 16；不做浮点）。
    var bitDepth: Int = 8
    /// 打开文件时的原始配置名（如 "kCGColorSpaceDisplayP3"；新建文档为 nil）。
    var sourceProfileName: String?

    static let `default` = ImagePixelFormat()

    var clampedBitDepth: Int { bitDepth >= 16 ? 16 : 8 }

    var cgColorSpace: CGColorSpace { space.cgColorSpace }

    var bitmapInfo: CGBitmapInfo {
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        return CGContext(data: nil, width: width, height: height,
                         bitsPerComponent: clampedBitDepth, bytesPerRow: 0,
                         space: cgColorSpace, bitmapInfo: bitmapInfo.rawValue)
    }

    /// 从源图推断（16 位源 → 16 位工作；广色域源 → P3 工作）。
    static func inferred(from image: CGImage) -> ImagePixelFormat {
        ImagePixelFormat(
            space: WorkingSpace.inferred(from: image.colorSpace),
            bitDepth: image.bitsPerComponent >= 16 ? 16 : 8,
            sourceProfileName: image.colorSpace.flatMap { $0.name as String? })
    }

    /// 已有位图的格式（输出上下文跟随输入位图，避免降位）。
    /// nil 图（如空文档）回落到给定位深/色域。
    static func of(_ image: CGImage?, fallback: ImagePixelFormat = .default) -> ImagePixelFormat {
        guard let image else { return fallback }
        var format = fallback
        if let space = image.colorSpace {
            format.space = WorkingSpace.inferred(from: space)
        }
        format.bitDepth = image.bitsPerComponent >= 16 ? 16 : 8
        return format
    }

    // MARK: - CoreImage 渲染

    /// 按目标格式渲染 CI 输出。16 位用 `RGBA16`（半浮点 16 bpc），并显式指定
    /// 工作/输出色域——裸 `createCGImage(from:)` 是 8 位 sRGB，P3/16 位会被
    /// 静默降掉。
    func render(_ ciImage: CIImage, from extent: CGRect,
                using context: CIContext) -> CGImage? {
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        return context.createCGImage(
            ciImage, from: extent,
            format: clampedBitDepth >= 16 ? .RGBA16 : .RGBA8,
            colorSpace: cgColorSpace, deferred: false)
    }

    /// 给 CIContext 用的选项（工作/输出色域与本文档一致）。
    var ciContextOptions: [CIContextOption: Any] {
        [.workingColorSpace: cgColorSpace, .outputColorSpace: cgColorSpace]
    }
}

/// 导出/保存选项（v0.8.85 批 1 件 1）：目标配置、位深、DPI、元数据策略。
nonisolated struct ImageSaveOptions: Equatable, Sendable {

    enum Profile: String, CaseIterable, Codable, Sendable {
        case preserve
        case sRGB
        case displayP3
        case adobeRGB

        var displayName: String {
            switch self {
            case .preserve: return "Preserve"
            case .sRGB: return "sRGB"
            case .displayP3: return "Display P3"
            case .adobeRGB: return "Adobe RGB (1998)"
            }
        }

        var cgColorSpace: CGColorSpace? {
            switch self {
            case .preserve: return nil
            case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)
            case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)
            case .adobeRGB: return CGColorSpace(name: CGColorSpace.adobeRGB1998)
            }
        }
    }

    enum Metadata: String, CaseIterable, Codable, Sendable {
        case preserve
        case stripGPS
        case stripAll
    }

    var profile: Profile = .preserve
    /// nil = 跟随源图；jpg/webp/heic 一律 8 位（容器不支持 16 位）。
    var bitDepth: Int?
    var dpi: Double?
    var metadata: Metadata = .preserve
    var quality: Double = 0.9

    static let `default` = ImageSaveOptions()

    /// 深/广容器是否支持 16 位与非 RGB 配置。
    static func supportsDeepColor(_ ext: String) -> Bool {
        ["png", "tif", "tiff"].contains(ext.lowercased())
    }
}
