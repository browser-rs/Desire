import SwiftUI
import WebKit

struct ReaderView: View {
    let title: String
    let contentHTML: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("返回")
                    }
                    .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ReaderWebView(html: wrappedHTML)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var wrappedHTML: String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            body {
                font-family: -apple-system, Georgia, serif;
                font-size: 18px;
                line-height: 1.7;
                color: #1a1a1a;
                padding: 20px 30px;
                max-width: 680px;
                margin: 0 auto;
            }
            h1 {
                font-family: -apple-system;
                font-size: 28px;
                font-weight: 700;
                line-height: 1.2;
                margin-bottom: 0.5em;
            }
            p { margin: 1em 0; }
            img { max-width: 100%; height: auto; border-radius: 4px; }
            a { color: #007aff; }
            pre { overflow-x: auto; background: #f5f5f5; padding: 12px; border-radius: 6px; font-size: 14px; }
            code { font-size: 14px; background: #f5f5f5; padding: 2px 6px; border-radius: 3px; }
            blockquote { border-left: 3px solid #007aff; margin: 1em 0; padding: 0.5em 1em; color: #555; }
            @media (prefers-color-scheme: dark) {
                body { color: #e0e0e0; background: #1c1c1e; }
                a { color: #5ac8fa; }
                pre, code { background: #2c2c2e; }
                blockquote { color: #aaa; }
            }
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

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
