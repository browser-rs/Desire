import CoreGraphics
import Foundation
import Vision

/// 条码/二维码识别引擎（v0.8.33 设计批）：Vision 端上解码，图片不离开本机。
nonisolated enum BarcodeScanEngine {

    struct Item: Sendable, Identifiable {
        var payload: String
        var symbology: String
        var id: String { symbology + "\u{1F}" + payload }
    }

    static func scan(url: URL) async throws -> [Item] {
        guard let image = PDFRasterizer.loadImage(url: url) else {
            throw BarcodeScanError.imageLoadFailed(url.lastPathComponent)
        }
        return try await scan(cgImage: image)
    }

    static func scan(cgImage: CGImage) async throws -> [Item] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectBarcodesRequest()
                request.symbologies = [
                    .qr, .aztec, .pdf417, .dataMatrix,
                    .code128, .code39, .code93, .codabar,
                    .ean8, .ean13, .upce, .itf14,
                ]
                do {
                    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                    var seen = Set<String>()
                    var items: [Item] = []
                    for observation in request.results ?? [] {
                        guard let payload = observation.payloadStringValue,
                              !payload.isEmpty else { continue }
                        let item = Item(payload: payload,
                                        symbology: observation.symbology.rawValue)
                        guard seen.insert(item.id).inserted else { continue }
                        items.append(item)
                    }
                    if items.isEmpty {
                        continuation.resume(throwing: BarcodeScanError.noBarcode)
                    } else {
                        continuation.resume(returning: items)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

nonisolated enum BarcodeScanError: LocalizedError {
    case noBarcode
    case imageLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .noBarcode:
            return String(localized: "No barcode or QR code found.")
        case .imageLoadFailed(let name):
            return String(localized: "Could not load \(name) as an image.")
        }
    }
}
