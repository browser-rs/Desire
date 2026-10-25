import Combine
import Foundation
import WebKit
import os

/// AI 双语对照（v0.7.20）：把页面块级文本逐批交给当前档案的模型翻译，译文
/// 插到对应块之后（原/译对照阅读）。与既有两条翻译路径的关系：
/// - `TranslationService`（Google 组件注入）：整页机翻替换式，走第三方；
/// - 智囊球 `.translate`（整页 AI 提示）：一次性回答，不落回页面。
/// 本条是**分块 + 回填**：批 8 块一次旁路调用（`MemoryExtractor.collectText`
/// 同管道，当前档案口径），命中即插、清空即删（导航后仍开着会重施）。
///
/// 状态按**标签**（tabID）记——同一窗口不同标签可以各自开/关。**不持久化**：
/// 临时阅读工具，重开标签不自动翻译。
@MainActor
final class BilingualReadingService: ObservableObject {
    static let shared = BilingualReadingService()

    struct Block: Decodable {
        let id: String
        let text: String
    }
    private struct CollectResult: Decodable {
        let blocks: [Block]
    }

    /// 开着双语的标签。
    @Published private(set) var activeTabIDs: Set<UUID> = []
    /// 模式（v0.8.8）：对照（译文插块后）或替换（原文就地换译文，可还原）。
    enum Mode: String {
        case interlinear
        case replace
    }
    @Published private(set) var mode: Mode = .interlinear
    /// 替换模式激活的标签（与对照模式互斥使用）。
    @Published private(set) var replaceTabIDs: Set<UUID> = []
    @Published private(set) var isRunning = false
    @Published private(set) var doneCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var lastError: String?

    private static let batchSize = 8
    private static let maxBlocks = 60
    private static let maxChars = 15_000
    /// 每次 start/stop 递增；在跑的批次落地前发现 token 变了就丢弃结果
    /// （关掉之后不该再有译文插进来）。
    private var runToken = 0

    private init() {}

    func isOn(tabID: UUID) -> Bool {
        activeTabIDs.contains(tabID)
    }

    func toggle(webView: WKWebView, tabID: UUID, preference: AgentPreferenceStore?) {
        toggleInterlinear(webView: webView, tabID: tabID, preference: preference)
    }

    func stop(webView: WKWebView, tabID: UUID) {
        activeTabIDs.remove(tabID)
        replaceTabIDs.remove(tabID)
        runToken += 1
        isRunning = false
        doneCount = 0
        totalCount = 0
        webView.evaluateJavaScript(
            "window.__desireBilingualClear && window.__desireBilingualClear();",
            completionHandler: nil)
    }

    /// 替换式开关（v0.8.8 自研整页翻译）：开着则关（还原原文），否则以
    /// 替换模式开跑。与对照模式互斥——开一个自动关另一个。
    func toggleReplace(webView: WKWebView, tabID: UUID, preference: AgentPreferenceStore?) {
        if replaceTabIDs.contains(tabID) {
            stop(webView: webView, tabID: tabID)
            return
        }
        if activeTabIDs.contains(tabID) { stop(webView: webView, tabID: tabID) }
        mode = .replace
        replaceTabIDs.insert(tabID)
        translate(webView: webView, tabID: tabID, preference: preference)
    }

    /// 对照式开关（沿用既有 toggle，补互斥）。
    func toggleInterlinear(webView: WKWebView, tabID: UUID, preference: AgentPreferenceStore?) {
        if activeTabIDs.contains(tabID) {
            stop(webView: webView, tabID: tabID)
            return
        }
        if replaceTabIDs.contains(tabID) { stop(webView: webView, tabID: tabID) }
        mode = .interlinear
        activeTabIDs.insert(tabID)
        translate(webView: webView, tabID: tabID, preference: preference)
    }

    func isReplaceOn(tabID: UUID) -> Bool { replaceTabIDs.contains(tabID) }

    /// 导航完成后按需重施（WebView.didFinish 调用）。
    func reapplyIfActive(webView: WKWebView, tabID: UUID) {
        guard isOn(tabID: tabID) else { return }
        translate(webView: webView, tabID: tabID, preference: AppState.live?.aiPreference)
    }

