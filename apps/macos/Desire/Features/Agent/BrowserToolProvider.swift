import AppKit
import UniformTypeIdentifiers
import WebKit
import os

@MainActor
class BrowserToolProvider {
    /// The app-state slice the tools operate over. Weak: strongly retained
    /// by the owning `AgentSessionStore` (`toolSurface`), which configures it
    /// via `attach(surface:)`. Replaces the former 13 individual
    /// `weak var ...Store?` injections.
    weak var surface: BrowserToolSurface?
    weak var ownerSession: AgentSessionStore?

    /// Attaches the tool surface. Called from `AgentSessionStore.configure`.
    func attach(surface: BrowserToolSurface, owner: AgentSessionStore? = nil) {
        self.surface = surface
        self.ownerSession = owner
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
        // 键必须是合法 JS 标识符——否则对象字面量直接生成坏 JS（静默语法错）。
        let invalidKeys = args.keys.filter {
            $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil
        }
        guard invalidKeys.isEmpty else {
            return "Error: callAsync argument key(s) \(invalidKeys.sorted()) are not valid JS identifiers — fix the call site"
        }
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
            // 隔离世界的注入在极少数文档形态下会缺失（实机观测：reddit 风控局域页
            // 的一次会话里 __desireSnapshot 找不到；挂起恢复、document.write 重置
            // 均无法复现，机制未钉死）。就地热补种 dom-tools 再试一次——把
            // ReferenceError 变成透明自愈；仍失败则按原错误返回并附标记。
            let effectiveWorld = world ?? WebView.agentToolWorld
            if detail.contains("Can't find variable") && detail.contains("__desire"),
               effectiveWorld == WebView.agentToolWorld {
                Log.agent.info("dom-tools helpers missing on \(wv.url?.absoluteString ?? "?", privacy: .public) — re-injecting on demand")
                let source = UserScriptLoader.load("dom-tools")
                _ = try? await wv.callAsyncJavaScript(source + "\nreturn true;",
                                                      arguments: [:], in: nil, contentWorld: effectiveWorld)
                let retried: Any?
                do {
                    retried = try await wv.callAsyncJavaScript(body, arguments: args, in: nil,
                                                               contentWorld: effectiveWorld)
                } catch {
                    return "Error: \(detail) [after dom-tools re-injection]"
                }
                if let s = retried as? String { return s }
                if let n = retried as? NSNumber { return n.stringValue }
                if retried != nil { return "\(retried!)" }
                return ""
            }
            return "Error: \(detail)"
        }
    }

    /// Captures the viewport and returns a data-URI (`data:image/jpeg;base64,…`)
    /// sized for vision-model consumption (max 1024px wide, JPEG q80 — a full
    /// PNG would be 1–2 MB and blow the token budget; JPEG at this size is
    /// ~100–200 KB, enough for layout understanding).
    ///
    /// 坐标自描述（v0.8.56 批 1）：缩放系数与 viewport 尺寸烧进图内底部
    /// caption——模型读图即知换算，宽窗口（>1024 CSS px）的 clickAt 不再漂移。
    func captureScreenshot(_ wv: WKWebView) async -> String {
        await withCheckedContinuation { continuation in
            wv.takeSnapshot(with: nil) { image, error in
                guard let image, error == nil else {
                    continuation.resume(returning: "")
                    return
                }
                let note = ScreenshotScaleNote.note(
                    viewportWidth: Double(image.size.width),
                    viewportHeight: Double(image.size.height))
                let targetW = note.targetWidth
                let targetH = note.targetHeight
                let captionH = CGFloat(ScreenshotScaleNote.captionHeight)
                guard targetW > 0, targetH > 0,
                      let rep = NSBitmapImageRep(
                          bitmapDataPlanes: nil, pixelsWide: targetW,
                          pixelsHigh: targetH + ScreenshotScaleNote.captionHeight,
                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                          isPlanar: false, colorSpaceName: .calibratedRGB,
                          bytesPerRow: 0, bitsPerPixel: 0
                      ) else {
                    continuation.resume(returning: "")
                    return
                }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                // NSGraphicsContext 坐标系原点在左下：内容画在上部，caption 贴底。
                image.draw(in: NSRect(x: 0, y: captionH,
                                      width: CGFloat(targetW), height: CGFloat(targetH)))
                NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 0.92).setFill()
                NSBezierPath(rect: NSRect(x: 0, y: 0,
                                          width: CGFloat(targetW), height: captionH)).fill()
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1),
                    .paragraphStyle: paragraph,
                ]
                let line = note.caption as NSString
                let textSize = line.size(withAttributes: attributes)
                line.draw(at: NSPoint(x: (CGFloat(targetW) - textSize.width) / 2,
                                      y: (captionH - textSize.height) / 2),
                          withAttributes: attributes)
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
