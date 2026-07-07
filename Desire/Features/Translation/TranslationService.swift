import AppKit
import Combine
import Foundation
import NaturalLanguage
import WebKit

@MainActor
class TranslationService: ObservableObject {
    @Published var isTranslating = false
    @Published var sourceLanguage: Locale.Language?
    @Published var isTranslated = false
    @Published var error: String?

    private let translateWidgetJS = """
    (function() {
        if (document.getElementById('desire-translate-script')) return;
        var id = 'desire-translate-element';
        var existing = document.getElementById(id);
        if (existing) { existing.style.display = 'block'; return; }

        var div = document.createElement('div');
        div.id = id;
        div.innerHTML = '<div id="google_translate_element" style="display:none"></div>';

        var style = document.createElement('style');
        style.id = 'desire-translate-style';
        style.textContent = `
            .desire-translate-bar {
                position: fixed; top: 0; left: 0; right: 0; z-index: 2147483647;
                background: #f0f0f0; padding: 6px 16px;
                display: flex; align-items: center; gap: 8px;
                font-family: -apple-system, sans-serif; font-size: 13px;
                border-bottom: 1px solid #ddd;
            }
            .desire-translate-bar .close-btn {
                margin-left: auto; cursor: pointer; opacity: 0.6;
                border: none; background: none; font-size: 16px;
            }
            .desire-translate-bar .close-btn:hover { opacity: 1; }
        `;
        document.head.appendChild(style);

        var script = document.createElement('script');
        script.id = 'desire-translate-script';
        script.src = 'https://translate.google.com/translate_a/element.js?cb=desireGoogleTranslateInit';
        script.onerror = function() {
            document.getElementById('desire-translate-element').innerHTML = '<div style="padding:8px;text-align:center;color:red">Translation service unavailable</div>';
        };
        document.head.appendChild(script);

        window.desireGoogleTranslateInit = function() {
            new google.translate.TranslateElement({pageLanguage: 'auto', layout: google.translate.TranslateElement.InlineLayout.SIMPLE}, 'google_translate_element');
        };

        document.body.insertBefore(div, document.body.firstChild);
        return true;
    })();
    """

    private let removeWidgetJS = """
    (function() {
        var el = document.getElementById('desire-translate-element');
        if (el) el.style.display = 'none';
        var iframe = document.querySelector('iframe.goog-te-banner-frame');
        if (iframe) iframe.style.display = 'none';
        document.body.style.top = '';
        document.body.style.position = '';
        var style = document.getElementById('desire-translate-style');
        if (style) style.remove();
        return true;
    })();
    """

    func detectLanguage(webView: WKWebView) async {
        do {
            let text: String = try await withCheckedThrowingContinuation { continuation in
                webView.evaluateJavaScript("document.body.innerText.substring(0, 500)") { result, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: result as? String ?? "") }
                }
            }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            if let dominant = recognizer.dominantLanguage {
                sourceLanguage = Locale.Language(identifier: dominant.rawValue)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func translatePage(webView: WKWebView) {
        guard !isTranslating else { return }
        isTranslating = true
        error = nil

        webView.evaluateJavaScript(translateWidgetJS) { [weak self] result, error in
            Task { @MainActor in
                if let error {
                    self?.error = error.localizedDescription
                } else {
                    self?.isTranslated = true
                }
                self?.isTranslating = false
            }
        }
    }

    func showOriginal(webView: WKWebView) {
        guard isTranslated else { return }
        webView.evaluateJavaScript(removeWidgetJS) { [weak self] _, _ in
            Task { @MainActor in
                self?.isTranslated = false
            }
        }
    }
}
