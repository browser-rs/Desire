import AVFoundation
import Combine
import Foundation
import os

/// 批量剪辑（v0.8.48 批 3）：对一个文件夹里的视频做 trim（可选裁头尾）或
/// concat（按名称顺序拼成一条）。走 `Jobs` 台账（立即返回 job id，进度/产物/
/// 失败逐项可见），底层复用 `TimelineCore` + `VideoEditorStore.export` 的离线
/// 合成路径（与 `editTimeline` 同一引擎）。
@MainActor
final class VideoBatchStore {
    static let shared = VideoBatchStore()

    enum BatchError: Error {
        case message(String)
    }

    struct Options {
        var folder: URL
        var start: Double?
        var end: Double?
        var concat: Bool
        var recursive: Bool
        var height: Double?

        var outputDirectoryName: String { concat ? "Merged" : "Trimmed" }
    }

    private nonisolated static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    @discardableResult
    func start(options: Options, conversationID: UUID?) -> Result<UUID, BatchError> {
        let files = Self.collectVideos(in: options.folder, recursive: options.recursive)
        guard !files.isEmpty else {
            return .failure(.message(
                "No video files (mp4/mov/m4v) in \(options.folder.path)"))
        }
        let jobID = JobStore.shared.start(
            title: options.concat
                ? String(localized: "Video batch merge")
                : String(localized: "Video batch trim"),
            kind: .media,
            detail: "\(files.count) file(s)",
            source: "videoBatch",
            conversationID: conversationID)
        Task { [weak self] in
            await self?.run(jobID: jobID, files: files, options: options)
        }
        return .success(jobID)
    }

    // MARK: - 执行

