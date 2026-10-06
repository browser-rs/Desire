import AppKit
import Vision

/// 端上文字识别（0.6.9 截图 OCR）：**显式 Vision API 调用**——与已关闭的
/// Live Text 是两回事（那是 WebKit 自动浮层，见 AGENTS；这里是用户点按钮
/// 才跑的识别，数据不出机）。识别语言 zh-Hans + en-US，精确档。
enum VisionOCRService {
    struct Result {
        /// 按版面顺序的文本行。
        var lines: [String]
        /// 合并文本（行以换行连接）。
        var text: String
    }

    enum OCRError: LocalizedError {
        case noText
        var errorDescription: String? {
            switch self {
            case .noText: String(localized: "No text found in this image.")
            }
        }
    }

    /// 识别 CGImage。行按 Vision 观察值的默认顺序（top-down）。
    /// VNRecognizeTextRequest 非 Sendable——构造、执行与行提取都关在后台
    /// 闭包里，只有 [String]（Sendable）过隔离边界。精确档大图可能上百毫秒，
    /// 不能占主线程。
    static func recognize(cgImage: CGImage) async throws -> Result {
        let lines: [String] = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["zh-Hans", "en-US"]
                    request.usesLanguageCorrection = true
                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    try handler.perform([request])
                    let text = (request.results ?? []).compactMap {
                        $0.topCandidates(1).first?.string
                    }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        guard !lines.isEmpty else { throw OCRError.noText }
        return Result(lines: lines, text: lines.joined(separator: "\n"))
    }

    static func recognize(image: NSImage) async throws -> Result {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw OCRError.noText
        }
        return try await recognize(cgImage: cgImage)
    }
}
