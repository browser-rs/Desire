import Combine
import Foundation

@MainActor
final class JobTemplateStore: ObservableObject {
    static let shared = JobTemplateStore()

    @Published private(set) var templates: [JobTemplate] = []

    private static let key = "jobs.templates"
    private static let cap = 50

    private init() {
        templates = (DiskStore.load([JobTemplate].self, key: Self.key) ?? [])
            .sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ template: JobTemplate) -> Bool {
        guard JobTemplateValidation.error(
            name: template.name, tool: template.tool, args: template.args) == nil
        else { return false }
        var copy = template
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.tool = copy.tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let index = templates.firstIndex(where: { $0.id == copy.id }) {
            templates[index] = copy
        } else {
            templates.insert(copy, at: 0)
        }
        if templates.count > Self.cap { templates.removeLast(templates.count - Self.cap) }
        persist()
        return true
    }

    func template(named name: String) -> JobTemplate? {
        templates.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func delete(_ id: UUID) {
        templates.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        DiskStore.save(templates, key: Self.key)
    }
}
