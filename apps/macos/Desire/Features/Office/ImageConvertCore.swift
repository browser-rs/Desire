import Foundation

/// 图片批量转换的纯逻辑（v0.8.26 办公增强）：格式归一、等比缩放尺寸与
/// 输出命名。解码/编码在 app 侧（`ImageConverter`，复用 ImageTransforms）。
nonisolated enum ImageConvertCore {

    enum Format: String, CaseIterable, Sendable {
        case png
        case jpeg
        case heic
        case tiff

        /// 文件扩展名（jpeg 用 jpg）。
        var fileExtension: String {
            self == .jpeg ? "jpg" : rawValue
        }
    }

    static func format(from raw: String?) -> Format? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        if value.hasPrefix(".") { value.removeFirst() }
        if value == "jpg" { value = "jpeg" }
        return Format(rawValue: value)
    }

    /// 等比缩放：只缩小不放大；maxDimension 为长边上限（nil/0 = 不改尺寸）。
    static func targetSize(width: Int, height: Int, maxDimension: Int?) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        guard let maxDimension, maxDimension > 0 else { return (width, height) }
        let longest = max(width, height)
        guard longest > maxDimension else { return (width, height) }
        let scale = Double(maxDimension) / Double(longest)
        let newWidth = max(1, Int((Double(width) * scale).rounded()))
        let newHeight = max(1, Int((Double(height) * scale).rounded()))
        return (newWidth, newHeight)
    }

    /// 输出文件名：原名 + 可选 "-<长边>" + 新扩展名。
    static func outputFileName(sourceName: String, format: Format,
                               maxDimension: Int?) -> String {
        let stem = (sourceName as NSString).deletingPathExtension
        var suffix = ""
        if let maxDimension, maxDimension > 0 { suffix = "-\(maxDimension)" }
        return "\(stem.isEmpty ? "image" : stem)\(suffix).\(format.fileExtension)"
    }

    /// 目标 URL：目录缺省 = 源文件所在目录；与源同路径时加 "-converted"。
    static func outputURL(source: URL, format: Format, maxDimension: Int?,
                          directory: URL? = nil) -> URL {
        let dir = directory ?? source.deletingLastPathComponent()
        let name = outputFileName(sourceName: source.lastPathComponent,
                                  format: format, maxDimension: maxDimension)
        let candidate = dir.appendingPathComponent(name)
        if candidate.standardizedFileURL == source.standardizedFileURL {
            let stem = (name as NSString).deletingPathExtension
            return dir.appendingPathComponent(stem + "-converted." + format.fileExtension)
        }
        return candidate
    }
}
