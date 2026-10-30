import Foundation

/// 压缩包探查/解压（v0.8.12 旗舰 C，7+8）：系统 `/usr/bin/ditto` 与
/// `/usr/bin/unzip`，零第三方依赖。纯逻辑部分（条目行解析）进 harness。
nonisolated enum ArchiveKit {

    struct Entry: Equatable {
        /// 压缩包内相对路径（含目录前缀）。
        let path: String
        let sizeBytes: Int64
        let isDirectory: Bool
    }

    /// 解压到目标目录（ditto -x -k；中文文件名/嵌套由 ditto 处理）。
    /// 目标目录不存在会创建；返回 (文件数, 总字节) 供回执。
    static func extract(archiveURL: URL, to destination: URL) throws -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destination.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "ArchiveKit", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(message.suffix(300))])
        }
        // 统计解出的内容
        var files = 0
        var bytes: Int64 = 0
        if let enumerator = fm.enumerator(at: destination, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true {
                    files += 1
                    bytes += Int64(values?.fileSize ?? 0)
                }
            }
        }
        return (files, bytes)
    }

    /// 只解压指定条目（v0.8.26 办公增强：查看器"解压所选"）。
    /// 用 unzip -o -q（ditto 没有按条目选择的形态）；目录条目会连同内容一起解出。
    static func extract(archiveURL: URL, to destination: URL,
                        entries: [String]) throws -> (files: Int, bytes: Int64) {
        guard !entries.isEmpty else { return (0, 0) }
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", archiveURL.path, "-d", destination.path] + entries
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
            throw NSError(domain: "ArchiveKit", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: String(message.suffix(300))])
        }
        let listed = list(archiveURL: archiveURL) ?? []
        let wanted = Set(entries)
        let bytes = listed
            .filter { wanted.contains($0.path) && !$0.isDirectory }
            .reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) }
        let files = entries.filter { !$0.hasSuffix("/") }.count
        return (files, bytes)
    }

    /// 条目清单（unzip -l 解析；非 zip 或工具缺失返回 nil）。
    static func list(archiveURL: URL) -> [Entry]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", archiveURL.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parseListing(text)
    }

    /// 解析 `unzip -l` 输出：每行 "  length  date  time  name"。
    nonisolated static func parseListing(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        for line in text.split(separator: "\n") {
            // 数据行形如： "     1234  2026-01-02 03:04   path/to/file"
            let trimmed = line.drop(while: { $0 == " " })
            guard let sizeEnd = trimmed.firstIndex(of: " ") else { continue }
            guard let size = Int64(trimmed[..<sizeEnd]) else { continue }
            let rest = trimmed[sizeEnd...].drop(while: { $0 == " " })
            // 时间段后两个空格分隔，找名字：跳过 "date time " 前缀（两次空格切分）。
            // unzip -l 数据行：size date time name——三个空格字段之后是名字。
            var nameStart = rest.startIndex
            var spacesSeen = 0
            while nameStart < rest.endIndex, spacesSeen < 3 {
                if rest[nameStart] == " " { spacesSeen += 1 }
                nameStart = rest.index(after: nameStart)
            }
            guard spacesSeen >= 3 else { continue }
            let path = String(rest[nameStart...]).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, path != "Name", !path.hasPrefix("----") else { continue }
            entries.append(Entry(path: path, sizeBytes: size, isDirectory: path.hasSuffix("/")))
        }
        return entries
    }

    /// 大小格式化（B/KB/MB）。
    nonisolated static func sizeText(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
