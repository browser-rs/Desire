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
        let result = await BackgroundCommandStore.shared.start(
            tool: tool, args: commandArgs, title: title, cwd: cwd,
            timeoutMinutes: timeout, conversationID: conversationID,
            report: report)
        switch result {
        case .success(let id):
            return String(localized: "Background command started as job \(id.uuidString). It will keep running after this turn; use backgroundTaskStatus to check progress.")
        case .failure(let error):
            return fail(error.message)
        }
    }
}
