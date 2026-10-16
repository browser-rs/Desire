import AVFoundation
import Combine

/// Reader 朗读（0.6.5 TTS）：AVSpeechSynthesizer 端上合成，零费用、数据不出机。
/// 一次 speak 整篇正文（合成器自带分句队列）；暂停/继续/停止由工具条驱动；
/// 切出阅读模式（onDisappear）自动停止。语种按文本首段 CJK 占比选 zh-CN/en-US。
/// 0.7.18：接 synthesizer delegate——自然读完/被打断时把 isSpeaking 归位
/// （此前只在显式 stop() 时归位：读完后工具条会一直显示"在讲"，朗读工具
/// 的"在讲吗"也失真）。
@MainActor
final class ReaderSpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = ReaderSpeechService()

    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("readerSpeechStop"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.stop()
            }
        }
    }

    /// 朗读纯文本（调用方从 readerContent HTML 剥出）。
    func speak(_ text: String) {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        // 语种：CJK 字符占比 > 30% 用中文 voice，否则英文。混合文本合成器
        // 会自动切换内嵌语种，voice 只决定主语言。
        let cjk = trimmed.filter { $0.isCJK }.count
        let locale = Double(cjk) / Double(max(trimmed.count, 1)) > 0.3 ? "zh-CN" : "en-US"
        utterance.voice = AVSpeechSynthesisVoice(language: locale) ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        isSpeaking = true
        isPaused = false
    }

    func togglePause() {
        if isPaused {
            synthesizer.continueSpeaking()
            isPaused = false
        } else {
            synthesizer.pauseSpeaking(at: .word)
            isPaused = true
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        isPaused = false
    }

    // MARK: - AVSpeechSynthesizerDelegate（自然读完 / 被打断时归位状态）

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
            self?.isPaused = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
            self?.isPaused = false
        }
    }
}

private extension Character {
    var isCJK: Bool {
        unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false
    }
}
