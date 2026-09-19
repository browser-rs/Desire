import SwiftUI
import WebKit

/// 阅读器设置（0.3.7）：字号/主题/行距，UserDefaults 持久化。
struct ReaderSettings {
    var fontSize: Int = 18
    var theme: Theme = .auto
    var lineSpacing: Double = 1.7

    enum Theme: String, CaseIterable, Identifiable {
        case auto, light, sepia, dark
        var id: String { rawValue }
    }

    static func load() -> ReaderSettings {
        let d = UserDefaults.standard
        return ReaderSettings(
            fontSize: d.object(forKey: "reader.fontSize") as? Int ?? 18,
            theme: Theme(rawValue: d.string(forKey: "reader.theme") ?? "") ?? .auto,
            lineSpacing: d.object(forKey: "reader.lineSpacing") as? Double ?? 1.7
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(fontSize, forKey: "reader.fontSize")
        d.set(theme.rawValue, forKey: "reader.theme")
        d.set(lineSpacing, forKey: "reader.lineSpacing")
    }
}

struct ReaderView: View {
    let title: String
    let contentHTML: String
    let isLoading: Bool
    let onClose: () -> Void

    @State private var settings = ReaderSettings.load()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                Spacer()

                // 字号步进
                HStack(spacing: 4) {
                    Button { stepFont(-1) } label: {
                        Text("A").font(.system(size: 11))
                    }
                    Button { stepFont(1) } label: {
                        Text("A").font(.system(size: 15, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                // 行距切换（紧凑/标准/宽松）
                Menu {
                    ForEach([1.4, 1.7, 2.0], id: \.self) { spacing in
                        Button(spacing == 1.4 ? "Tight" : spacing == 1.7 ? "Normal" : "Loose") {
                            settings.lineSpacing = spacing
                            settings.save()
                        }
                    }
                } label: {
                    Image(systemName: "text.line.height")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)

                // 主题
                Menu {
                    ForEach(ReaderSettings.Theme.allCases) { theme in
                        Button(theme.rawValue.capitalized) {
                            settings.theme = theme
                            settings.save()
                        }
                    }
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(height: 16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if isLoading {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Extracting content…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No readable content found")
                        .font(.headline)
                    Text("This page may not have a readable article format.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ReaderWebView(html: wrappedHTML)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(settingsIdentity) // 设置变化重载（HTML 模板内联样式）
            }
        }
    }

    private var settingsIdentity: String {
        "\(settings.fontSize)-\(settings.theme.rawValue)-\(settings.lineSpacing)"
    }

    private func stepFont(_ delta: Int) {
        settings.fontSize = max(14, min(26, settings.fontSize + delta))
        settings.save()
    }

    private var wrappedHTML: String {
        let themeCSS: String
        switch settings.theme {
        case .auto:
            themeCSS = """
            body { color: #1a1a1a; background: transparent; }
            a { color: #007aff; }
            pre, code { background: #f5f5f5; }
            blockquote { color: #555; }
            @media (prefers-color-scheme: dark) {
                body { color: #e0e0e0; background: #1c1c1e; }
                a { color: #5ac8fa; }
                pre, code { background: #2c2c2e; }
                blockquote { color: #aaa; }
            }
            """
        case .light:
            themeCSS = "body { color: #1a1a1a; background: #ffffff; } a { color: #007aff; } pre, code { background: #f5f5f5; } blockquote { color: #555; }"
        case .sepia:
            themeCSS = "body { color: #4a4234; background: #f4ecd8; } a { color: #9a6b00; } pre, code { background: #e8dcc0; } blockquote { color: #7a6a52; }"
        case .dark:
            themeCSS = "body { color: #e0e0e0; background: #1c1c1e; } a { color: #5ac8fa; } pre, code { background: #2c2c2e; } blockquote { color: #aaa; }"
        }
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            body {
                font-family: -apple-system, Georgia, serif;
                font-size: \(settings.fontSize)px;
                line-height: \(settings.lineSpacing);
                padding: 20px 30px;
                max-width: 680px;
                margin: 0 auto;
            }
            h1 {
                font-family: -apple-system;
                font-size: \(settings.fontSize + 10)px;
                font-weight: 700;
                line-height: 1.2;
                margin-bottom: 0.5em;
            }
            p { margin: 1em 0; }
            img { max-width: 100%; height: auto; border-radius: 4px; }
            pre { overflow-x: auto; padding: 12px; border-radius: 6px; font-size: \(settings.fontSize - 4)px; }
            code { font-size: \(settings.fontSize - 4)px; padding: 2px 6px; border-radius: 3px; }
            blockquote { border-left: 3px solid #007aff; margin: 1em 0; padding: 0.5em 1em; }
            \(themeCSS)
        </style>
        </head>
        <body>
        <h1>\(title)</h1>
        \(contentHTML)
        </body>
        </html>
        """
    }
}

private struct ReaderWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.loadHTMLString(html, baseURL: nil)
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // 设置变化经 .id 重挂载，无需 update 处理。
    }
}

#Preview {
    ReaderView(title: "示例文章标题", contentHTML: "<p>这是阅读模式的内容预览。</p><p>第二段内容。</p>", isLoading: false, onClose: {})
        .frame(width: 600, height: 400)
}
