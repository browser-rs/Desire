import Foundation

/// 研究简报的 Agent 工具面（v0.8.50）：start / status / list / cancel /
/// export / toexcerpts。与桥端点共用 `ResearchBriefService` / `Store`。
extension BrowserToolProvider {

    static func researchBriefTool(_ args: [String: Any], conversationID: UUID?) -> String {
        let action = (args["action"] as? String ?? "start").lowercased()
        switch action {
        case "start":
            guard let topic = (args["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !topic.isEmpty else {
                return fail("Missing topic")
            }
            let depth = Int(args["depth"] as? Double ?? 6)
            let language = args["language"] as? String ?? "zh-Hans"
            let template = ResearchBriefTemplate(rawValue: args["template"] as? String ?? "summary") ?? .summary
            let seedURLs = (args["urls"] as? [String]) ?? []
            let document = ResearchBriefService.shared.start(
                topic: topic, depth: depth, language: language,
                template: template, seedURLs: seedURLs, conversationID: conversationID)
            return """
            Research brief started (id: \(document.id.uuidString)). It runs in the background \
            (Jobs ledger) without touching the user's tabs. Poll with researchBrief action=status \
            id=\(document.id.uuidString), or check backgroundTaskStatus.
            """
        case "status":
            guard let raw = args["id"] as? String, let id = UUID(uuidString: raw),
                  let document = ResearchBriefStore.shared.document(id: id) else {
                return fail("Unknown brief id")
            }
            var lines = [
                "Topic: \(document.topic)",
                "State: \(document.state.rawValue)",
                "Sources: \(document.sources.count) · unverified quotes: \(document.unverifiedQuotes) · dropped refs: \(document.droppedRefs)",
            ]
            if let path = document.deliverablePath { lines.append("File: \(path)") }
            if let error = document.error { lines.append("Error: \(error)") }
            lines.append("")
            lines.append(ResearchBriefCore.render(document))
            return lines.joined(separator: "\n")
        case "list":
            let briefs = ResearchBriefStore.shared.briefs
            guard !briefs.isEmpty else { return "No research briefs yet." }
            return briefs.map { document in
                "- \(document.id.uuidString) · \(document.state.rawValue) · \(document.topic) · \(document.sources.count) source(s)"
            }.joined(separator: "\n")
        case "cancel":
            guard let raw = args["id"] as? String, let id = UUID(uuidString: raw) else {
                return fail("Missing id")
            }
            ResearchBriefService.shared.cancel(id: id)
            return "Cancellation requested for \(raw)."
        case "export":
            guard let raw = args["id"] as? String, let id = UUID(uuidString: raw),
                  let document = ResearchBriefStore.shared.document(id: id) else {
                return fail("Unknown brief id")
            }
            guard let url = ResearchBriefStore.shared.exportToDownloads(document) else {
                return fail("Export failed")
            }
            return "Exported to \(url.path)"
        case "toexcerpts":
            guard let raw = args["id"] as? String, let id = UUID(uuidString: raw),
                  let document = ResearchBriefStore.shared.document(id: id) else {
                return fail("Unknown brief id")
            }
            var added = 0
            var seenSources = Set<Int>()
            for point in document.points where point.verified {
                guard seenSources.insert(point.sourceID).inserted else { continue }
                guard let source = document.sources.first(where: { $0.id == point.sourceID }) else { continue }
                if ExcerptStore.shared.add(kind: .webSelection,
                                           title: source.title,
                                           source: source.url,
                                           content: point.quote,
                                           note: point.point) {
                    added += 1
                }
            }
            return added > 0
                ? "Added \(added) quote(s) to Excerpts."
                : "No verified quotes to add."
        default:
            return fail("Unknown action \(action) — use start | status | list | cancel | export | toexcerpts")
        }
    }
}