    private func run(jobID: UUID, files: [URL], options: Options) async {
        let outputDir = options.folder
            .appendingPathComponent(options.outputDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir,
                                                 withIntermediateDirectories: true)
        let log = Logger(subsystem: "me.siwi.Desire", category: "video")
        log.info("videoBatch: \(files.count) file(s) -> \(outputDir.path, privacy: .public)")

        if options.concat {
            await runConcat(jobID: jobID, files: files, options: options, outputDir: outputDir)
            return
        }

        var outputs: [URL] = []
        var failures: [String] = []
        for (index, file) in files.enumerated() {
            let name = file.lastPathComponent
            JobStore.shared.update(jobID,
                                   detail: "\(index + 1)/\(files.count): \(name)",
                                   progress: Double(index) / Double(files.count))
            do {
                let output = try await exportTrimmed(file: file, options: options,
                                                     outputDir: outputDir)
                outputs.append(output)
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
                log.error("videoBatch failed \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        finish(jobID: jobID, outputs: outputs, failures: failures,
               outputDir: outputDir, options: options)
    }

    private func runConcat(jobID: UUID, files: [URL], options: Options,
                           outputDir: URL) async {
        var project = TimelineCore.Project()
        project.title = "merged"
        guard let videoTrack = project.tracks.first(where: { $0.kind == .video }) else {
            JobStore.shared.finish(jobID, state: .failed, error: "No video track in project")
            return
        }
        JobStore.shared.update(jobID, detail: "Collecting clips…", progress: 0.1)
        var at = 0.0
        var failures: [String] = []
        for file in files {
            let duration = await MediaEditProbe.duration(file) ?? 0
            guard duration > 0 else {
                failures.append("\(file.lastPathComponent): unreadable")
                continue
            }
            let start = max(0, options.start ?? 0)
            let end = min(options.end ?? duration, duration)
            let clipDuration = max(0.1, end - start)
            let clip = TimelineCore.Clip(start: at, duration: clipDuration,
                                         sourceStart: start, sourceURL: file,
                                         label: file.lastPathComponent)
            if let next = TimelineCore.upsertClip(project, trackID: videoTrack.id, clip: clip) {
                project = next
                at += clipDuration
            } else {
                failures.append("\(file.lastPathComponent): rejected by timeline")
            }
        }
        guard at > 0.1 else {
            JobStore.shared.finish(jobID, state: .failed,
                                   receipt: failures.joined(separator: "\n"),
                                   error: "Nothing to merge")
            return
        }
        JobStore.shared.update(jobID, detail: "Rendering \(MediaEditCore.formatClock(at))…",
                               progress: 0.3)
        do {
            let rendered = try await VideoEditorStore.export(
                project: project,
                progress: { fraction in
                    Task { @MainActor in
                        JobStore.shared.update(jobID, progress: 0.3 + fraction * 0.7)
                    }
                },
                targetHeight: options.height)
            let output = outputDir.appendingPathComponent("merged.mp4")
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: rendered, to: output)
            finish(jobID: jobID, outputs: [output], failures: failures,
                   outputDir: outputDir, options: options)
        } catch {
            JobStore.shared.finish(jobID, state: .failed,
                                   receipt: failures.joined(separator: "\n"),
                                   error: error.localizedDescription)
        }
    }

    private func exportTrimmed(file: URL, options: Options,
                               outputDir: URL) async throws -> URL {
        let duration = await MediaEditProbe.duration(file) ?? 0
        guard duration > 0 else {
            throw BatchError.message("unreadable (no duration)")
        }
        let start = max(0, options.start ?? 0)
        let end = min(options.end ?? duration, duration)
        let clipDuration = max(0.1, end - start)
        var project = TimelineCore.Project()
        project.title = file.deletingPathExtension().lastPathComponent
        guard let videoTrack = project.tracks.first(where: { $0.kind == .video }) else {
            throw BatchError.message("no video track")
        }
        let clip = TimelineCore.Clip(start: 0, duration: clipDuration,
                                     sourceStart: start, sourceURL: file,
                                     label: file.lastPathComponent)
        guard let next = TimelineCore.upsertClip(project, trackID: videoTrack.id, clip: clip) else {
            throw BatchError.message("timeline rejected the clip")
        }
        project = next
        let rendered = try await VideoEditorStore.export(
            project: project, progress: { _ in }, targetHeight: options.height)
        let base = file.deletingPathExtension().lastPathComponent
        var output = outputDir.appendingPathComponent(base + "-trimmed.mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: output.path) {
            output = outputDir.appendingPathComponent("\(base)-trimmed-\(counter).mp4")
            counter += 1
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: rendered, to: output)
        return output
    }

    private func finish(jobID: UUID, outputs: [URL], failures: [String],
                        outputDir: URL, options: Options) {
        let summary = "\(outputs.count) done · \(failures.count) failed · \(options.outputDirectoryName)/"
        let receipt = (outputs.map(\.lastPathComponent) + failures).joined(separator: "\n")
        JobStore.shared.finish(
            jobID,
            state: failures.isEmpty ? .done : .failed,
            detail: summary,
            receipt: receipt.trimmingCharacters(in: .whitespacesAndNewlines),
            artifactURL: outputs.first?.path ?? outputDir.path,
            error: failures.isEmpty ? nil : failures.joined(separator: "\n"))
        guard !outputs.isEmpty else { return }
        AgentScheduler.shared.deliveryTarget?.appendExternalNote(
            "Video batch finished: \(outputs.count) file(s), \(failures.count) failed. Output: \(outputDir.path)")
        ProactiveNotificationStore.shared.deliver(
            title: String(localized: "Video batch finished"),
            body: String(localized: "Open the Jobs panel to see the results."),
            tier: .routine)
    }

    // MARK: - 收集

    nonisolated static func collectVideos(in folder: URL, recursive: Bool) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: recursive ? [] : [.skipsSubdirectoryDescendants]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard videoExtensions.contains(url.pathExtension.lowercased()) else { continue }
            // 输出目录不参与收集（重跑不会把上次的产物再处理一遍）。
            if url.pathComponents.contains("Trimmed") || url.pathComponents.contains("Merged") {
                continue
            }
            files.append(url)
        }
        return files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
