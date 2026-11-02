import Combine
import Foundation

/// 流水线持久化（v0.8.38 A5）：单文件数组，量小无需分文件。
@MainActor
final class ToolboxPipelineStore: ObservableObject {
    static let shared = ToolboxPipelineStore()

    @Published private(set) var pipelines: [ToolboxPipeline] = []

    private static let storageKey = "toolbox.pipelines"

    private init() {
        pipelines = (DiskStore.load([ToolboxPipeline].self, key: Self.storageKey) ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    func save(_ pipeline: ToolboxPipeline) -> Bool {
        guard ToolboxPipelineCore.validationError(for: pipeline) == nil else { return false }
        var copy = pipeline
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.updatedAt = Date()
        if let index = pipelines.firstIndex(where: { $0.id == copy.id }) {
            pipelines[index] = copy
        } else {
            pipelines.insert(copy, at: 0)
        }
        pipelines.sort { $0.updatedAt > $1.updatedAt }
        persist()
        return true
    }

    func delete(_ id: UUID) {
        pipelines.removeAll { $0.id == id }
        persist()
    }

    func pipeline(_ id: UUID) -> ToolboxPipeline? {
        pipelines.first { $0.id == id }
    }

    private func persist() {
        DiskStore.save(pipelines, key: Self.storageKey)
    }
}
