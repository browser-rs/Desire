import Foundation
import os

/// .msex 安装器（0.3.3）：Chrome manifest v3 的忠实子集。包结构 =
/// zip（扩展名 .msex），根目录 manifest.json + 资源文件。
///
/// 解析的字段：name / version / description / content_scripts[]
/// {matches, js[], css[], run_at} / action.default_popup。
/// js/css 文件内容**内联进 Plugin**（jsCode/cssCode）——Desire 的插件
/// 模型没有"包目录"概念，内联让单个 Plugin 即自足。popup 同理存 HTML
/// 字符串。
@MainActor
enum MSExInstaller {
    struct InstallResult {
        let plugin: Plugin
    }

    /// 解包 + 解析 + 构造 Plugin。失败抛可读错误（桥/面板直接展示）。
    static func install(from packageURL: URL, store: PluginStore) throws -> InstallResult {
        let fm = FileManager.default
        let extractDir = fm.temporaryDirectory
            .appendingPathComponent("msex-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extractDir) }

        // ditto 通吃 zip（macOS 自带，保留权限）。沙盒已移除，可跑。
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", packageURL.path, extractDir.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw MSExError.unpack(err.suffix(200).description)
        }

        return try installManifestedPackage(at: extractDir, store: store)
    }

    /// **Safari 扩展包**装载（双系统归一，2026-09-28）：`.safariextension` 目录 /
    /// 任意含 manifest.json 的目录 / zip(crx/xpi) 均可——content_scripts 形状与
    /// Chrome MV3 相同，共享同一条解析管线。background 脚本无对应概念，忽略
    /// （在描述里注明）。
    static func installSafariPackage(from url: URL, store: PluginStore) throws -> InstallResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw MSExError.noManifest
        }

        if isDir.boolValue {
            return try installManifestedPackage(at: url, store: store)
        }
        // zip/crx/xpi 文件 → 解包后同管线
        return try install(from: url, store: store)
    }

    /// 从**已就位的包目录**解析 manifest 并构造 Plugin（zip 与目录两路共用）。
    private static func installManifestedPackage(at dir: URL, store: PluginStore) throws -> InstallResult {
        let extractDir = dir
        let manifestURL = extractDir.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw MSExError.noManifest
        }

        guard let name = manifest["name"] as? String, !name.isEmpty else {
            throw MSExError.noName
        }
        let version = manifest["version"] as? String ?? "1.0"
        let description = manifest["description"] as? String ?? ""

        // content_scripts 合并（多脚本块少见但合法）。
        var matches: [String] = []
        var jsChunks: [String] = []
        var cssChunks: [String] = []
        var runAt = RunAt.documentEnd
        if let scripts = manifest["content_scripts"] as? [[String: Any]] {
            for script in scripts {
                if let m = script["matches"] as? [String] { matches += m }
                if let js = script["js"] as? [String] {
                    for file in js {
                        if let src = try? String(contentsOf: extractDir.appendingPathComponent(file), encoding: .utf8) {
                            jsChunks.append(src)
                        }
                    }
                }
                if let css = script["css"] as? [String] {
                    for file in css {
                        if let src = try? String(contentsOf: extractDir.appendingPathComponent(file), encoding: .utf8) {
                            cssChunks.append(src)
                        }
                    }
                }
                if let ra = script["run_at"] as? String, let parsed = RunAt(rawValue: ra) {
                    runAt = parsed
                }
            }
        }

        // action.default_popup（mv3 在 action，v2 在 browser_action——都认）。
        var popupHTML: String?
        var popupBaseDir: URL?
        if let action = manifest["action"] as? [String: Any],
           let popupPath = action["default_popup"] as? String {
            let popupURL = extractDir.appendingPathComponent(popupPath)
            popupHTML = try? String(contentsOf: popupURL, encoding: .utf8)
            popupBaseDir = popupURL.deletingLastPathComponent()
        } else if let action = manifest["browser_action"] as? [String: Any],
                  let popupPath = action["default_popup"] as? String {
            let popupURL = extractDir.appendingPathComponent(popupPath)
            popupHTML = try? String(contentsOf: popupURL, encoding: .utf8)
            popupBaseDir = popupURL.deletingLastPathComponent()
        }

        guard !jsChunks.isEmpty || !cssChunks.isEmpty || popupHTML != nil else {
            throw MSExError.noContent
        }

        // R2 归一后续（Chrome 式从文件加载）：真实扩展的 popup 都引用外部
        // css/js（如 trove-bookmark 的 ../lib/qrcode.min.js）——相对引用内联
        // 进 HTML，否则 popup 弹出来是断链的白壳。基准目录 = **popup.html 所在
        // 目录**（引用相对它解析，`../` 跳包根），不是 manifest 根。
        popupHTML = popupBaseDir.flatMap { dir in
            popupHTML.map { Self.inlinePopupResources(html: $0, baseDir: dir) }
        }
        // background（service_worker/scripts）内联——由
        // PluginBackgroundRuntime 以常驻 headless webview 运行
        //（contextMenus/storage/notifications/事件都可用）。
        var backgroundCode: String?
        if let background = manifest["background"] as? [String: Any] {
            if let serviceWorker = background["service_worker"] as? String {
                backgroundCode = try? String(contentsOf: extractDir.appendingPathComponent(serviceWorker), encoding: .utf8)
            } else if let scripts = background["scripts"] as? [String] {
                backgroundCode = scripts.compactMap {
                    try? String(contentsOf: extractDir.appendingPathComponent($0), encoding: .utf8)
                }.joined(separator: "\n")
            }
        }
        let effectiveDescription = description

        // 真实图标：manifest icons{} 里最大的尺寸 → PNG 数据（工具栏渲染用；
        // 插件模型无图片文件概念，数据随 Plugin 持久化）。
        let iconPNG = Self.largestIconPNG(manifest: manifest, extractDir: extractDir)

        // popup 文档 origin：host_permissions 第一个 https/http 条目去路径。
        // Chrome 扩展页面凭 host_permissions 跨域 fetch；Desire 的 popup 用它
        // 作 loadHTMLString 的 baseURL，让 API 调用变同源（否则被 CORS 拦截，
        // 实测 trove-bookmark"登录失败: Load failed"）。
        var popupBaseOrigin: String?
        if let perms = manifest["host_permissions"] as? [String] {
            let candidate = perms.first { $0.hasPrefix("https://") } ?? perms.first { $0.hasPrefix("http://") }
            if let candidate, let url = URL(string: candidate.replacingOccurrences(of: "/*", with: "/")),
               let host = url.host {
                popupBaseOrigin = "\(url.scheme ?? "https")://\(host)\(url.port.map { ":\($0)" } ?? "")"
            }
        }

        let plugin = Plugin(
            name: name,
            description: effectiveDescription,
            version: version,
            urlPatterns: matches.isEmpty ? ["*"] : matches,
            runAt: runAt,
            jsCode: jsChunks.joined(separator: "\n;\n"),
            cssCode: cssChunks.joined(separator: "\n"),
            icon: "puzzlepiece",
            popupHTML: popupHTML,
            iconPNG: iconPNG,
            popupBaseOrigin: popupBaseOrigin,
            backgroundCode: backgroundCode
        )
        // 同名重装 = 更新（替换旧条目；沿用旧 id —— storage 按 id
        // 命名空间，换 id 会孤儿化已存数据）。
        var resultPlugin = plugin
        if let existing = store.plugins.first(where: { $0.name == name }) {
            // 包资源目录随 uuid 复用——importPackage 先清旧再拷（= 更新）。
            let resourcesPath = try? PluginResources.importPackage(
                from: extractDir, pluginID: existing.id)
            let updated = Plugin(
                id: existing.id, name: plugin.name, description: plugin.description,
                version: plugin.version, author: plugin.author,
                urlPatterns: plugin.urlPatterns, excludePatterns: plugin.excludePatterns,
                runAt: plugin.runAt, jsCode: plugin.jsCode, cssCode: plugin.cssCode,
                isEnabled: existing.isEnabled, createdAt: existing.createdAt,
                pinned: existing.pinned, icon: plugin.icon, popupHTML: plugin.popupHTML,
                iconPNG: iconPNG ?? existing.iconPNG,
                popupBaseOrigin: popupBaseOrigin ?? existing.popupBaseOrigin,
                backgroundCode: backgroundCode ?? existing.backgroundCode,
                resourcesPath: resourcesPath ?? existing.resourcesPath)
            store.update(updated)
            resultPlugin = updated
        } else {
            var newPlugin = plugin
            // 包目录整包拷入资源区：chrome.scripting files[] / runtime.getURL
            // 的文件来源（拷贝失败不拦安装——内联 jsCode 已可用，files[] 再报错）。
            newPlugin.resourcesPath = try? PluginResources.importPackage(
                from: extractDir, pluginID: plugin.id)
            store.add(newPlugin)
            resultPlugin = newPlugin
        }
        Log.userScripts.info("msex installed: \(name, privacy: .public) v\(version, privacy: .public)")
        // **返回实际入库的插件**（更新分支 id = 旧条目）——此前返回新构造
        // 对象，同名重装时桥/调用方拿到的是从未入库的 id（实测 E2E 探针
        // 全打空）。
        return InstallResult(plugin: resultPlugin)
    }

    // MARK: - 图标

    /// manifest icons{} 里最大的尺寸 → PNG 数据。解析失败静默返回 nil
    ///（工具栏回退 SF Symbol）。
    private static func largestIconPNG(manifest: [String: Any], extractDir: URL) -> Data? {
        guard let icons = manifest["icons"] as? [String: String], !icons.isEmpty else { return nil }
        let best = icons
            .compactMap { (size, path) -> (Int, String)? in
                guard let n = Int(size) else { return nil }
                return (n, path)
            }
            .max(by: { $0.0 < $1.0 })?
            .1
        guard let best else { return nil }
        return try? Data(contentsOf: extractDir.appendingPathComponent(best))
    }

    // MARK: - popup 资源内联

    /// 把 popup HTML 里的相对引用资源内联：`<link rel=stylesheet href>` →
    /// `<style>`、`<script src>` → `<script>`。路径相对 popup HTML 所在目录
    /// 解析（`../` 自然支持）；绝对 http(s)/data 引用保持原样（无法内联）。
    /// 最多 3 轮——内联内容自身再引用更深资源极少见，封顶防失控。
    ///
    /// regex 用**原始字符串**（`#"..."#`）——普通字符串里 `\\b`/`\\s` 的双重
    /// 转义是这段代码第一次落盘就坏掉的直接原因。
    static func inlinePopupResources(html: String, baseDir: URL) -> String {
        var out = html
        for _ in 0..<3 {
            var changed = false

            // <script src="X"></script>（属性顺序：src 可能不在最后，按 tag 抓）
            let scriptRegex = try? NSRegularExpression(
                pattern: #"<script\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>\s*</script>"#,
                options: [.caseInsensitive])
            if let scriptRegex {
                var result = ""
                var last = out.startIndex
                let ns = out as NSString
                scriptRegex.enumerateMatches(in: out, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                    guard let match, let range = Range(match.range, in: out),
                          let srcRange = Range(match.range(at: 1), in: out) else { return }
                    let src = String(out[srcRange])
                    if src.lowercased().hasPrefix("http://") || src.lowercased().hasPrefix("https://")
                        || src.lowercased().hasPrefix("data:") {
                        return // 保持原样
                    }
                    let fileURL = baseDir.appendingPathComponent(src)
                    guard let code = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
                    // 内联的 JS 里若含 </script> 会截断 HTML——转义
                    let safe = code.replacingOccurrences(of: "</script", with: #"<\/script"#)
                    result += out[last..<range.lowerBound]
                    result += "<script>\(safe)</script>"
                    last = range.upperBound
                    changed = true
                }
                result += out[last...]
                out = result
            }

            // <link ... rel="stylesheet" ... href="X">（属性顺序不定，按 tag 解析）
            let linkRegex = try? NSRegularExpression(
                pattern: #"<link\b[^>]*>"#,
                options: [.caseInsensitive])
            if let linkRegex {
                var result = ""
                var last = out.startIndex
                let ns = out as NSString
                linkRegex.enumerateMatches(in: out, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                    guard let match, let range = Range(match.range, in: out) else { return }
                    let tag = String(out[range])
                    guard tag.lowercased().contains("stylesheet"),
                          let href = Self.attribute("href", from: tag),
                          !href.lowercased().hasPrefix("http://"),
                          !href.lowercased().hasPrefix("https://"),
                          !href.lowercased().hasPrefix("data:") else { return }
                    let fileURL = baseDir.appendingPathComponent(href)
                    guard let css = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
                    result += out[last..<range.lowerBound]
                    result += "<style>\(css)</style>"
                    last = range.upperBound
                    changed = true
                }
                result += out[last...]
                out = result
            }

            if !changed { break }
        }
        return out
    }

    /// 从 HTML 标签文本里取属性值（双/单引号皆可）。
    private static func attribute(_ name: String, from tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"\#(name)\s*=\s*["']?([^"' >]+)"#,
            options: [.caseInsensitive]) else { return nil }
        let ns = tag as NSString
        // 捕获组只有 1 个（\#(name) 是字面插值不是组）——读 range(at: 2) 会
        // NSException（harness 对真实扩展首跑即崩，已实证）。
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
              match.range(at: 1).location != NSNotFound,
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }

    enum MSExError: LocalizedError {
        case unpack(String)
        case noManifest
        case noName
        case noContent

        var errorDescription: String? {
            switch self {
            case .unpack(let detail): "Couldn't unpack .msex: \(detail)"
            case .noManifest: "manifest.json missing at package root"
            case .noName: "manifest.name missing"
            case .noContent: "No content scripts, css, or popup in the package"
            }
        }
    }
}
