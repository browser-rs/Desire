import AppKit
import CoreGraphics
import Foundation

/// 后台任务工具（v0.8.39）的执行实现。定义在 Definitions，分派在 DOMTools。
extension BrowserToolProvider {

    static func listBackgroundTasks(_ args: [String: Any]) -> String {
        let stateFilter = (args["state"] as? String ?? "active").lowercased()
        let kindFilter = (args["kind"] as? String ?? "").lowercased()
        let limit = min(max(Int(args["limit"] as? Double ?? 20), 1), 100)
        let all = JobStore.shared.allJobs
        let filtered = all.filter { job in
            let stateOK: Bool
            switch stateFilter {
            case "all": stateOK = true
            case "failed": stateOK = job.state == .failed
            case "done": stateOK = job.state == .done
            default: stateOK = job.state.isActive
            }
            let kindOK = kindFilter.isEmpty || job.kind.rawValue == kindFilter
                || (kindFilter == "batch" && job.kind == .download
                    && (job.externalID?.hasPrefix("batch-") ?? false))
            return stateOK && kindOK
        }
        guard !filtered.isEmpty else {
            return stateFilter == "active"
                ? String(localized: "No active background tasks.")
                : String(localized: "No matching background tasks.")
        }
        let activeCount = all.filter { $0.state.isActive }.count
        let failedCount = all.filter { $0.state == .failed }.count
        var lines = [
            String(localized: "Background tasks — \(activeCount) active, \(failedCount) failed (showing \(min(limit, filtered.count)))"),
        ]
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        for job in filtered.prefix(limit) {
            var line = "- [\(job.id.uuidString)] \(job.title) — \(job.kind.label) · \(job.state.label)"
            if let progress = job.progress, job.state == .running {
                line += " \(Int((progress * 100).rounded()))%"
            }
            if !job.detail.isEmpty { line += " · \(job.detail)" }
            if let error = job.error, !error.isEmpty { line += " · \(error)" }
            if let artifact = job.artifactURL, !artifact.isEmpty {
                line += " · output: \(artifact)"
            }
            line += " · \(formatter.localizedString(for: job.updatedAt, relativeTo: Date()))"
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func backgroundTaskStatus(_ args: [String: Any]) -> String {
        guard let raw = args["id"] as? String, let id = UUID(uuidString: raw) else {
            return fail("Missing or invalid job id")
        }
        guard let job = JobStore.shared.allJobs.first(where: { $0.id == id }) else {
            return fail("No background task with id \(raw)")
        }
        var lines = [
            "\(job.title)",
            "ID: \(job.id.uuidString)",
            "Kind: \(job.kind.label) · State: \(job.state.label)",
            "Updated: \(job.updatedAt.formatted(date: .abbreviated, time: .standard))",
        ]
        if let progress = job.progress { lines.append("Progress: \(Int((progress * 100).rounded()))%") }
        if !job.detail.isEmpty { lines.append("Detail: \(job.detail)") }
        if let error = job.error, !error.isEmpty { lines.append("Error: \(error)") }
        if let receipt = job.receipt, !receipt.isEmpty { lines.append("Receipt: \(receipt)") }
        if let artifact = job.artifactURL, !artifact.isEmpty { lines.append("Output: \(artifact)") }
        if let exit = job.exitCode { lines.append("Exit code: \(exit)") }
        if let conversation = job.conversationID {
            lines.append("Conversation: \(conversation.uuidString)")
        }
        if let logFile = job.logFile, !logFile.isEmpty {
            let lineCount = min(max(Int(args["logLines"] as? Double ?? 40), 1), 200)
            let tail = BackgroundCommandStore.readTail(path: logFile, maxLines: lineCount)
            lines.append("Log: \(logFile)")
            if !tail.isEmpty { lines.append("Log tail:\n\(tail)") }
        }
        if job.state.isActive {
            let watched = JobWatchStore.shared.active.contains {
                $0.jobIDs.contains(job.id.uuidString)
            }
            lines.append(watched
                ? String(localized: "A completion watch is active.")
                : String(localized: "No completion watch. Use watchBackgroundTasks to be told when it finishes."))
        }
        return lines.joined(separator: "\n")
    }

    static func watchBackgroundTasks(_ args: [String: Any],
                                     conversationID: UUID?) -> String {
        let ids = (args["ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
        let rawIDs = args["ids"] as? [String] ?? []
        if ids.count != rawIDs.count {
            return fail("One or more job ids are invalid")
        }
        let kind = (args["kind"] as? String)?.lowercased()
        let mode = (args["mode"] as? String)?.lowercased() == "resume" ? JobWatch.Mode.resume : .notify
        if let error = JobWatchCore.validationError(ids: ids, kind: kind, mode: mode) {
            return fail(error)
        }
        let conditionName = (args["condition"] as? String ?? "terminal").lowercased()
        let condition: JobWatchCondition
        switch conditionName {
        case "terminal", "done", "finish":
            condition = .terminal
        case "failed", "failure":
            condition = JobWatchCondition(kind: .failed)
        case "progress":
            let value = args["progress"] as? Double ?? 0.5
            guard value > 0, value <= 1 else {
                return fail("progress must be between 0 and 1 (e.g. 0.5)")
            }
            condition = JobWatchCondition(kind: .progress, value: value)
        case "logmatch", "log", "pattern":
            guard let pattern = args["logPattern"] as? String,
                  !pattern.trimmingCharacters(in: .whitespaces).isEmpty else {
                return fail("logPattern is required for a log match watch")
            }
            condition = JobWatchCondition(kind: .logMatch, pattern: pattern)
        case "heartbeat", "progress-report":
            let minutes = Int(args["heartbeatMinutes"] as? Double ?? 10)
            guard minutes >= 1, minutes <= 120 else {
                return fail("heartbeatMinutes must be 1-120")
            }
            condition = JobWatchCondition(kind: .heartbeat, minutes: minutes)
        default:
            return fail("condition must be terminal | failed | progress | logMatch | heartbeat")
        }
        let targets = JobWatchCore.snapshot(ids: ids, kind: kind,
                                            jobs: JobStore.shared.allJobs)
        guard !targets.isEmpty else {
            if let kind {
                return fail("No active background tasks of kind \(kind)")
            }
            return fail("None of those jobs are in the ledger")
        }
        let watch = JobWatchStore.shared.register(
            jobIDs: targets.map(\.id.uuidString),
            conversationID: conversationID, mode: mode,
            reason: args["reason"] as? String, condition: condition)
        let modeText = mode == .resume
            ? String(localized: "I will report the result when the session is idle.")
            : String(localized: "I will add a completion note and notification.")
        let conditionText = JobWatchCore.conditionDescription(condition)
        return String(localized: "Watching \(targets.count) task(s) (watcher \(watch.id.uuidString)) — \(conditionText). \(modeText)\n")
            + targets.map { "- \($0.title) [\($0.id.uuidString)]" }.joined(separator: "\n")
    }

    static func cancelBackgroundTask(_ args: [String: Any]) -> String {
        guard let raw = args["id"] as? String, let id = UUID(uuidString: raw) else {
            return fail("No background task with that id")
        }
        switch JobControl.cancel(id) {
        case .success(let message): return message
        case .failure(let error): return fail(error.message)
        }
    }

    static func retryBackgroundTask(_ args: [String: Any]) async -> String {
        guard let raw = args["id"] as? String, let id = UUID(uuidString: raw) else {
            return fail("No background task with that id")
        }
        switch await JobControl.retry(id) {
        case .success(let newID):
            return String(localized: "Retry started as job \(newID.uuidString).")
        case .failure(let error):
            return fail(error.message)
        }
    }

    static func runBackgroundCommand(_ args: [String: Any],
                                     conversationID: UUID?) async -> String {
        guard let tool = args["tool"] as? String, !tool.isEmpty else {
            return fail("Missing tool (allowlisted: \(SystemCommandStore.shared.allowedBinaries.sorted().joined(separator: ", ")))")
        }
        let commandArgs = args["args"] as? [String] ?? []
        let title = args["title"] as? String
        let cwd = args["cwd"] as? String
        let timeout = min(max(args["timeoutMinutes"] as? Double ?? 60, 1), 360)
        let reportRaw = (args["report"] as? String ?? "notify").lowercased()
        let report: JobWatch.Mode?
        switch reportRaw {
        case "none": report = nil
        case "resume": report = .resume
        default: report = .notify
        }
        let after = (args["after"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
        let maxAttempts = min(max(Int(args["maxAttempts"] as? Double ?? 1), 1), 5)
        let retryOn = (args["retryOn"] as? String ?? "nonZero").lowercased()
        let priority = (args["priority"] as? String ?? "normal").lowercased()
        let result = await BackgroundCommandStore.shared.start(
            tool: tool, args: commandArgs, title: title, cwd: cwd,
            timeoutMinutes: timeout, conversationID: conversationID,
            report: report, after: after,
            maxAttempts: maxAttempts, retryOn: retryOn,
            priority: priority)
        switch result {
        case .success(let id):
            return String(localized: "Background command started as job \(id.uuidString). It will keep running after this turn; use backgroundTaskStatus to check progress.")
        case .failure(let error):
            return fail(error.message)
        }
    }
}


// MARK: - 命令模板（v0.8.40）

extension BrowserToolProvider {
    static func saveJobTemplate(_ args: [String: Any]) -> String {
        guard let name = args["name"] as? String,
              let tool = args["tool"] as? String else {
            return fail("Missing name / tool")
        }
        let commandArgs = args["args"] as? [String] ?? []
        if let error = JobTemplateValidation.error(name: name, tool: tool, args: commandArgs) {
            return fail(error)
        }
        let existing = JobTemplateStore.shared.template(named: name)
        let template = JobTemplate(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            tool: tool, args: commandArgs,
            cwd: args["cwd"] as? String,
            timeoutMinutes: min(max(args["timeoutMinutes"] as? Double ?? 60, 1), 360),
            maxAttempts: min(max(Int(args["maxAttempts"] as? Double ?? 1), 1), 5),
            retryOn: (args["retryOn"] as? String ?? "nonZero").lowercased(),
            priority: (args["priority"] as? String ?? "normal").lowercased(),
            createdAt: existing?.createdAt ?? Date())
        guard JobTemplateStore.shared.save(template) else {
            return fail("Could not save the template")
        }
        return String(localized: "Saved template “\(template.name)”.")
    }

    static func listJobTemplates(_ args: [String: Any]) -> String {
        let templates = JobTemplateStore.shared.templates
        guard !templates.isEmpty else {
            return String(localized: "No job templates yet.")
        }
        return templates.map { template in
            var line = "• \(template.name) — \(template.tool)"
            if !template.args.isEmpty { line += " " + template.args.joined(separator: " ") }
            line += " · \(Int(template.timeoutMinutes)) min"
            if template.maxAttempts > 1 { line += " · retry \(template.maxAttempts)x" }
            if template.priority != "normal" { line += " · \(template.priority)" }
            if let cwd = template.cwd, !cwd.isEmpty { line += " · \(cwd)" }
            return line
        }.joined(separator: "\n")
    }

    static func runJobTemplate(_ args: [String: Any],
                               conversationID: UUID?) async -> String {
        guard let name = args["name"] as? String,
              let template = JobTemplateStore.shared.template(named: name) else {
            return fail("No template named “\(args["name"] as? String ?? "")”")
        }
        let report: JobWatch.Mode? = {
            switch (args["report"] as? String ?? "notify").lowercased() {
            case "none": return nil
            case "resume": return .resume
            default: return .notify
            }
        }()
        let result = await BackgroundCommandStore.shared.start(
            tool: template.tool, args: template.args, title: template.name,
            cwd: template.cwd, timeoutMinutes: template.timeoutMinutes,
            conversationID: conversationID, report: report,
            after: [], maxAttempts: template.maxAttempts,
            retryOn: template.retryOn, priority: template.priority)
        switch result {
        case .success(let id):
            return String(localized: "Template “\(template.name)” started as job \(id.uuidString).")
        case .failure(let error):
            return fail(error.message)
        }
    }
}


extension BrowserToolProvider {
    static func batchConvertFolder(_ args: [String: Any],
                                   conversationID: UUID?) -> String {
        guard let folder = args["folder"] as? String, !folder.isEmpty else {
            return fail("Missing folder")
        }
        guard let format = (args["format"] as? String)?.lowercased(),
              !format.isEmpty else {
            return fail("Missing format (e.g. pdf, docx, md, xlsx)")
        }
        let resolved: URL
        switch AgentWorkspace.shared.resolve(folder, write: false) {
        case .granted(let url): resolved = url
        case .denied(let reason): return reason
        }
        let report: JobWatch.Mode? = {
            switch (args["report"] as? String ?? "notify").lowercased() {
            case "none": return nil
            case "resume": return .resume
            default: return .notify
            }
        }()
        let result = OfficeBatchStore.shared.start(
            folder: resolved, format: format,
            recursive: (args["recursive"] as? Bool) ?? true,
            conversationID: conversationID, report: report)
        switch result {
        case .success(let id):
            return String(localized: "Folder conversion started as job \(id.uuidString). Output goes to Converted/ inside the folder.")
        case .failure(let error):
            return fail(error.message)
        }
    }
}


extension BrowserToolProvider {
    static func batchEditImages(_ args: [String: Any],
                                conversationID: UUID?) -> String {
        guard let folder = args["folder"] as? String, !folder.isEmpty else {
            return fail("Missing folder")
        }
        guard let format = (args["format"] as? String)?.lowercased(),
              !format.isEmpty else {
            return fail("Missing format (jpeg/png/heic)")
        }
        let resolved: URL
        switch AgentWorkspace.shared.resolve(folder, write: false) {
        case .granted(let url): resolved = url
        case .denied(let reason): return reason
        }
        let presetName = args["preset"] as? String
        if let presetName, !presetName.isEmpty,
           ImageEditPresetStore.shared.presets.first(where: {
               $0.name.caseInsensitiveCompare(presetName) == .orderedSame
           }) == nil {
            return fail("No preset named \(presetName)")
        }
        // adjust（v0.8.55 批 4）：内联调节参数 JSON（AI 看样张后定参）——
        // 与 preset 二选一，同时给时 adjust 优先。宽松解码见 ImageAdjustParams。
        var inlineAdjust: ImageAdjustParams?
        if let raw = args["adjust"] as? String, !raw.isEmpty {
            guard let data = raw.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any] else {
                return fail("adjust must be a JSON object string, e.g. {\"exposure\":0.3,\"saturation\":1.2}")
            }
            inlineAdjust = ImageAdjustParams.from(looseJSON: object)
        }
        let quality = min(max(args["quality"] as? Double ?? 0.9, 0.3), 1)
        let longEdge = Int(args["longEdge"] as? Double ?? 0)
        let result = ImageBatchEditStore.shared.start(
            folder: resolved, format: format, quality: quality,
            longEdge: longEdge >= 16 ? longEdge : nil,
            recursive: (args["recursive"] as? Bool) ?? true,
            presetName: presetName?.isEmpty == false ? presetName : nil,
            inlineAdjust: inlineAdjust,
            conversationID: conversationID)
        switch result {
        case .success(let id):
            return String(localized: "Batch edit started as job \(id.uuidString). Output goes to Edited/ inside the folder.")
        case .failure(let error):
            return fail(error.message)
        }
    }

    /// 批量剪辑（v0.8.48 批 3）：trim（裁头尾）/ concat（按名拼成一条）。
    /// 走 Jobs 台账，立即返回 job id；底层复用 TimelineCore + 离线导出引擎。
    static func batchTrimVideos(_ args: [String: Any], conversationID: UUID?) -> String {
        guard let folder = args["folder"] as? String, !folder.isEmpty else {
            return fail("Missing folder")
        }
        let resolved: URL
        switch AgentWorkspace.shared.resolve(folder, write: true) {
        case .granted(let url): resolved = url
        case .denied(let reason): return reason
        }
        let start = args["start"] as? Double
        let end = args["end"] as? Double
        if let start, let end, end <= start {
            return fail("end must be greater than start")
        }
        let options = VideoBatchStore.Options(
            folder: resolved, start: start, end: end,
            concat: (args["concat"] as? Bool) ?? false,
            recursive: (args["recursive"] as? Bool) ?? false,
            height: args["height"] as? Double,
            audioOnly: (args["audioOnly"] as? Bool) ?? false)
        switch VideoBatchStore.shared.start(options: options, conversationID: conversationID) {
        case .success(let id):
            return "Video batch started as job \(id.uuidString). Output goes to \(options.outputDirectoryName)/ inside the folder. Check progress with backgroundTaskStatus."
        case .failure(let error):
            switch error {
            case .message(let message): return fail(message)
            }
        }
    }

    /// PDF 批量处理（v0.8.44 批 4）：merge/split/extract/rotate。
    static func batchProcessPDFs(_ args: [String: Any],
                                 conversationID: UUID?) -> String {
        guard let folder = args["folder"] as? String, !folder.isEmpty else {
            return fail("Missing folder")
        }
        guard let rawOperation = args["operation"] as? String, !rawOperation.isEmpty else {
            return fail("Missing operation (merge/split/extract/rotate)")
        }
        guard let operation = PDFBatchCore.Operation(rawValue: rawOperation.lowercased()) else {
            return fail("Unknown operation \(rawOperation) — use merge | split | extract | rotate")
        }
        let resolved: URL
        switch AgentWorkspace.shared.resolve(folder, write: false) {
        case .granted(let url): resolved = url
        case .denied(let reason): return reason
        }
        let pagesSpec = args["pages"] as? String
        var degrees = Int(args["degrees"] as? Double ?? 90)
        if operation == .rotate, degrees % 90 != 0 {
            return fail("degrees must be a multiple of 90")
        }
        if operation != .rotate { degrees = 90 }
        let result = PDFBatchStore.shared.start(
            folder: resolved, operation: operation,
            pagesSpec: pagesSpec, degrees: degrees,
            recursive: (args["recursive"] as? Bool) ?? false,
            conversationID: conversationID)
        switch result {
        case .success(let id):
            let extra = operation == .extract
                ? " Pages: \(pagesSpec ?? "")." : ""
            return String(localized: "PDF batch started as job \(id.uuidString). Output goes to \(operation.outputDirectoryName)/ inside the folder.\(extra)")
        case .failure(let error):
            return fail(error.message)
        }
    }
}


// MARK: - 编辑器工具族（v0.8.42 批 3）

extension BrowserToolProvider {
    /// lookImageFile（v0.8.55 批 4）：把图片**文件**渲染成 vision 输入裸返
    /// （dataURI 通道，与 screenshot / editImage lookImage 同机制——结果以
    /// `data:image/` 开头即进模型）。AI 批量修图值守的"看"：看 1-3 张样张
    /// 定参 → batchEditImages {adjust}。maxSide 控长边（默认 1024 省 token）。
    static func lookImageFile(_ args: [String: Any]) -> String {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return fail("Missing path")
        }
        let resolved: URL
        switch AgentWorkspace.shared.resolve(path, write: false) {
        case .granted(let url): resolved = url
        case .denied(let reason): return reason
        }
        guard let image = ImageTransforms.load(from: resolved) else {
            return fail("Could not load image at \(resolved.path)")
        }
        let maxSide = min(1024, max(128, args["maxSide"] as? Double ?? 1024))
        let scaled = ImageLookCompare.downscaled(image, maxSide: CGFloat(maxSide))
        guard let uri = ImageAttachment.dataURI(from: NSImage(
            cgImage: scaled, size: CGSize(width: scaled.width, height: scaled.height))) else {
            return fail("Could not encode image")
        }
        return uri
    }

    /// listArtifacts（v0.8.57 批 1）：产物清单（文本行格式——每行一条，
    /// 模型可直接把 path 填进后续作业的 folder/path 参数）。
    static func listArtifacts(_ args: [String: Any]) -> String {
        let kindRaw = (args["kind"] as? String ?? "").lowercased()
        let days = min(365, max(0, Int(args["days"] as? Double ?? 30)))
        let kind = ArtifactIndex.Kind(rawValue: kindRaw)
        let items = ArtifactIndex.filter(
            ArtifactIndex.derive(from: JobStore.shared.allJobs),
            kind: kind, withinDays: days)
        if items.isEmpty {
            return "No artifacts yet (finished jobs with outputs will list here)"
        }
        let fm = FileManager.default
        let lines = items.prefix(40).map { item -> String in
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: item.path, isDirectory: &isDir)
            let sizeText: String
            if !exists {
                sizeText = "missing"
            } else if isDir.boolValue {
                sizeText = "dir"
            } else if let bytes = (try? fm.attributesOfItem(atPath: item.path)[.size]) as? Int {
                sizeText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            } else {
                sizeText = "?"
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            return "[\(item.kind.rawValue)] \(item.path) · \(sizeText) · \(item.jobTitle) · \(formatter.string(from: item.at))"
        }
        let total = items.count
        let header = total > 40 ? "(showing 40 of \(total))\n" : ""
        return header + lines.joined(separator: "\n")
    }

    static func imageInfo(_ args: [String: Any]) -> String {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return fail("Missing path")
        }
        let resolved: URL
        switch AgentWorkspace.shared.resolve(path, write: false) {
        case .granted(let url): resolved = url
        case .denied(let reason): return reason
        }
        guard let summary = ImageEXIF.read(from: resolved) else {
            return fail("Cannot read image at \(resolved.path)")
        }
        var lines: [String] = [
            "File: \(resolved.lastPathComponent)",
            "Size: \(summary.pixelWidth ?? 0) × \(summary.pixelHeight ?? 0) px",
        ]
        if let format = summary.formatName { lines.append("Format: \(format)") }
        if let size = summary.fileSize {
            lines.append("File size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
        }
        if let make = summary.cameraMake ?? summary.cameraModel {
            lines.append("Camera: \(make) \(summary.cameraModel ?? "")")
        }
        if let lens = summary.lensModel { lines.append("Lens: \(lens)") }
        let settings = [summary.exposureTime, summary.fNumber, summary.iso,
                        summary.focalLength].compactMap(\.self)
        if !settings.isEmpty { lines.append("Settings: \(settings.joined(separator: " · "))") }
        if let date = summary.dateTimeOriginal { lines.append("Date: \(date)") }
        if let artist = summary.artist { lines.append("Artist: \(artist)") }
        if let copyright = summary.copyright { lines.append("Copyright: \(copyright)") }
        if !summary.keywords.isEmpty { lines.append("Keywords: \(summary.keywords.joined(separator: ", "))") }
        if let lat = summary.gpsLatitude, let lon = summary.gpsLongitude {
            lines.append("GPS: \(lat), \(lon)")
        } else {
            lines.append("GPS: not present")
        }
        return lines.joined(separator: "\n")
    }

    static func setImageWatermark(_ args: [String: Any]) -> String {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return fail("Missing path")
        }
        let text = args["text"] as? String ?? ""
        let imagePath = args["watermarkImagePath"] as? String ?? ""
        guard !text.isEmpty || !imagePath.isEmpty else {
            return fail("Provide text or watermarkImagePath")
        }
        let resolved: URL
        switch AgentWorkspace.shared.resolve(path, write: true) {
        case .granted(let url): resolved = url
        case .denied(let reason): return reason
        }
        guard let original = ImageTransforms.load(from: resolved) else {
            return fail("Cannot read image at \(resolved.path)")
        }
        var params = ImageWatermarkParams(
            kind: imagePath.isEmpty ? .text : .image,
            text: text,
            imagePath: imagePath,
            position: Int(args["position"] as? Double ?? 8))
        params.opacity = args["opacity"] as? Double ?? 0.6
        params.scale = args["scale"] as? Double ?? 0.04
        params.tile = (args["tile"] as? Bool) ?? false
        guard let output = ImageWatermarkRenderer.render(original, params: params) else {
            return fail("Watermark rendering failed")
        }
        // 写到 Converted/ 或覆盖原文件
        let overwrite = (args["overwrite"] as? Bool) ?? false
        let outputURL: URL
        if overwrite {
            outputURL = resolved
        } else {
            let dir = resolved.deletingLastPathComponent()
                .appendingPathComponent("Converted", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            outputURL = dir.appendingPathComponent("wm-\(resolved.lastPathComponent)")
        }
        do {
            try ImageTransforms.save(output, to: outputURL)
        } catch {
            return fail("Write failed: \(error.localizedDescription)")
        }
        return String(localized: "Watermarked image saved to \(outputURL.path).")
    }

    static func straightenImage(_ args: [String: Any]) -> String {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return fail("Missing path")
        }
        guard let degrees = args["degrees"] as? Double,
              degrees >= -45, degrees <= 45, degrees != 0 else {
            return fail("degrees must be between -45 and 45 (non-zero)")
        }
        let resolved: URL
        switch AgentWorkspace.shared.resolve(path, write: true) {
        case .granted(let url): resolved = url
        case .denied(let reason): return reason
        }
        guard let original = ImageTransforms.load(from: resolved) else {
            return fail("Cannot read image at \(resolved.path)")
        }
        guard let output = ImageTransforms.straightened(original, degrees: degrees) else {
            return fail("Straighten failed")
        }
        do {
            try ImageTransforms.save(output, to: resolved)
        } catch {
            return fail("Write failed: \(error.localizedDescription)")
        }
        return String(localized: "Straightened by \(String(format: "%.1f", degrees))° and saved to \(resolved.path).")
    }

    static func autoEnhanceImage(_ args: [String: Any]) -> String {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return fail("Missing path")
        }
        let resolved: URL
        switch AgentWorkspace.shared.resolve(path, write: true) {
        case .granted(let url): resolved = url
        case .denied(let reason): return reason
        }
        guard let original = ImageTransforms.load(from: resolved) else {
            return fail("Cannot read image at \(resolved.path)")
        }
        let params = ImageAICore.autoEnhance(original)
        guard let output = ImagePipelineRenderer.render(base: original, pipeline: {
            var pipeline = ImageEditPipeline()
            _ = pipeline.append(.adjust(params))
            return pipeline
        }()) else {
            return fail("Auto enhance rendering failed")
        }
        do {
            try ImageTransforms.save(output, to: resolved)
        } catch {
            return fail("Write failed: \(error.localizedDescription)")
        }
        return String(localized: "Auto enhanced and saved to \(resolved.path).")
    }
}


extension BrowserToolProvider {
    static func batchWatermarkImages(_ args: [String: Any],
                                     conversationID: UUID?) -> String {
        guard let folder = args["folder"] as? String, !folder.isEmpty else {
            return fail("Missing folder")
        }
        let text = args["text"] as? String ?? ""
        let imagePath = args["watermarkImagePath"] as? String ?? ""
        guard !text.isEmpty || !imagePath.isEmpty else {
            return fail("Provide text or watermarkImagePath")
        }
        let resolved: URL
        switch AgentWorkspace.shared.resolve(folder, write: true) {
        case .granted(let url): resolved = url
        case .denied(let reason): return reason
        }
        if let error = ImageBatchWatermarkCore.validationError(folder: resolved) {
            return fail(error)
        }
        var params = ImageWatermarkParams(
            kind: imagePath.isEmpty ? .text : .image,
            text: text, imagePath: imagePath,
            position: Int(args["position"] as? Double ?? 8))
        params.opacity = args["opacity"] as? Double ?? 0.6
        params.scale = args["scale"] as? Double ?? 0.04
        params.tile = (args["tile"] as? Bool) ?? false
        params.rotation = args["rotation"] as? Double ?? 0
        let jobID = JobStore.shared.start(
            title: String(localized: "Batch watermark \(resolved.lastPathComponent)"),
            kind: .office,
            detail: String(localized: "Starting…"),
            source: "image-batch-watermark",
            conversationID: conversationID)
        Task { @MainActor in
            let files = ImageBatchEditCore.inputFiles(in: resolved, recursive: true)
            guard !files.isEmpty else {
                JobStore.shared.finish(jobID, state: .failed,
                                       detail: String(localized: "No image files found"),
                                       error: String(localized: "No image files found"))
                JobEventCenter.shared.recordTerminal(jobID: jobID)
                return
            }
            let outputDir = ImageBatchWatermarkCore.outputDir(for: resolved)
            try? FileManager.default.createDirectory(at: outputDir,
                                                    withIntermediateDirectories: true)
            var failures: [String] = []
            var succeeded = 0
            for (index, file) in files.enumerated() {
                if Task.isCancelled { break }
                guard let job = JobStore.shared.job(id: jobID),
                      job.state == .running else { break }
                JobStore.shared.update(
                    jobID,
                    detail: "\(index + 1)/\(files.count) · \(file.lastPathComponent)",
                    progress: Double(index) / Double(files.count))
                guard let original = ImageTransforms.load(from: file) else {
                    failures.append("\(file.lastPathComponent): load failed")
                    continue
                }
                guard let output = ImageWatermarkRenderer.render(original, params: params) else {
                    failures.append("\(file.lastPathComponent): render failed")
                    continue
                }
                let dest = ImageBatchWatermarkCore.outputURL(for: file, in: outputDir)
                do {
                    try ImageTransforms.save(output, to: dest)
                    succeeded += 1
                } catch {
                    failures.append("\(file.lastPathComponent): write failed")
                }
            }
            let summary = succeeded == files.count
                ? String(localized: "Watermarked \(succeeded) image(s) → \(outputDir.path)")
                : String(localized: "Watermarked \(succeeded)/\(files.count) image(s) → \(outputDir.path)")
                + (failures.isEmpty ? "" : "\n" + failures.prefix(6).joined(separator: "\n"))
            let state: JobRecord.State = succeeded == 0 ? .failed : .done
            JobStore.shared.finish(
                jobID, state: state,
                detail: String(localized: "\(succeeded)/\(files.count) watermarked"),
                receipt: summary,
                artifactURL: outputDir.path,
                error: state == .failed ? String(localized: "All watermarks failed") : nil)
            JobEventCenter.shared.recordTerminal(jobID: jobID)
        }
        return String(localized: "Batch watermark started as job. Progress in Jobs center.")
    }
}


// MARK: - 图片编辑补齐（迭代 2 · v0.8.43）

extension BrowserToolProvider {
    static func cropImage(_ args: [String: Any]) -> String {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return fail("Missing path")
        }
        guard let x = args["x"] as? Double, let y = args["y"] as? Double,
              let w = args["width"] as? Double, let h = args["height"] as? Double,
              w > 0, h > 0, x >= 0, y >= 0 else {
            return fail("Missing or invalid x/y/width/height")
        }
        let resolved: URL
        switch AgentWorkspace.shared.resolve(path, write: true) {
        case .granted(let url): resolved = url
        case .denied(let reason): return reason
        }
        guard let original = ImageTransforms.load(from: resolved) else {
            return fail("Cannot read image at \(resolved.path)")
        }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        guard rect.maxX <= CGFloat(original.width),
              rect.maxY <= CGFloat(original.height) else {
            return fail("Crop rect exceeds image bounds (\(original.width) × \(original.height))")
        }
        guard let output = ImageTransforms.cropped(original, rect: rect) else {
            return fail("Crop failed")
        }
        do {
            try ImageTransforms.save(output, to: resolved)
        } catch {
            return fail("Write failed: \(error.localizedDescription)")
        }
        return String(localized: "Cropped to \(Int(w)) × \(Int(h)) and saved to \(resolved.path).")
    }

    static func flipImage(_ args: [String: Any]) -> String {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return fail("Missing path")
        }
        guard let direction = args["direction"] as? String else {
            return fail("Missing direction (horizontal/vertical)")
        }
        let horizontal: Bool
        switch direction.lowercased() {
        case "horizontal", "h": horizontal = true
        case "vertical", "v": horizontal = false
        default: return fail("direction must be horizontal or vertical")
        }
        let resolved: URL
        switch AgentWorkspace.shared.resolve(path, write: true) {
        case .granted(let url): resolved = url
        case .denied(let reason): return reason
        }
        guard let original = ImageTransforms.load(from: resolved) else {
            return fail("Cannot read image at \(resolved.path)")
        }
        guard let output = ImageTransforms.flipped(original, horizontal: horizontal) else {
            return fail("Flip failed")
        }
        do {
            try ImageTransforms.save(output, to: resolved)
        } catch {
            return fail("Write failed: \(error.localizedDescription)")
        }
        return String(localized: "Flipped \(direction) and saved to \(resolved.path).")
    }