    /// 收集 → 分批翻译 → 逐批回填。后台 Task；状态经 @Published 暴露给工具条
    /// 与桥。
    func translate(webView: WKWebView, tabID: UUID, preference: AgentPreferenceStore?) {
        guard let preference = preference ?? AppState.live?.aiPreference else {
            lastError = String(localized: "No AI profile configured")
            return
        }
        runToken += 1
        let token = runToken
        isRunning = true
        lastError = nil
        doneCount = 0
        totalCount = 0
        // 术语表（v0.8.8 基础件 10）：记忆里 category=translation 的条目按
        // 站点作用域（scope=本站 host 或 global）注入系统提示——
        // "这个站把 X 译成 Y"这类偏好直接生效，复用既有记忆面板维护。
        let host = (webView.url?.host ?? "").lowercased()
        let glossary = AgentMemoryStore.shared.factsSnapshot.filter { fact in
            guard fact.category.lowercased() == "translation" else { return false }
            let scope = fact.scope.lowercased()
            return scope == "global" || scope == host
                || host.hasSuffix("." + scope)
        }
        let install = UserScriptLoader.load("bilingual-translate")
        webView.evaluateJavaScript(install) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                await self?.run(webView: webView, tabID: tabID, preference: preference,
                                token: token, glossary: glossary.map(\.content))
            }
        }
    }

    private func run(webView: WKWebView, tabID: UUID,
                     preference: AgentPreferenceStore, token: Int,
                     glossary: [String] = []) async {
        let collectJS = "return window.__desireBilingualCollect({ maxBlocks: \(Self.maxBlocks), maxChars: \(Self.maxChars) });"
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(
                collectJS, arguments: [:], in: nil, contentWorld: .page)
        } catch {
            Log.agent.info("bilingual: collect failed — \(error.localizedDescription, privacy: .public)")
            finish(token: token, error: String(localized: "Could not read the page text"))
            return
        }
        guard let raw,
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let collected = try? JSONDecoder().decode(CollectResult.self, from: data) else {
            finish(token: token, error: String(localized: "Could not read the page text"))
            return
        }
        let blocks = collected.blocks
        totalCount = blocks.count
        guard !blocks.isEmpty else {
            finish(token: token, error: String(localized: "No readable paragraphs on this page"))
            return
        }

        var failures = 0
        var index = 0
        while index < blocks.count {
            guard runToken == token else { return }   // 已关掉/已重开
            let batch = Array(blocks[index..<min(index + Self.batchSize, blocks.count)])
            if let translations = await Self.translateBatch(batch, preference: preference,
                                                            glossary: glossary),
               translations.count == batch.count {
                apply(batch: batch, translations: translations, webView: webView)
                doneCount += batch.count
            } else {
                failures += batch.count
            }
            index += batch.count
        }
        guard runToken == token else { return }
        finish(token: token,
               error: failures > 0
                   ? String(localized: "\(failures) block(s) could not be translated")
                   : nil)
    }

    private func apply(batch: [Block], translations: [String], webView: WKWebView) {
        let items: [[String: String]] = zip(batch, translations).map {
            ["id": $0.0.id, "text": $0.1]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8) else { return }
        // 模式分派（v0.8.8）：替换式就地换文（原文在节点上可还原），
        // 对照式插译文块（既有行为）。
        let fn = mode == .replace ? "__desireBilingualReplace" : "__desireBilingualApply"
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                "return window.\(fn)(\(json));",
                arguments: [:], in: nil, contentWorld: .page)
        }
    }

    private func finish(token: Int, error: String?) {
        guard runToken == token else { return }
        isRunning = false
        lastError = error
    }

    /// 一批的翻译调用：编号行输入，模型按同序回 JSON 数组。目标语言 = 系统
    /// 首选语言（中文系统 → 简体中文）。
    private static func translateBatch(_ batch: [Block],
                                       preference: AgentPreferenceStore,
                                       glossary: [String] = []) async -> [String]? {
        let numbered = batch.enumerated()
            .map { "\($0.offset + 1). \($0.element.text)" }
            .joined(separator: "\n")
        // 术语表：一行一条（"原文 → 译文"或任意说明行），原样并入提示。
        let glossarySection = glossary.isEmpty ? "" :
            "\nGlossary (use these exact renderings where applicable):\n"
            + glossary.joined(separator: "\n")
        let system = """
        You are a professional translator embedded in a web browser. Translate every numbered \
        paragraph below into \(targetLanguageName()). Return ONLY a JSON array of strings — one \
        translation per input paragraph, in the same order, with the same count. Never merge or \
        split paragraphs. Keep numbers, code and proper nouns intact.\(glossarySection) (DESIRE_BILINGUAL_TRANSLATE)
        """
        let output = await MemoryExtractor.collectText(
            preference: preference, system: system, user: numbered,
            onUsage: { p, c, m in
                AgentSessionStore.recordBypassUsage(kind: "bilingual", prompt: p,
                                                    completion: c, model: m)
            })
        return BilingualParsing.parseTranslations(output, expected: batch.count)
    }

    private static func targetLanguageName() -> String {
        let code = Locale.preferredLanguages.first ?? "en"
        if code.hasPrefix("zh") { return "Simplified Chinese" }
        if code.hasPrefix("ja") { return "Japanese" }
        if code.hasPrefix("ko") { return "Korean" }
        return "English"
    }
}
