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
        if let action = manifest["action"] as? [String: Any],
           let popupPath = action["default_popup"] as? String {
            popupHTML = try? String(contentsOf: extractDir.appendingPathComponent(popupPath), encoding: .utf8)
        } else if let action = manifest["browser_action"] as? [String: Any],
                  let popupPath = action["default_popup"] as? String {
            popupHTML = try? String(contentsOf: extractDir.appendingPathComponent(popupPath), encoding: .utf8)
        }

        guard !jsChunks.isEmpty || !cssChunks.isEmpty || popupHTML != nil else {
            throw MSExError.noContent
        }

        let plugin = Plugin(
            name: name,
            description: description,
            version: version,
            urlPatterns: matches.isEmpty ? ["*"] : matches,
            runAt: runAt,
            jsCode: jsChunks.joined(separator: "\n;\n"),
            cssCode: cssChunks.joined(separator: "\n"),
            icon: "puzzlepiece",
            popupHTML: popupHTML
        )
        // 同名重装 = 更新（替换旧条目；沿用旧 id —— storage 按 id
        // 命名空间，换 id 会孤儿化已存数据）。
        if let existing = store.plugins.first(where: { $0.name == name }) {
            let updated = Plugin(
                id: existing.id, name: plugin.name, description: plugin.description,
                version: plugin.version, author: plugin.author,
                urlPatterns: plugin.urlPatterns, excludePatterns: plugin.excludePatterns,
                runAt: plugin.runAt, jsCode: plugin.jsCode, cssCode: plugin.cssCode,
                isEnabled: existing.isEnabled, createdAt: existing.createdAt,
                pinned: existing.pinned, icon: plugin.icon, popupHTML: plugin.popupHTML)
            store.update(updated)
        } else {
            store.add(plugin)
        }
        Log.userScripts.info("msex installed: \(name, privacy: .public) v\(version, privacy: .public)")
        return InstallResult(plugin: plugin)
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
