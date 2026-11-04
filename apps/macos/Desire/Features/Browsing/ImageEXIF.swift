import Foundation
import ImageIO

/// EXIF 查看与编辑（v0.8.42）：读取摘要 + 编辑核心字段 + GPS 清除。
/// 写入通过 CGImageSource → CGImageDestination 复制属性（不重编码像素）。
nonisolated enum ImageEXIF {

    // MARK: - 读取

    struct Summary {
        var cameraMake: String?
        var cameraModel: String?
        var lensModel: String?
        var exposureTime: String?
        var fNumber: String?
        var iso: String?
        var focalLength: String?
        var dateTimeOriginal: String?
        var copyright: String?
        var artist: String?
        var description: String?
        var keywords: [String]
        var gpsLatitude: Double?
        var gpsLongitude: Double?
        var orientation: Int?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var fileSize: Int64?
        var formatName: String?
    }

    static func read(from url: URL) -> Summary? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
              as? [CFString: Any] else { return nil }
        var summary = Summary(
            cameraMake: nil, cameraModel: nil, lensModel: nil,
            exposureTime: nil, fNumber: nil, iso: nil, focalLength: nil,
            dateTimeOriginal: nil, copyright: nil, artist: nil,
            description: nil, keywords: [], gpsLatitude: nil, gpsLongitude: nil,
            orientation: nil, pixelWidth: nil, pixelHeight: nil,
            fileSize: nil, formatName: nil)
        summary.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
        summary.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
        summary.orientation = props[kCGImagePropertyOrientation] as? Int
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let make = exif[kCGImagePropertyExifLensMake] as? String { summary.cameraMake = make }
            if let model = exif[kCGImagePropertyExifLensModel] as? String { summary.lensModel = model }
            if let time = exif[kCGImagePropertyExifExposureTime] as? Double {
                summary.exposureTime = time >= 1 ? "\(time)s" : "1/\(Int(1 / time))s"
            }
            if let f = exif[kCGImagePropertyExifFNumber] as? Double { summary.fNumber = "ƒ/\(f)" }
            if let isoValues = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int],
               let first = isoValues.first { summary.iso = "ISO \(first)" }
            if let fl = exif[kCGImagePropertyExifFocalLength] as? Double {
                summary.focalLength = "\(Int(fl))mm"
            }
            if let dt = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                summary.dateTimeOriginal = dt
            }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if let make = tiff[kCGImagePropertyTIFFMake] as? String { summary.cameraMake = summary.cameraMake ?? make }
            if let model = tiff[kCGImagePropertyTIFFModel] as? String { summary.cameraModel = summary.cameraModel ?? model }
            if let copyright = tiff[kCGImagePropertyTIFFCopyright] as? String { summary.copyright = copyright }
            if let artist = tiff[kCGImagePropertyTIFFArtist] as? String { summary.artist = artist }
        }
        if let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            if let caption = iptc[kCGImagePropertyIPTCCaptionAbstract] as? String {
                summary.description = summary.description ?? caption
            }
            if let keywords = iptc[kCGImagePropertyIPTCKeywords] as? [String] {
                summary.keywords = keywords
            }
            if let credit = iptc["By-line" as CFString] as? String {
                summary.artist = summary.artist ?? credit
            }
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
               let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String,
               let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
               let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String {
                summary.gpsLatitude = latRef == "S" ? -lat : lat
                summary.gpsLongitude = lonRef == "W" ? -lon : lon
            }
        }
        summary.fileSize = (try? FileManager.default.attributesOfItem(
            atPath: url.path)[.size] as? Int64) ?? nil
        summary.formatName = CGImageSourceGetType(source) as String?
        return summary
    }

    // MARK: - 编辑

    /// 编辑核心字段并写回（不重编码像素）。`clearGPS` = 删除 GPS 字典。
    /// `clearAll` = 删除所有元数据（保留像素/尺寸/格式）。
    static func write(
        to url: URL, title: String?, artist: String?, copyright: String?,
        description: String?, keywords: [String], clearGPS: Bool, clearAll: Bool
    ) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        guard let type = CGImageSourceGetType(source) else { return false }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, type, CGImageSourceGetCount(source), nil) else { return false }
        let count = CGImageSourceGetCount(source)
        for index in 0..<count {
            guard var props = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                    as? [CFString: Any] else { continue }
            if clearAll {
                props.removeValue(forKey: kCGImagePropertyExifDictionary)
                props.removeValue(forKey: kCGImagePropertyTIFFDictionary)
                props.removeValue(forKey: kCGImagePropertyIPTCDictionary)
                props.removeValue(forKey: kCGImagePropertyGPSDictionary)
                props.removeValue(forKey: "XMP" as CFString)
            } else {
                if clearGPS {
                    props.removeValue(forKey: kCGImagePropertyGPSDictionary)
                }
                var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
                if let artist { tiff[kCGImagePropertyTIFFArtist] = artist }
                if let copyright { tiff[kCGImagePropertyTIFFCopyright] = copyright }
                props[kCGImagePropertyTIFFDictionary] = tiff
                var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
                if let description { exif[kCGImagePropertyExifUserComment] = description }
                props[kCGImagePropertyExifDictionary] = exif
                var iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
                if let description { iptc[kCGImagePropertyIPTCCaptionAbstract] = description }
                if !keywords.isEmpty { iptc[kCGImagePropertyIPTCKeywords] = keywords }
                props[kCGImagePropertyIPTCDictionary] = iptc
            }
            CGImageDestinationAddImageFromSource(dest, source, index,
                                                 props as CFDictionary)
        }
        return CGImageDestinationFinalize(dest)
    }
}
