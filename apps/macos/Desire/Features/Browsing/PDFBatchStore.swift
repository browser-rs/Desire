import Combine
import Foundation
import PDFKit

/// PDF 批量处理（v0.8.44 批 4）：merge/split/extract/rotate 走 JobStore 台账，
/// 每文件独立失败可见，取消保留已完成项。逐文件 PDFKit 工作丢后台任务
/// （PDFDocument 在 detached 任务里创建/使用/释放），主线程只派发与记账。
@MainActor
final class PDFBatchStore: ObservableObject {
    static let shared = PDFBatchStore()

    private init() {}

    func start(folder: URL, operation: PDFBatchCore.Operation,
               pagesSpec: String?, degrees: Int,
               recursive: Bool, conversationID: UUID?) -> Result<UUID, CommandLaunchError> {
        if let error = PDFBatchCore.validationError(folder: folder,
                                                    operation: operation,
                                                    pagesSpec: pagesSpec) {
            return .failure(CommandLaunchError(error))
        }
        let jobID = JobStore.shared.start(
            title: String(localized: "PDF batch (\(operation.rawValue)) \(folder.lastPathComponent)"),
            kind: .pdf,
            detail: String(localized: "Scanning…"),
            source: "pdf-batch",
            conversationID: conversationID)
        Task { @MainActor [weak self] in
            await self?.run(jobID: jobID, folder: folder, operation: operation,
                            pagesSpec: pagesSpec?.trimmingCharacters(in: .whitespaces),
                            degrees: degrees, recursive: recursive)
        }
        return .success(jobID)
    }

    private func run(jobID: UUID, folder: URL, operation: PDFBatchCore.Operation,
                     pagesSpec: String?, degrees: Int, recursive: Bool) async {
        let files = PDFBatchCore.pdfFiles(in: folder, recursive: recursive)
        guard !files.isEmpty else {
            JobStore.shared.finish(
                jobID, state: .failed,
                detail: String(localized: "No PDF files found"),
                error: String(localized: "No PDF files found in the folder"))
            JobEventCenter.shared.recordTerminal(jobID: jobID)
            return
        }
        // merge 的单位 = 整个文件夹一个输出；其余每文件一输出
        let outputDir = folder.appendingPathComponent(operation.outputDirectoryName,
                                                      isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir,
                                                 withIntermediateDirectories: true)
        var failures: [String] = []
        var succeeded = 0
        let units = operation == .merge ? 1 : files.count
        if operation == .merge {
            JobStore.shared.update(jobID,
                                   detail: "1/\(units) · \(folder.lastPathComponent)",
                                   progress: 0)
            if await mergeFiles(files: files, to: PDFBatchCore.mergeOutputURL(
                in: folder, outputDir: outputDir)) != nil {
                succeeded = 1
            } else {
                failures.append("\(folder.lastPathComponent): merge failed")
            }
        } else {
            for (index, file) in files.enumerated() {
                if Task.isCancelled { break }
                guard let job = JobStore.shared.job(id: jobID), job.state == .running else { break }
                JobStore.shared.update(
                    jobID,
                    detail: "\(index + 1)/\(units) · \(file.lastPathComponent)",
                    progress: Double(index) / Double(units))
                let outcome = await processFile(file: file, operation: operation,
                                                pagesSpec: pagesSpec,
                                                degrees: degrees,
                                                outputDir: outputDir)
                if let error = outcome {
                    failures.append("\(file.lastPathComponent): \(error)")
                } else {
                    succeeded += 1
                }
            }
        }
        let total = operation == .merge ? 1 : files.count
        let summary = succeeded == total
            ? String(localized: "Processed \(succeeded) → \(outputDir.path)")
            : String(localized: "Processed \(succeeded)/\(total) → \(outputDir.path)")
            + (failures.isEmpty ? "" : "\n" + failures.prefix(6).joined(separator: "\n"))
        let state: JobRecord.State = succeeded == 0 ? .failed : .done
        JobStore.shared.finish(
            jobID, state: state,
            detail: String(localized: "\(succeeded)/\(total) done"),
            receipt: summary,
            artifactURL: outputDir.path,
            error: state == .failed ? String(localized: "All PDF operations failed") : nil)
        JobEventCenter.shared.recordTerminal(jobID: jobID)
    }

    /// 单文件处理；返回 nil = 成功，字符串 = 失败原因。
    private func processFile(file: URL, operation: PDFBatchCore.Operation,
                             pagesSpec: String?, degrees: Int,
                             outputDir: URL) async -> String? {
        let dest = PDFBatchCore.outputURL(for: file, in: outputDir, operation: operation)
        let src = file
        let target = dest
        let op = operation
        let spec = pagesSpec
        let angle = degrees
        return await Task.detached(priority: .utility) {
            guard let document = PDFDocument(url: src) else { return "open failed" }
            guard !document.isLocked else { return "password-protected" }
            switch op {
            case .split:
                for pageIndex in 0..<document.pageCount {
                    guard let page = document.page(at: pageIndex) else { continue }
                    let single = PDFDocument()
                    single.insert(page, at: 0)
                    let url = PDFBatchCore.outputURL(for: src, in: target.deletingLastPathComponent(),
                                                     operation: .split, pageIndex: pageIndex)
                    try? FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard single.write(to: url) else { return "write failed" }
                }
            case .extract:
                guard let indices = PageRangeParser.parse(spec ?? "",
                                                          pageCount: document.pageCount) else {
                    return "invalid pages spec"
                }
                let out = PDFDocument()
                for (offset, index) in indices.enumerated() {
                    if let page = document.page(at: index) {
                        out.insert(page, at: offset)
                    }
                }
                guard out.pageCount > 0, out.write(to: target) else { return "write failed" }
            case .rotate:
                let normalized = ((angle % 360) + 360) % 360
                guard normalized % 90 == 0 else { return "degrees must be a multiple of 90" }
                for pageIndex in 0..<document.pageCount {
                    document.page(at: pageIndex)?.rotation =
                        ((document.page(at: pageIndex)?.rotation ?? 0) + normalized) % 360
                }
                guard document.write(to: target) else { return "write failed" }
            case .merge:
                return "unsupported"
            }
            return nil
        }.value
    }

    private func mergeFiles(files: [URL], to dest: URL) async -> Int? {
        let sources = files
        let target = dest
        return await Task.detached(priority: .utility) {
            let out = PDFDocument()
            var inserted = 0
            for source in sources {
                guard let doc = PDFDocument(url: source) else { continue }
                for index in 0..<doc.pageCount {
                    if let page = doc.page(at: index) {
                        out.insert(page, at: inserted)
                        inserted += 1
                    }
                }
            }
            guard inserted > 0, out.write(to: target) else { return nil }
            return inserted
        }.value
    }
}
