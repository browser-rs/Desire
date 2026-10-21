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

    static func css(_ color: ReaderHighlight.Color) -> String {
        switch color {
        case .yellow: return "#ffe58f"
        case .green: return "#b7eb8f"
        case .blue: return "#91d5ff"
        case .pink: return "#ffadd2"
        }
    }
}
