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
    /// 逐段朗读（v0.8.43）：当前段落索引（0 起）；非逐段模式 = nil。
    @Published private(set) var currentParagraphIndex: Int?
    /// 段落总数（逐段模式）
    @Published private(set) var paragraphCount: Int = 0

    /// 电子书整章朗读（v0.8.35）：自然读完时推进下一章；阅读模式不设这两个回调。
    var onFinish: (() -> Void)?
    var onSpeakRange: ((_ location: Int, _ length: Int, _ total: Int) -> Void)?
    /// 逐段朗读：段落切换回调（段落索引），供阅读器高亮跳转。
    var onParagraphChange: ((_ index: Int) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var currentTextLength = 0
    /// 逐段模式：段落数组 + 当前索引
    private var paragraphs: [String] = []
    private var paragraphIndex = 0

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
        currentTextLength = (trimmed as NSString).length
        let settings = ReaderSpeechSettings.load()
        utterance.rate = settings.rate
        if let identifier = settings.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
        } else {
            // 语种：CJK 字符占比 > 30% 用中文 voice，否则英文。混合文本合成器
            // 会自动切换内嵌语种，voice 只决定主语言。
            let cjk = trimmed.filter { $0.isCJK }.count
            let locale = Double(cjk) / Double(max(trimmed.count, 1)) > 0.3 ? "zh-CN" : "en-US"
            utterance.voice = AVSpeechSynthesisVoice(language: locale)
                ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        synthesizer.speak(utterance)
        isSpeaking = true
        isPaused = false
    }

    /// 逐段朗读（v0.8.43 阅读器入口）：段落文本来自阅读 DOM 采集
    /// （`ReaderController.tagParagraphs`），索引与页面元素一一对应，
    /// 朗读时 `onParagraphChange` 驱动页面高亮跟随。
    func speakParagraphs(_ texts: [String]) {
        stop()
        let parts = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        paragraphs = parts
        paragraphIndex = 0
        paragraphCount = parts.count
        currentParagraphIndex = 0
        speakParagraph(at: 0)
    }

    /// 逐段朗读（兜底）：按段落分队列，自然读完自动推进下一段。
    /// 段落拆分 = 双换行或单换行（PDF 剥出文本行间有 \n）。无法与页面元素
    /// 对应（无 DOM 标记），仅当 DOM 采集失败时使用。
    func speakParagraphs(_ text: String) {
        stop()
        let parts = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        paragraphs = parts
        paragraphIndex = 0
        paragraphCount = parts.count
        currentParagraphIndex = 0
        speakParagraph(at: 0)
    }

    private func speakParagraph(at index: Int) {
        guard paragraphs.indices.contains(index) else {
            // 全部段落读完
            isSpeaking = false
            isPaused = false
            currentParagraphIndex = nil
            onFinish?()
            return
        }
        paragraphIndex = index
        currentParagraphIndex = index
        onParagraphChange?(index)
        let text = paragraphs[index]
        let utterance = AVSpeechUtterance(string: text)
        currentTextLength = (text as NSString).length
        let settings = ReaderSpeechSettings.load()
        utterance.rate = settings.rate
        if let identifier = settings.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
        } else {
            let cjk = text.filter { $0.isCJK }.count
            let locale = Double(cjk) / Double(max(text.count, 1)) > 0.3 ? "zh-CN" : "en-US"
            utterance.voice = AVSpeechSynthesisVoice(language: locale)
                ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        synthesizer.speak(utterance)
        isSpeaking = true
        isPaused = false
    }

    /// 逐段控制：跳到指定段落（下一/上一/手动跳转）。
    func speakParagraphJump(_ delta: Int) {
        guard !paragraphs.isEmpty else { return }
        let target = max(0, min(paragraphs.count - 1, paragraphIndex + delta))
        synthesizer.stopSpeaking(at: .immediate)
        speakParagraph(at: target)
    }

    var canJumpPrevious: Bool { paragraphIndex > 0 }
    var canJumpNext: Bool { paragraphIndex < paragraphs.count - 1 }

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
        paragraphs = []
        paragraphIndex = 0
        currentParagraphIndex = nil
    }

    // MARK: - AVSpeechSynthesizerDelegate（自然读完 / 被打断时归位状态）

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 逐段模式：自然读完一段 → 推进下一段（不打断队列）
            if !self.paragraphs.isEmpty,
               self.paragraphIndex < self.paragraphs.count - 1 {
                self.speakParagraph(at: self.paragraphIndex + 1)
                return
            }
            self.isSpeaking = false
            self.isPaused = false
            self.currentParagraphIndex = nil
            self.paragraphs = []
            self.onFinish?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, let onSpeakRange = self.onSpeakRange else { return }
            onSpeakRange(characterRange.location, characterRange.length,
                         self.currentTextLength)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 跳段/重开是"stopSpeaking + 立刻 speak 新段"——取消回调晚到时
            // 新段落已在队列里，不能把它刚置起的状态打掉（否则跳段后工具条
            // 闪回"未在朗读"）。
            if self.synthesizer.isSpeaking || self.synthesizer.isPaused { return }
            self.isSpeaking = false
            self.isPaused = false
        }
    }
}

private extension Character {
    var isCJK: Bool {
        unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false
    }
}
