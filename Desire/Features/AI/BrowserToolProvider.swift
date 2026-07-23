import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
class BrowserToolProvider {
    /// The app-state slice the tools operate over. Weak: owned by the app
    /// (AppState conforms). Set once per window via `attach(surface:)`.
    /// Replaces the former 13 individual `weak var ...Store?` injections.
    weak var surface: BrowserToolSurface?

    /// Attaches the tool surface. Called from `AISessionStore.configure`.
    func attach(surface: BrowserToolSurface) {
        self.surface = surface
    }


    // MARK: - Helpers

    func isNewTabPage(_ url: String) -> Bool {
        url.isEmpty || url == "about:blank" || url.hasPrefix("desire://newtab")
    }

    func eval(_ wv: WKWebView, _ js: String) async -> String {
        await withCheckedContinuation { continuation in
            wv.evaluateJavaScript(js) { result, error in
                if let error = error {
                    continuation.resume(returning: "Error: \(error.localizedDescription)")
                } else if let result = result as? String {
                    continuation.resume(returning: result)
                } else if let result = result {
                    continuation.resume(returning: "\(result)")
                } else {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    /// Invokes a pre-injected page-world function (defined in
    /// `UserScripts/dom-tools.js`) via `callAsyncJavaScript`. Parameters are
    /// passed as native typed values — NO string interpolation, NO escaping —
    /// so model-controlled selectors/values cannot break out into code.
    ///
    /// `function` is the JS function name (e.g. `__desireClick`); `args` keys
    /// must match the function's parameter names. Returns a status string
    /// shaped like `eval` so call sites stay unchanged.
    func callAsync(_ wv: WKWebView, function: String, args: [String: Any]) async -> String {
        // callAsyncJavaScript runs `functionBody` as an async closure with
        // `args` injected as named JS consts. We await the page function.
        let paramList = args.keys.sorted().joined(separator: ",")
        let body = "return await \(function)(\(paramList))"
        do {
            let result = try await wv.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
            if let s = result as? String { return s }
            if let n = result as? NSNumber { return n.stringValue }
            if result != nil { return "\(result!)" }
            return ""
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    func captureScreenshot(_ wv: WKWebView) async -> String {
        await withCheckedContinuation { continuation in
            wv.takeSnapshot(with: nil) { image, error in
                if let error = error {
                    continuation.resume(returning: "Error: \(error.localizedDescription)")
                } else if let image = image,
                          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let bitmap = NSBitmapImageRep(cgImage: cgImage)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        let b64 = png.base64EncodedString()
                        continuation.resume(returning: b64)
                    } else {
                        continuation.resume(returning: "Error: PNG encoding failed")
                    }
                } else {
                    continuation.resume(returning: "Error: failed to capture screenshot")
                }
            }
        }
    }
}
