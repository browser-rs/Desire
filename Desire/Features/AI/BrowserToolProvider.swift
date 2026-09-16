import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
class BrowserToolProvider {
    /// The app-state slice the tools operate over. Weak: strongly retained
    /// by the owning `AISessionStore` (`toolSurface`), which configures it
    /// via `attach(surface:)`. Replaces the former 13 individual
    /// `weak var ...Store?` injections.
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

    /// Captures the viewport and returns a data-URI (`data:image/jpeg;base64,…`)
    /// sized for vision-model consumption (max 1024px wide, JPEG q80 — a full
    /// PNG would be 1–2 MB and blow the token budget; JPEG at this size is
    /// ~100–200 KB, enough for layout understanding).
    func captureScreenshot(_ wv: WKWebView) async -> String {
        await withCheckedContinuation { continuation in
            wv.takeSnapshot(with: nil) { image, error in
                guard let image, error == nil else {
                    continuation.resume(returning: "")
                    return
                }
                // Resize off-main: draw into a constrained bitmap.
                let maxDim: CGFloat = 1024
                let px = image.size
                let scale = min(1, maxDim / max(px.width, px.height))
                let targetW = Int(px.width * scale)
                let targetH = Int(px.height * scale)
                guard targetW > 0, targetH > 0,
                      let rep = NSBitmapImageRep(
                          bitmapDataPlanes: nil, pixelsWide: targetW, pixelsHigh: targetH,
                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                          isPlanar: false, colorSpaceName: .calibratedRGB,
                          bytesPerRow: 0, bitsPerPixel: 0
                      ) else {
                    continuation.resume(returning: "")
                    return
                }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(x: 0, y: 0, width: targetW, height: targetH))
                NSGraphicsContext.restoreGraphicsState()
                let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
                if let jpegData = jpeg {
                    continuation.resume(returning: "data:image/jpeg;base64," + jpegData.base64EncodedString())
                } else {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}
