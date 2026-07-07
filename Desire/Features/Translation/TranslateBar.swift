import SwiftUI

struct TranslateBar: View {
    @ObservedObject var service: TranslationService
    let webView: BrowserWKWebView
    let onDismiss: () -> Void

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
                .foregroundStyle(Color.accentColor)
            } else if let source = service.sourceLanguage {
                HStack(spacing: 4) {
                    Text("This page is in")
                        .font(.caption)
                    Text(displayName(for: source))
                        .font(.caption.weight(.medium))
                }
                Button("Translate") {
                    service.translatePage(webView: webView)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            } else {
                Text("Translate this page?")
                    .font(.caption)
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
