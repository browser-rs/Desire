import Combine
import CoreGraphics
import Foundation

/// 图片批量编辑（迭代 3 · v0.8.43）：对文件夹应用统一管线
/// （preset + 缩放 + 格式），每文件独立 Job；失败逐项可见，取消保留已完成项。
@MainActor
final class ImageBatchEditStore: ObservableObject {
    static let shared = ImageBatchEditStore()

    private init() {}

    func start(folder: URL, format: String, quality: Double,
               longEdge: Int?, recursive: Bool,
               presetName: String?, conversationID: UUID?) -> Result<UUID, CommandLaunchError> {
        let fmt = format.lowercased()
        if let error = ImageBatchEditCore.validationError(folder: folder, format: fmt) {
            return .failure(CommandLaunchError(error))
        }
        let params = presetName.flatMap { name -> ImageAdjustParams? in
            ImageEditPresetStore.shared.presets
                .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?
                .params
        }
        let jobID = JobStore.shared.start(
            title: String(localized: "Batch edit \(folder.lastPathComponent)"),
            kind: .office,
            detail: String(localized: "Scanning…"),
            source: "image-batch-edit",
            conversationID: conversationID)
        Task { @MainActor [weak self] in
            await self?.run(jobID: jobID, folder: folder, format: fmt,
                            quality: quality, longEdge: longEdge,
                            recursive: recursive, params: params)
        }
        return .success(jobID)
    }

    private func run(jobID: UUID, folder: URL, format: String,
                     quality: Double, longEdge: Int?, recursive: Bool,
                     params: ImageAdjustParams?) async {
        let files = ImageBatchEditCore.inputFiles(in: folder, recursive: recursive)
        guard !files.isEmpty else {
            JobStore.shared.finish(
                jobID, state: .failed,
                detail: String(localized: "No image files found"),
                error: String(localized: "No image files found"))
            JobEventCenter.shared.recordTerminal(jobID: jobID)
            return
        }
        let outputDir = folder.appendingPathComponent("Edited", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir,
                                                withIntermediateDirectories: true)
        var failures: [String] = []
        var succeeded = 0
        for (index, file) in files.enumerated() {
            if Task.isCancelled { break }
            guard let job = JobStore.shared.job(id: jobID), job.state == .running else { break }
            JobStore.shared.update(
                jobID,
                detail: "\(index + 1)/\(files.count) · \(file.lastPathComponent)",
                progress: Double(index) / Double(files.count))
            guard let original = ImageTransforms.load(from: file) else {
                failures.append("\(file.lastPathComponent): load failed")
                continue
            }
            // 管线渲染（preset 参数 + 选区/曲线一并走 pipeline）
            var output = ImagePipelineRenderer.render(base: original, pipeline: {
                var pipeline = ImageEditPipeline()
                if let params {
                    _ = pipeline.append(.adjust(params))
                }
                return pipeline
            }()) ?? original
            // 长边缩放
            if let edge = longEdge, edge >= 16 {
                let long = max(output.width, output.height)
                if long > edge {
                    let scale = Double(edge) / Double(long)
                    let width = max(1, Int((Double(output.width) * scale).rounded()))
                    let height = max(1, Int((Double(output.height) * scale).rounded()))
                    output = ImageTransforms.resized(output, width: width,
                                                     height: height) ?? output
                }
            }
            let dest = ImageBatchEditCore.outputURL(for: file, in: outputDir, format: format)
            do {
                try ImageTransforms.save(output, to: dest, quality: quality)
                succeeded += 1
            } catch {
                failures.append("\(file.lastPathComponent): write failed")
            }
        }
        let summary = succeeded == files.count
            ? String(localized: "Edited \(succeeded) image(s) → \(outputDir.path)")
            : String(localized: "Edited \(succeeded)/\(files.count) image(s) → \(outputDir.path)")
            + (failures.isEmpty ? "" : "\n" + failures.prefix(6).joined(separator: "\n"))
        let state: JobRecord.State = succeeded == 0 ? .failed : .done
        JobStore.shared.finish(
            jobID, state: state,
            detail: String(localized: "\(succeeded)/\(files.count) edited"),
            receipt: summary,
            artifactURL: outputDir.path,
            error: state == .failed ? String(localized: "All edits failed") : nil)
        JobEventCenter.shared.recordTerminal(jobID: jobID)
    }
}
