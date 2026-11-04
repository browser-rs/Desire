import Combine
import Foundation
import NaturalLanguage
import Translation

/// 阅读模式整页翻译（v0.8.43）：Apple Translation.framework 端上翻译
/// （与电子书整章翻译同管道），8 段一批、批间回填渐进显示、按页+语言缓存。
/// 不占 Agent 回合、不产生会话消息。webview 侧注入由 ReaderView 通过
/// `ReaderController` 完成，本模型只管翻译编排与缓存。
@MainActor
final class ReaderTranslationModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case translating
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    /// 已应用的译文（设置变化重建 webview 后回填用）
    @Published private(set) var appliedTranslations: [Int: String] = [:]
    /// 译文可见性（缓存保留，只切 body class）
    @Published var isHidden = false
    /// translationTask 消费；invalidate 触发新会话
    @Published var configuration: TranslationSession.Configuration?

    /// 每批段落数（与电子书整章翻译一致）
    private static let chunkSize = 8

    private var pendingBlocks: [ReaderTranslationBlock] = []
    private var pendingPageURL = ""
    private var pendingLanguage = ""

    var isActive: Bool { phase == .translating }
    var isApplied: Bool { !appliedTranslations.isEmpty }

    /// 翻译入口。缓存命中直接回填（`apply` 落页）后返回，不触发翻译会话。
    func start(pageURL: String, blocks: [ReaderTranslationBlock],
               apply: ([Int: String]) async -> Void) async {
        guard !blocks.isEmpty else {
            phase = .failed(String(localized: "Nothing to translate"))
            return
        }
        let sample = blocks.prefix(3).map(\.text).joined(separator: " ")
        let source = Self.detectLanguage(sample)
        let target = Self.targetSpec(source: source)
        pendingPageURL = pageURL
        pendingLanguage = target.cacheKey
        pendingBlocks = blocks
        // 无 URL（少见：离线副本等）只做会话内缓存，不落盘
        if !pageURL.isEmpty,
           let cached = ReaderTranslationStore.load(pageURL)
               .translations(pageURL: pageURL, language: target.cacheKey) {
            appliedTranslations = cached
            phase = .done
            progress = 1
            isHidden = false
            await apply(cached)
            return
        }
        phase = .translating
        progress = 0
        var config = TranslationSession.Configuration(source: source,
                                                      target: target.language)
        config.invalidate()
        configuration = config
    }

    /// `.translationTask` 的主体：分批翻译，每批回填一次（渐进显示）。
    /// 失败保留已回填的部分，错误如实上报。
    func translateAll(session: TranslationSession,
                      apply: ([Int: String]) async -> Void) async {
        guard phase == .translating, !pendingBlocks.isEmpty else { return }
        var result = appliedTranslations
        var cursor = 0
        do {
            while cursor < pendingBlocks.count {
                let chunk = Array(pendingBlocks[cursor..<min(cursor + Self.chunkSize,
                                                             pendingBlocks.count)])
                let requests = chunk.map {
                    TranslationSession.Request(
                        sourceText: $0.text,
                        clientIdentifier: String($0.id))
                }
                let responses = try await session.translations(from: requests)
                for response in responses {
                    if let id = response.clientIdentifier.flatMap(Int.init) {
                        result[id] = response.targetText
                    }
                }
                cursor += Self.chunkSize
                progress = Double(min(cursor, pendingBlocks.count))
                    / Double(pendingBlocks.count)
                appliedTranslations = result
                await apply(result)
            }
            var cache = ReaderTranslationStore.load(pendingPageURL)
            cache.save(pageURL: pendingPageURL, language: pendingLanguage,
                       translations: result)
            if !pendingPageURL.isEmpty {
                ReaderTranslationStore.save(cache, for: pendingPageURL)
            }
            phase = .done
            progress = 1
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func setHidden(_ hidden: Bool) {
        isHidden = hidden
    }

    func clear() {
        configuration = nil
        phase = .idle
        progress = 0
        appliedTranslations = [:]
        isHidden = false
        pendingBlocks = []
        guard !pendingPageURL.isEmpty else { return }
        var cache = ReaderTranslationStore.load(pendingPageURL)
        cache.remove(pageURL: pendingPageURL)
        ReaderTranslationStore.save(cache, for: pendingPageURL)
        pendingPageURL = ""
    }

    // MARK: - 语言

    static func detectLanguage(_ text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let identifier = recognizer.dominantLanguage?.rawValue else { return nil }
        return Locale.Language(identifier: identifier)
    }

    /// 目标语言 = 系统偏好语言；正文已是该语言则翻成英文（电子书同规则）。
    static func targetSpec(source: Locale.Language?) -> (language: Locale.Language,
                                                         cacheKey: String) {
        let raw = Locale.preferredLanguages.first ?? "en"
        let system = Locale.Language(identifier: raw)
        if let source, source.languageCode == system.languageCode {
            return (Locale.Language(identifier: "en"), "en")
        }
        return (system, raw)
    }
}
