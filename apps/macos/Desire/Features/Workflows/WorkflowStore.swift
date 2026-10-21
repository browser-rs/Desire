import Combine
import Foundation

/// 工作流录制会话与本地库（v0.7.29）。录制发生在页面里（`workflow-recorder.js`），
/// 宿主只做策略：站点过滤、**敏感字段清空值**、步骤上限与落盘。
@MainActor
final class WorkflowStore: ObservableObject {
    static let shared = WorkflowStore()

    @Published private(set) var workflows: [Workflow] = []
    @Published private(set) var isRecording = false
    @Published private(set) var pendingSteps: [Workflow.Step] = []
    @Published private(set) var recordingHost: String?
    @Published private(set) var recordingStartURL: String?

    private static let key = "desire.workflows"
    private static let maxSteps = 200

    private init() { load() }

    // MARK: - 录制

    func startRecording(url: String) {
        guard let host = WorkflowLogic.host(of: url) else { return }
        isRecording = true
        recordingHost = host
        recordingStartURL = url
        pendingSteps = []
    }

    /// 返回被接受的步骤（nil = 忽略：未录制/异站/非法/超上限）。
    @discardableResult
    func recordEvent(_ body: [String: Any], tabURL: String) -> Workflow.Step? {
        guard isRecording, let scope = recordingHost else { return nil }
        guard let host = WorkflowLogic.host(of: tabURL),
              host == scope || host.hasSuffix("." + scope) else { return nil }
        guard pendingSteps.count < Self.maxSteps else { return nil }
        guard let type = body["type"] as? String else { return nil }

        let step: Workflow.Step
        switch type {
        case "navigate":
            guard let url = body["url"] as? String, !url.isEmpty else { return nil }
            if pendingSteps.isEmpty, url == recordingStartURL { return nil }
            if let last = pendingSteps.last, last.kind == .navigate, last.url == url { return nil }
            step = Workflow.Step(kind: .navigate, url: url, note: String(url.prefix(120)))
        case "click":
            let selectors = (body["selectors"] as? [String]) ?? []
            guard selectors.contains(where: WorkflowLogic.isValidSelector) else { return nil }
            let note = (body["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            step = Workflow.Step(kind: .click, selectors: selectors,
                                 note: (note?.isEmpty ?? true) ? nil : String(note!.prefix(80)))
        case "input", "select":
            let selectors = (body["selectors"] as? [String]) ?? []
            guard selectors.contains(where: WorkflowLogic.isValidSelector) else { return nil }
            let field = (body["field"] as? [String: Any]) ?? [:]
            let sensitive = WorkflowLogic.isSensitiveField(
                type: field["type"] as? String,
                autocomplete: field["autocomplete"] as? String,
                name: field["name"] as? String,
                id: field["id"] as? String,
                placeholder: field["placeholder"] as? String)
            let rawValue = body["value"] as? String ?? ""
            let note = (body["note"] as? String).map { String($0.prefix(80)) }
            step = Workflow.Step(kind: type == "select" ? .select : .input,
                                 selectors: selectors,
                                 value: sensitive ? nil : String(rawValue.prefix(500)),
                                 sensitive: sensitive,
                                 note: note)
        default:
            return nil
        }
        pendingSteps.append(step)
        return step
    }

    /// 停止并保存；返回新工作流（无步骤/未录制 → nil）。
    @discardableResult
    func stopRecording(name: String, now: Date = Date()) -> Workflow? {
        defer {
            isRecording = false
            pendingSteps = []
            recordingHost = nil
            recordingStartURL = nil
        }
        guard isRecording, let host = recordingHost,
              let startURL = recordingStartURL, !pendingSteps.isEmpty else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let workflow = Workflow(name: trimmed.isEmpty ? "Workflow \(workflows.count + 1)" : trimmed,
                                host: host,
                                startURL: startURL,
                                createdAt: now,
                                updatedAt: now,
                                steps: pendingSteps)
        workflows.insert(workflow, at: 0)
        save()
        return workflow
    }

    func cancelRecording() {
        isRecording = false
        pendingSteps = []
        recordingHost = nil
        recordingStartURL = nil
    }

    // MARK: - 库

    func workflows(forURL url: String) -> [Workflow] {
        workflows.filter { WorkflowLogic.matchesSite($0, url: url) }
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = workflows.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        workflows[index].name = trimmed
        workflows[index].updatedAt = Date()
        save()
    }

    func delete(_ id: UUID) {
        workflows.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([Workflow].self, from: data) else { return }
        workflows = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(workflows) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
