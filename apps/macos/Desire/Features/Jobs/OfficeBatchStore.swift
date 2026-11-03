import Combine
import Foundation

/// Office 文件夹批量转换（v0.8.40）：选目录 → 逐个文件转换到 `Converted/`，
/// 每项独立成功/失败，不覆盖原文件。长任务模式：立即返回 jobID。
@MainActor
final class OfficeBatchStore: ObservableObject {
    static let shared = OfficeBatchStore()

    private init() {}

    private nonisolated static let sourceExtensions: Set<String> = [
        "pdf", "docx", "doc", "rtf", "rtfd", "odt", "html", "htm",
        "csv", "tsv", "xlsx", "pptx", "json", "jsonl", "ndjson",
        "png", "jpg", "jpeg", "heic", "tiff", "gif", "webp",
    ]

    @discardableResult
    func start(folder: URL, format: String, recursive: Bool,
               conversationID: UUID?, report: JobWatch.Mode?) -> Result<UUID, CommandLaunchError> {
        let fmt = format.lowercased()
        guard DocumentConvert.formats.contains(fmt) else {
            return .failure(CommandLaunchError(String(localized: "Unsupported target format: \(fmt)")))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir),
              isDir.boolValue else {
            return .failure(CommandLaunchError(String(localized: "Folder does not exist: \(folder.path)")))
        }
        let jobID = JobStore.shared.start(
            title: String(localized: "Convert \(folder.lastPathComponent) → \(fmt)"),
            kind: .office,
            detail: String(localized: "Scanning…"),
            source: "office-batch",
            conversationID: conversationID)
        if let report {
            _ = JobWatchStore.shared.register(
                jobIDs: [jobID.uuidString], conversationID: conversationID,
                mode: report, reason: String(localized: "Office batch"))
        }
        Task { @MainActor [weak self] in
            await self?.run(jobID: jobID, folder: folder, format: fmt,
                            recursive: recursive)
        }
        return .success(jobID)
    }

    private func run(jobID: UUID, folder: URL, format: String,
                     recursive: Bool) async {
        let files = Self.files(in: folder, recursive: recursive)
        guard !files.isEmpty else {
            JobStore.shared.finish(
                jobID, state: .failed,
                detail: String(localized: "No convertible files found"),
                error: String(localized: "No convertible files found"))
            JobEventCenter.shared.recordTerminal(jobID: jobID)
            return
        }
        let outputDir = uniqueDirectory(folder.appendingPathComponent("Converted",
                                                                       isDirectory: true))
        do {
            try FileManager.default.createDirectory(at: outputDir,
                                                    withIntermediateDirectories: true)
        } catch {
            JobStore.shared.finish(
                jobID, state: .failed,
                detail: String(localized: "Could not create Converted folder"),
                error: error.localizedDescription)
            JobEventCenter.shared.recordTerminal(jobID: jobID)
            return
        }

        var failures: [String] = []
        var done = 0
        for (index, file) in files.enumerated() {
            if Task.isCancelled { break }
            guard let job = JobStore.shared.job(id: jobID), job.state == .running else { break }
            let progress = Double(index) / Double(files.count)
            JobStore.shared.update(
                jobID,
                detail: "\(index + 1)/\(files.count) · \(file.lastPathComponent)",
                progress: progress)
            let dest = uniqueFile(in: outputDir,
                                  base: file.deletingPathExtension().lastPathComponent,
                                  ext: format)
            let outcome = await DocumentConvert.convert(
                sources: [file], format: format, to: dest)
            if outcome.ok {
                done += 1
            } else {
                failures.append("\(file.lastPathComponent): \(outcome.message)")
            }
        }
        let summary = done == files.count
            ? String(localized: "Converted \(done) file(s) → \(outputDir.path)")
            : String(localized: "Converted \(done)/\(files.count) file(s) → \(outputDir.path)")
            + (failures.isEmpty ? "" : "\n" + failures.prefix(8).joined(separator: "\n"))
        let state: JobRecord.State = done == 0 ? .failed : .done
        JobStore.shared.finish(
            jobID, state: state,
            detail: String(localized: "\(done)/\(files.count) converted"),
            receipt: summary,
            artifactURL: outputDir.path,
            error: state == .failed ? String(localized: "All conversions failed") : nil)
        JobEventCenter.shared.recordTerminal(jobID: jobID)
    }

    private func uniqueDirectory(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("Converted-\(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    private func uniqueFile(in dir: URL, base: String, ext: String) -> URL {
        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private nonisolated static func files(in folder: URL, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        if recursive {
            guard let enumerator = fm.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]) else { return [] }
            for case let url as URL in enumerator {
                if sourceExtensions.contains(url.pathExtension.lowercased()) {
                    result.append(url)
                }
            }
        } else {
            let children = (try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])) ?? []
            result = children.filter {
                sourceExtensions.contains($0.pathExtension.lowercased())
            }
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
