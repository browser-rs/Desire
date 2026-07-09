import AppKit
import Foundation
import UniformTypeIdentifiers

/// Safari Web Extension 导入器
/// 支持 .safariextension、.crx、.xpi、.zip 等格式
@MainActor
class SafariExtensionImporter {

    enum ImportError: LocalizedError {
        case fileNotFound
        case invalidFormat
        case manifestNotFound
        case manifestParseFailed(String)
        case unsupportedManifestVersion(Int)
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .fileNotFound: return "Extension file not found"
            case .invalidFormat: return "Invalid extension package format"
            case .manifestNotFound: return "manifest.json not found in extension package"
            case .manifestParseFailed(let msg): return "Failed to parse manifest.json: \(msg)"
            case .unsupportedManifestVersion(let v): return "Unsupported manifest version: \(v)"
            case .permissionDenied: return "Permission denied to access extension"
            }
        }
    }

    /// 从文件导入扩展
    static func importExtension(from url: URL) throws -> SafariExtension {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.fileNotFound
        }

        let ext = url.pathExtension.lowercased()
        let bundleURL: URL

        switch ext {
        case "safariextension":
            // Safari 扩展目录
            bundleURL = url
        case "crx", "xpi", "zip":
            // Chrome/Firefox 扩展包，需要解压
            bundleURL = try unpackArchive(at: url)
        default:
            // 尝试作为目录或 ZIP
            if url.hasDirectoryPath {
                bundleURL = url
            } else {
                bundleURL = try unpackArchive(at: url)
            }
        }

        return try loadExtension(from: bundleURL)
    }

    /// 解压扩展包
    private static func unpackArchive(at url: URL) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesireExtensions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // 使用 unzip 命令（macOS 自带）
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", url.path, "-d", tempDir.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ImportError.invalidFormat
        }

        return tempDir
    }

    /// 从目录加载扩展
    private static func loadExtension(from bundleURL: URL) throws -> SafariExtension {
        // 1. 查找 manifest.json
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ImportError.manifestNotFound
        }

        // 2. 解析 manifest.json
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            throw ImportError.manifestParseFailed(error.localizedDescription)
        }

        let manifest: ExtensionManifest
        do {
            let decoder = JSONDecoder()
            manifest = try decoder.decode(ExtensionManifest.self, from: manifestData)
        } catch {
            throw ImportError.manifestParseFailed(error.localizedDescription)
        }

        // 3. 验证 manifest version
        guard manifest.manifest_version == 2 || manifest.manifest_version == 3 else {
            throw ImportError.unsupportedManifestVersion(manifest.manifest_version)
        }

        // 4. 创建 SafariExtension
        let extension_ = SafariExtension(
            manifest: manifest,
            bundleURL: bundleURL
        )

        return extension_
    }

    /// 从用户选择导入
    static func importFromUserChoice() async throws -> SafariExtension? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .safariExtension,
            .zip,
            UTType(filenameExtension: "crx") ?? .data,
            UTType(filenameExtension: "xpi") ?? .data
        ]
        panel.message = "Select a Safari Web Extension package"

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        return try importExtension(from: url)
    }

    /// 加载扩展图标
    static func loadIcon(for extension_: SafariExtension, preferredSize: Int = 128) -> NSImage? {
        guard let icons = extension_.manifest.icons else { return nil }

        // 找到最接近的尺寸
        let sizes = icons.keys.compactMap { Int($0) }.sorted()
        let bestSize = sizes.min(by: { abs($0 - preferredSize) < abs($1 - preferredSize) }) ?? sizes.first
        guard let size = bestSize, let iconPath = icons[String(size)] else { return nil }

        guard let bundleURL = extension_.bundleURL else { return nil }
        let iconURL = bundleURL.appendingPathComponent(iconPath)

        guard let image = NSImage(contentsOf: iconURL) else { return nil }
        return image
    }

    /// 加载扩展资源文件内容
    static func loadResource(for extension_: SafariExtension, path: String) -> Data? {
        guard let bundleURL = extension_.bundleURL else { return nil }
        let resourceURL = bundleURL.appendingPathComponent(path)
        return try? Data(contentsOf: resourceURL)
    }

    /// 加载 Content Script
    static func loadContentScript(for extension_: SafariExtension) throws -> (js: [String], css: [String]) {
        guard let bundleURL = extension_.bundleURL else { return ([], []) }

        var js: [String] = []
        var css: [String] = []

        guard let contentScripts = extension_.manifest.content_scripts else {
            return (js, css)
        }

        for script in contentScripts {
            // 加载 JS
            if let jsFiles = script.js {
                for jsFile in jsFiles {
                    let jsURL = bundleURL.appendingPathComponent(jsFile)
                    if let jsData = try? Data(contentsOf: jsURL),
                       let jsCode = String(data: jsData, encoding: .utf8) {
                        js.append(jsCode)
                    }
                }
            }

            // 加载 CSS
            if let cssFiles = script.css {
                for cssFile in cssFiles {
                    let cssURL = bundleURL.appendingPathComponent(cssFile)
                    if let cssData = try? Data(contentsOf: cssURL),
                       let cssCode = String(data: cssData, encoding: .utf8) {
                        css.append(cssCode)
                    }
                }
            }
        }

        return (js, css)
    }

    /// 加载 Background Script
    static func loadBackgroundScript(for extension_: SafariExtension) throws -> String? {
        guard let bundleURL = extension_.bundleURL,
              let background = extension_.manifest.background else { return nil }

        // V3: Service Worker
        if let serviceWorker = background.service_worker {
            let swURL = bundleURL.appendingPathComponent(serviceWorker)
            return try? String(contentsOf: swURL, encoding: .utf8)
        }

        // V2: Background scripts
        if let scripts = background.scripts, !scripts.isEmpty {
            var combined = ""
            for script in scripts {
                let scriptURL = bundleURL.appendingPathComponent(script)
                if let code = try? String(contentsOf: scriptURL, encoding: .utf8) {
                    combined += code + "\n"
                }
            }
            return combined.isEmpty ? nil : combined
        }

        return nil
    }
}

// MARK: - UTType Extension

extension UTType {
    static let safariExtension = UTType(
        exportedAs: "com.apple.safari.extension",
        conformingTo: .package
    )
}