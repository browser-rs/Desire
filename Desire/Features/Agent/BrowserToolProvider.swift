import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
class BrowserToolProvider {
    /// The app-state slice the tools operate over. Weak: strongly retained
    /// by the owning `AgentSessionStore` (`toolSurface`), which configures it
    /// via `attach(surface:)`. Replaces the former 13 individual
    /// `weak var ...Store?` injections.
    weak var surface: BrowserToolSurface?

    /// Attaches the tool surface. Called from `AgentSessionStore.configure`.
    func attach(surface: BrowserToolSurface) {
        self.surface = surface
    }


    // MARK: - Helpers

    func isNewTabPage(_ url: String) -> Bool {
        url.isEmpty || url == "about:blank" || url.hasPrefix("desire://newtab")
    }

    func eval(_ wv: WKWebView, _ js: String) async -> String {
        // 隔离世界求值（页面猴补不了这里）；间接 eval 承接任意形态（表达式/
        // 语句/带尾分号的 IIFE），完成值经 return 带出——callAsyncJavaScript
        // 是唯一回传完成值的跨世界 API（evaluateJavaScript 的 in:in: 重载不回
        // 值，探针实测）。
        do {
            let result = try await wv.callAsyncJavaScript(
                "return eval(\(JSString.literal(js)));",
                arguments: [:], in: nil, contentWorld: WebView.agentToolWorld
            )
            if let s = result as? String { return s }
            if let n = result as? NSNumber { return n.stringValue }
            if result != nil { return "\(result!)" }
            return ""
        } catch {
            // The localized description is a useless generic ("A JavaScript
            // exception occurred") — surface the actual exception message.
            let ns = error as NSError
            let detail = ns.userInfo["WKJavaScriptExceptionMessage"] as? String
                ?? ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String
                ?? ns.userInfo[NSDebugDescriptionErrorKey] as? String
                ?? error.localizedDescription
            return "Error: \(detail)"
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
    func callAsync(_ wv: WKWebView, function: String, args: [String: Any], world: WKContentWorld? = nil) async -> String {
        // callAsyncJavaScript runs `functionBody` as an async closure with
        // `args` injected as named JS consts. We await the injected function.
        // 默认隔离世界（页面覆盖不到）；依赖页面世界状态的两个网络函数由
        // 调用点显式传 .page。
        // **按键对象传参**：args 键按字母序作位置实参曾是错位源（形参顺序
        // ≠ 字母序的函数全部中招——__desireSnapshot 加 ignoreSels 后炸出；
        // __desireClick 的 ref/text 形态靠 resolveEl 兜底掩盖多年）。对象
        // 字面量按键传，与形参顺序无关；dom-tools 宿主直调函数一律解构形参。
        let namedArgs = args.keys.map { "\($0): \($0)" }.sorted().joined(separator: ", ")
        let body = "return await \(function)({ \(namedArgs) });"
        do {
            let result = try await wv.callAsyncJavaScript(body, arguments: args, in: nil,
                                                          contentWorld: world ?? WebView.agentToolWorld)
            if let s = result as? String { return s }
            if let n = result as? NSNumber { return n.stringValue }
            if result != nil { return "\(result!)" }
            return ""
        } catch {
            // localizedDescription 是无信息量的通用文案——带出真实异常文本
            let ns = error as NSError
            let detail = ns.userInfo["WKJavaScriptExceptionMessage"] as? String
                ?? ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String
                ?? error.localizedDescription
            return "Error: \(detail)"
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
