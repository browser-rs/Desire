import SwiftUI

struct TranslateBar: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var service: TranslationService
    let webView: BrowserWKWebView
    let tabID: UUID
    let onDismiss: () -> Void
    /// 自研翻译管道（v0.8.8 默认引擎：替换式/对照式，走用户自配模型，
    /// 页面内容不出第三方）。
    @ObservedObject private var bilingual = BilingualReadingService.shared

    var body: some View {
        HStack(spacing: 8) {
            if service.isTranslating {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
                Text("Loading translator…")
                    .font(.caption)
            } else if service.isTranslated {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("Page translated")
                    .font(.caption)
                Button("Show Original") {
                    service.showOriginal(webView: webView)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(appAccent)
            } else if bilingual.isRunning {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
                Text(String(localized: "Translating (\(bilingual.doneCount)/\(bilingual.totalCount))"))
                    .font(.caption)
            } else if bilingual.isOn(tabID: tabID) || bilingual.isReplaceOn(tabID: tabID) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text(bilingual.isReplaceOn(tabID: tabID)
                     ? String(localized: "AI translation on (replaced)")
                     : String(localized: "AI translation on (bilingual)"))
                    .font(.caption)
                Button(String(localized: "Show Original")) {
                    bilingual.stop(webView: webView, tabID: tabID)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(appAccent)
            } else if let source = service.sourceLanguage {
                HStack(spacing: 4) {
                    Text("This page is in")
                        .font(.caption)
                    Text(displayName(for: source))
                        .font(.caption.weight(.medium))
                }
                // 自研双模式（默认）+ Google 挂件（第三方、默认收进 More）。
                Button(String(localized: "Translate (AI)")) {
                    bilingual.toggleReplace(webView: webView, tabID: tabID,
                                           preference: nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(appAccent)
                Button(String(localized: "Bilingual")) {
                    bilingual.toggleInterlinear(webView: webView, tabID: tabID,
                                               preference: nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(appAccent)
                Button(String(localized: "More")) {
                    service.translatePage(webView: webView)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(String(localized: "Third-party Google widget — page content goes to Google; kept as a fallback"))
            } else {
                Text("Translate this page?")
                    .font(.caption)
            }
            if let error = bilingual.lastError {
                Text(error)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            Spacer()

            if let error = service.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Button {
                if service.isTranslated {
                    service.showOriginal(webView: webView)
                }
                if bilingual.isOn(tabID: tabID) || bilingual.isReplaceOn(tabID: tabID) {
                    bilingual.stop(webView: webView, tabID: tabID)
                }
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func displayName(for language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier else { return "" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
