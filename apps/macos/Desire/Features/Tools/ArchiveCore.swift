import Foundation

/// 压缩/解压纯逻辑（v0.8.33 文件批）：归档命名与 zip-slip 路径校验。
/// 命令执行在 ArchiveEngine。纯 Foundation、进 tests/run.sh。
nonisolated enum ArchiveCore {

    enum Format: String, CaseIterable, Identifiable, Sendable {
        case zip, tarGz
        var id: String { rawValue }
        var displayName: String { self == .zip ? "ZIP" : "TAR.GZ" }
        var fileExtension: String { self == .zip ? "zip" : "tar.gz" }
    }

    struct Entry: Equatable, Sendable {
        var path: String
        var isDirectory: Bool
    }

    enum ArchiveError: LocalizedError {
        case emptySelection
        case differentDirectories
        case unsafeEntry(String)
        case commandFailed(String)
        case noFiles
        case destinationExists(String)

        var errorDescription: String? {
            switch self {
            case .emptySelection:
                return String(localized: "Choose at least one file or folder.")
            case .differentDirectories:
                return String(localized: "All selected items must be in the same folder.")
            case .unsafeEntry(let path):
                return String(localized: "The archive contains an unsafe path: \(path)")
            case .commandFailed(let message):
                return String(localized: "Archive command failed: \(message)")
            case .noFiles:
                return String(localized: "The archive is empty.")
            case .destinationExists(let name):
                return String(localized: "\(name) already exists.")
            }
        }
    }

    /// `Photos` → `Photos.zip`；`a.txt` → `a.txt.zip`。
    static func archiveFileName(sourceName: String, format: Format) -> String {
        let trimmed = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.isEmpty ? "Archive" : trimmed
        return safe + "." + format.fileExtension
    }

    /// 校验并归一归档条目路径；绝对路径、`..`、反斜杠、空路径一律拒绝。
    static func safeEntryPath(_ raw: String) -> String? {
        guard !raw.isEmpty, !raw.contains("\\"), !raw.contains("\0") else { return nil }
        guard !raw.hasPrefix("/") else { return nil }
        let components = raw.components(separatedBy: "/")
        var normalized: [String] = []
        for component in components {
            if component.isEmpty { continue }
            if component == "." { return nil }
            if component == ".." { return nil }
            if component.contains(":") { return nil }
            normalized.append(component)
        }
        return normalized.isEmpty ? nil : normalized.joined(separator: "/")
    }

    /// 解压前校验整张清单；返回第一个不安全条目。
    static func firstUnsafeEntry(_ entries: [String]) -> String? {
        entries.first { safeEntryPath($0) == nil }
    }
}

/// 归档命令执行（ditto / zip / tar；解压前先校验路径）。
nonisolated enum ArchiveEngine {

    typealias ProgressHandler = @Sendable (_ message: String) -> Void

    static func list(archive: URL) async throws -> [ArchiveCore.Entry] {
        try await Task.detached(priority: .userInitiated) {
            let names = try listNames(archive: archive)
            guard !names.isEmpty else { throw ArchiveCore.ArchiveError.noFiles }
            return names.map { name in
                ArchiveCore.Entry(path: name, isDirectory: name.hasSuffix("/"))
            }
        }.value
    }

    /// 压缩：所有源文件/文件夹必须在同一目录（保证归档内是相对路径）。
    static func create(sources: [URL], format: ArchiveCore.Format,
                       to destination: URL) async throws -> Int {
        guard !sources.isEmpty else { throw ArchiveCore.ArchiveError.emptySelection }
        let parent = sources[0].deletingLastPathComponent().standardizedFileURL
        guard sources.allSatisfy({
            $0.deletingLastPathComponent().standardizedFileURL == parent
        }) else {
            throw ArchiveCore.ArchiveError.differentDirectories
        }
        return try await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: destination)
            let names = sources.map { source -> String in
                let name = source.lastPathComponent
                return name.hasPrefix("-") ? "./" + name : name
            }
            let arguments: [String]
            let executable: String
            switch format {
            case .zip:
                executable = "/usr/bin/zip"
                arguments = ["-r", "-y", "-q", destination.path] + names
            case .tarGz:
                executable = "/usr/bin/tar"
                arguments = ["-czf", destination.path, "-C", parent.path] + names
            }
            let result = try run(executable, arguments, workingDirectory: parent)
            guard result.status == 0 else {
                throw ArchiveCore.ArchiveError.commandFailed(result.message)
            }
            return sources.count
        }.value
    }

    /// 解压到目录（先列清单并逐条校验，拒绝 zip-slip）。
    static func extract(archive: URL, to directory: URL,
                        progress: ProgressHandler? = nil) async throws -> [ArchiveCore.Entry] {
        try await Task.detached(priority: .userInitiated) {
            let names = try listNames(archive: archive)
            guard !names.isEmpty else { throw ArchiveCore.ArchiveError.noFiles }
            if let unsafe = ArchiveCore.firstUnsafeEntry(names) {
                throw ArchiveCore.ArchiveError.unsafeEntry(unsafe)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            progress?(String(localized: "Extracting…"))
            let result: ProcessResult
            if archive.pathExtension.lowercased() == "zip" {
                result = try run("/usr/bin/ditto",
                                 ["-x", "-k", archive.path, directory.path], workingDirectory: nil)
            } else {
                result = try run("/usr/bin/tar",
                                 ["-xzf", archive.path, "-C", directory.path], workingDirectory: nil)
            }
            guard result.status == 0 else {
                throw ArchiveCore.ArchiveError.commandFailed(result.message)
            }
            return names.map {
                ArchiveCore.Entry(path: $0, isDirectory: $0.hasSuffix("/"))
            }
        }.value
    }

    // MARK: - 私有

    private struct ProcessResult {
        var status: Int32
        var output: String
        var message: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func listNames(archive: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw ArchiveCore.ArchiveError.commandFailed("file not found")
        }
        let executable: String
        let arguments: [String]
        if archive.pathExtension.lowercased() == "zip" {
            executable = "/usr/bin/unzip"
            arguments = ["-Z1", archive.path]
        } else {
            executable = "/usr/bin/tar"
            arguments = ["-tzf", archive.path]
        }
        let result = try run(executable, arguments, workingDirectory: nil)
        guard result.status == 0 else {
            throw ArchiveCore.ArchiveError.commandFailed(result.message)
        }
        return result.output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
    }

    private static func run(_ executable: String, _ arguments: [String],
                            workingDirectory: URL?) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw ArchiveCore.ArchiveError.commandFailed(error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus,
                             output: String(data: data, encoding: .utf8) ?? "")
    }
}
