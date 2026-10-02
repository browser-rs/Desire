import Foundation

/// 插件包资源目录（2026-10-02）：装载 manifest 包（.msex / Safari 包 /
/// Load unpacked 目录）时把整个包目录拷进
/// `~/Library/Application Support/Desire/PluginResources/<uuid>/`。
/// 此后 chrome.scripting 的 files[] 动态注入与 runtime.getURL 从这里读——
/// 此前 jsCode 内联是唯一代码通道，动态注入没有文件可读。
///
/// 手写 JSON 插件没有包目录（resourcesPath = nil），files[] 明确报错。
/// Foundation-only：路径清洗进 tests/run.sh。
enum PluginResources {
    /// 包拷贝总量上限：超过即拒绝安装（防超大目录拖垮安装路径）。
    static let sizeCapBytes = 50 * 1024 * 1024

    static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Desire/PluginResources", isDirectory: true)
    }

    /// 相对路径清洗（纯函数）：拒绝绝对路径、`..` 逃逸、盘符/URL 形式与空段；
    /// 正常相对结构（`sub/dir/file.js`）原样保留。
    static func sanitizedRelativePath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("\\"),
              !trimmed.contains("//"), !trimmed.lowercased().hasPrefix("file:") else { return nil }
        let parts = trimmed.split(separator: "/").map(String.init)
        guard !parts.isEmpty,
              parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else { return nil }
        return parts.joined(separator: "/")
    }

    /// 包目录拷进资源区，返回目录名（即 `Plugin.resourcesPath`，持久化在
    /// Plugin 上）。同名重装沿用同一 uuid——先清旧目录再拷（= 更新语义）。
    static func importPackage(from sourceDir: URL, pluginID: UUID) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let target = baseDirectory.appendingPathComponent(pluginID.uuidString, isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        let bytes = try directorySize(sourceDir)
        guard bytes <= sizeCapBytes else {
            throw ResourcesError.tooLarge(bytes)
        }
        try fm.copyItem(at: sourceDir, to: target)
        return pluginID.uuidString
    }

    /// 插件卸载/更新前的清理。
    static func discard(_ resourcesPath: String?) {
        guard let resourcesPath, !resourcesPath.isEmpty else { return }
        let target = baseDirectory.appendingPathComponent(resourcesPath, isDirectory: true)
        try? FileManager.default.removeItem(at: target)
    }

    static func directory(for resourcesPath: String?) -> URL? {
        guard let resourcesPath, !resourcesPath.isEmpty else { return nil }
        let dir = baseDirectory.appendingPathComponent(resourcesPath, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return dir
    }

    /// 读资源文本文件（files[] 注入用）：路径先清洗，再确认解析结果确实
    /// 落在该插件资源目录**之内**（清洗 + 逐一构造，天然防逃逸）。
    static func readTextFile(resourcesPath: String?, relativePath: String) throws -> String {
        guard let clean = sanitizedRelativePath(relativePath) else {
            throw ResourcesError.badPath(relativePath)
        }
        guard let dir = directory(for: resourcesPath) else {
            throw ResourcesError.noResources
        }
        let fileURL = dir.appendingPathComponent(clean)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ResourcesError.missing(clean)
        }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw ResourcesError.notText(clean)
        }
        return text
    }

    private static func directorySize(_ dir: URL) throws -> Int {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total = 0
        for case let url as URL in en {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += size
            if total > sizeCapBytes { return total }
        }
        return total
    }

    enum ResourcesError: LocalizedError {
        case tooLarge(Int)
        case badPath(String)
        case noResources
        case missing(String)
        case notText(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                "Package exceeds the \(sizeCapBytes / 1024 / 1024) MB resources cap (\(bytes / 1024 / 1024) MB)"
            case .badPath(let raw):
                "Invalid plugin resource path: \(raw)"
            case .noResources:
                "Plugin has no package resources (hand-written plugins cannot use files[])"
            case .missing(let path):
                "Plugin resource not found: \(path)"
            case .notText(let path):
                "Plugin resource is not text: \(path)"
            }
        }
    }
}