    static func resizeImage(_ args: [String: Any]) -> String {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return fail("Missing path")
        }
        guard let width = args["width"] as? Int, width > 0 else {
            return fail("Missing or invalid width")
        }
        let height: Int
        if let h = args["height"] as? Int, h > 0 {
            height = h
        } else {
            guard let original = ImageTransforms.load(from: resolved(path)) else {
                return fail("Cannot read image")
            }
            height = max(1, Int((Double(original.height) * Double(width) / Double(original.width)).rounded()))
        }
        let resolved: URL
        switch AgentWorkspace.shared.resolve(path, write: true) {
        case .granted(let url): resolved = url
        case .denied(let reason): return reason
        }
        guard let original = ImageTransforms.load(from: resolved) else {
            return fail("Cannot read image at \(resolved.path)")
        }
        guard let output = ImageTransforms.resized(original, width: width, height: height) else {
            return fail("Resize failed")
        }
        do {
            try ImageTransforms.save(output, to: resolved)
        } catch {
            return fail("Write failed: \(error.localizedDescription)")
        }
        return String(localized: "Resized to \(width) × \(height) and saved to \(resolved.path).")
    }

    private static func resolved(_ path: String) -> URL {
        switch AgentWorkspace.shared.resolve(path, write: false) {
        case .granted(let url): return url
        case .denied: return URL(fileURLWithPath: path)
        }
    }
}


