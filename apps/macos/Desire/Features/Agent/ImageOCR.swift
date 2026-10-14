import Foundation
import ImageIO
import Vision

/// 端上 OCR（Apple Vision，全本地、不联网）：从图片里读出文字——
/// 截图的图表数字、收据金额、海报文案、聊天记录……「看得懂图」是替人
/// 干活的基本功。识别中英混排，精确模式。
///
/// 放在后台队列执行（Vision 一轮几百毫秒到数秒），不占主 actor。
nonisolated enum ImageOCR {

    /// 识别图片文件里的文字；失败（读不出图/无文字）返回 nil。
    static func recognizeText(at url: URL, maxChars: Int = 30_000) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: recognizeSync(at: url, maxChars: maxChars))
            }
        }
    }

    /// 同步识别（供探针/测试直调）。Vision 观测按视觉顺序返回，逐行拼接。
    static func recognizeSync(at url: URL, maxChars: Int = 30_000) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // 语言集被系统拒绝（罕见）——退回系统默认语言再试一次。
            request.recognitionLanguages = []
            do {
                try handler.perform([request])
            } catch {
                return nil
            }
        }
        let lines = (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }
        guard !lines.isEmpty else { return nil }
        let text = lines.joined(separator: "\n")
        return text.count > maxChars ? String(text.prefix(maxChars)) + "…[truncated]" : text
    }
}
