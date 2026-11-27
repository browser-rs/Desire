import AppKit
import SwiftUI

struct TranslateBar: View {
    @State private var exporting = false
    @State private var savingBook = false
    @State private var bookConfirmation: String?
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var service: TranslationService
    let webView: BrowserWKWebView
    let tabID: UUID
    let onDismiss: () -> Void
    /// 自研翻译管道（v0.8.8 默认引擎：替换式/对照式，走用户自配模型，
    /// 页面内容不出第三方）。
    @ObservedObject private var bilingual = BilingualReadingService.shared
    /// 翻译缓存体量（v0.8.80 批 5）：条上可见 + 可清。
    @State private var cachePages = 0
    @State private var cacheChars = 0

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
                if let usage = usageLabel {
                    Text(usage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else if bilingual.isOn(tabID: tabID) || bilingual.isReplaceOn(tabID: tabID) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text(bilingual.isReplaceOn(tabID: tabID)
                     ? String(localized: "AI translation on (replaced)")
                     : String(localized: "AI translation on (bilingual)"))
                    .font(.caption)
                if let usage = usageLabel {
                    Text(usage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if bilingual.isReplaceOn(tabID: tabID) == false {
                    // 双语导出（v0.8.62 批 3）：Markdown 对照落下载目录。
                    Button {
                        exporting = true
                        Task {
                            let url = await bilingual.exportMarkdown(webView: webView, tabID: tabID)
                            await MainActor.run {
                                exporting = false
                                if let url {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                        }
                    } label: {
                        if exporting {
                            ProgressView().scaleEffect(0.6)
                        } else {
                            Image(systemName: "square.and.arrow.up.on.square")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appAccent)
                    .help(String(localized: "Export bilingual markdown to Downloads"))
                    // 双语成书（v0.8.64 批 2）：对照对 → HTML 书落书架。
                    Button {
                        savingBook = true
                        Task {
                            let confirmation = await bilingual.saveBilingualBook(
                                webView: webView, tabID: tabID)
                            await MainActor.run {
                                savingBook = false
                                bookConfirmation = confirmation
                                if confirmation != nil {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                        bookConfirmation = nil
                                    }
                                }
                            }
                        }
                    } label: {
                        if savingBook {
                            ProgressView().scaleEffect(0.6)
                        } else if bookConfirmation != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "book.closed")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appAccent)
                    .help(bookConfirmation ?? String(localized: "Save the bilingual pairs as a book in the library"))
                    .disabled(savingBook)
                }
                if bilingual.lastError != nil {
                    Button(String(localized: "Retry Failed Blocks")) {
                        bilingual.translate(webView: webView, tabID: tabID,
                                            preference: AppState.live?.aiPreference)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(appAccent)
                }
                if cachePages > 0 {
                    Menu {
                        Text(String(localized: "Translation cache: \(cachePages) page(s), \(cacheChars) chars"))
                        Button(String(localized: "Clear Translation Cache"), role: .destructive) {
                            BilingualReadingService.clearCache()
                            refreshCacheStats()
                        }
                    } label: {
                        Image(systemName: "externaldrive")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(String(localized: "Translation cache: \(cachePages) page(s), \(cacheChars) chars"))
                }
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
        .onAppear { refreshCacheStats() }
        .onChange(of: bilingual.doneCount) { _, _ in refreshCacheStats() }
    }

    private func refreshCacheStats() {
        let summary = BilingualReadingService.cacheSummary()
        cachePages = summary.pages
        cacheChars = summary.chars
    }

    /// 本轮翻译的可见账：缓存命中 / token / 按单价表折算的费用。
    private var usageLabel: String? {
        var parts: [String] = []
        if let name = bilingual.lastProfileName, !name.isEmpty {
            parts.append(name)
        }
        if bilingual.lastCacheHits > 0 {
            parts.append(String(localized: "\(bilingual.lastCacheHits) cached"))
        }
        let tokens = bilingual.lastPromptTokens + bilingual.lastCompletionTokens
        if tokens > 0 {
            parts.append("\(tokens) tok")
            if let model = bilingual.lastModel,
               let price = AppState.live?.aiPreference.usagePrice(for: model),
               let cost = price.cost(promptTokens: bilingual.lastPromptTokens,
                                     completionTokens: bilingual.lastCompletionTokens) {
                parts.append(cost < 0.0001 ? "< $0.0001" : String(format: "$%.4f", cost))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func displayName(for language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier else { return "" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
