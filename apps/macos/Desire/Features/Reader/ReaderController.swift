import Combine
import Foundation
import WebKit

/// 阅读视图的命令桥（v0.7.29）：ReaderView 的 SwiftUI 工具栏通过它读取选区
/// 并让阅读 webview 重绘高亮。webview 由 ReaderWebView 在创建时 attach。
@MainActor
final class ReaderController: ObservableObject {
    weak var webView: WKWebView?

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func selectedAnchor() async -> (quote: String, prefix: String, suffix: String)? {
        guard let webView else { return nil }
        guard let raw = (try? await webView.evaluateJavaScript(ReaderHighlightJS.selectedAnchor)) as? String,
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let quote = (object["quote"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return nil }
        return (quote,
                object["prefix"] as? String ?? "",
                object["suffix"] as? String ?? "")
    }

    func apply(_ highlights: [ReaderHighlight]) async {
        guard let webView else { return }
        let payload: [[String: String]] = highlights.map { item in
            ["id": item.id.uuidString,
             "quote": item.quote,
             "prefix": item.prefix,
             "suffix": item.suffix,
             "color": Self.css(item.color)]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        _ = try? await webView.evaluateJavaScript(
            ReaderHighlightJS.applyScript(highlightsJSON: json))
    }

    func scrollTo(_ id: UUID) async {
        guard let webView else { return }
        let encoded = (try? JSONEncoder().encode(id.uuidString))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        _ = try? await webView.evaluateJavaScript(
            ReaderHighlightJS.scrollScript(idJSON: encoded))
    }

    // MARK: 逐段朗读（v0.8.43）：段落采集 + 朗读跟随

    /// 给正文块元素按 DOM 顺序打段落标记，返回段落文本（索引与页面元素对应）。
    /// 失败（webview 不在/解析异常）返回空数组，调用方退回整篇朗读。
    func tagParagraphs() async -> [String] {
        guard let webView else { return [] }
        guard let raw = (try? await webView.evaluateJavaScript(ReaderParagraphJS.tagScript)) as? String,
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return list
    }

    /// 高亮并滚动到指定段落（朗读跟随；元素缺失时静默无操作）。
    func scrollToParagraph(_ index: Int) async {
        guard let webView else { return }
        _ = try? await webView.evaluateJavaScript(
            ReaderParagraphJS.scrollScript(index: index))
    }

    // MARK: 整页翻译（v0.8.43）：段落译文注入/隐藏/清除

    /// 回填段落译文（增量安全；依赖 `data-desire-para` 标记，调用前先 tagParagraphs）。
    func applyTranslations(_ translations: [Int: String]) async {
        guard let webView else { return }
        _ = try? await webView.evaluateJavaScript(
            ReaderTranslationJS.applyScript(payload: ReaderTranslationJS.payload(translations)))
    }

    func setTranslationsHidden(_ hidden: Bool) async {
        guard let webView else { return }
        _ = try? await webView.evaluateJavaScript(
            ReaderTranslationJS.hiddenScript(hidden))
    }

    func clearTranslations() async {
        guard let webView else { return }
        _ = try? await webView.evaluateJavaScript(ReaderTranslationJS.removeScript)
    }

    static func css(_ color: ReaderHighlight.Color) -> String {
        switch color {
        case .yellow: return "#ffe58f"
        case .green: return "#b7eb8f"
        case .blue: return "#91d5ff"
        case .pink: return "#ffadd2"
        }
    }
}