extension BrowserToolProvider {
    static func mergeImages(_ args: [String: Any]) -> String {
        let paths = (args["paths"] as? [String] ?? []).filter { !$0.isEmpty }
        guard paths.count >= 2 else {
            return fail("Provide at least 2 image paths")
        }
        let direction: ImageMergeCore.Direction =
            (args["direction"] as? String ?? "horizontal").lowercased() == "vertical"
                ? .vertical : .horizontal
        let gap = max(0, args["gap"] as? Double ?? 0)
        var sources: [CGImage] = []
        for path in paths {
            switch AgentWorkspace.shared.resolve(path, write: false) {
            case .granted(let url):
                guard let image = ImageTransforms.load(from: url) else {
                    return fail("Cannot read image at \(url.path)")
                }
                sources.append(image)
            case .denied(let reason): return reason
            }
        }
        guard let result = ImageMergeCore.merge(sources, direction: direction, gap: gap) else {
            return fail("Merge failed")
        }
        // 输出到第一张图同目录 Merged/
        guard let first = paths.first else { return fail("No paths") }
        let firstURL = AgentWorkspace.shared.resolve(first, write: false)
        let dir: URL
        if case .granted(let url) = firstURL {
            dir = url.deletingLastPathComponent()
                .appendingPathComponent("Merged", isDirectory: true)
        } else {
            dir = AgentWorkspace.shared.directory.appendingPathComponent("Merged",
                                                                        isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = dir.appendingPathComponent(
            "merged-\(Int(Date().timeIntervalSince1970)).png")
        do {
            try ImageTransforms.save(result.image, to: output)
        } catch {
            return fail("Write failed: \(error.localizedDescription)")
        }
        return String(localized: "Merged \(sources.count) image(s) → \(output.path) (\(Int(result.size.width)) × \(Int(result.size.height)) px).")
    }
}
