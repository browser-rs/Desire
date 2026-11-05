import Combine
import Foundation

/// 图片编辑预设（v0.8.41）：把当前调节参数（含曲线）存成命名预设，
/// 跨文档复用。DiskStore 单文件数组。
nonisolated struct ImageEditPreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var params: ImageAdjustParams
    var createdAt: Date
}

@MainActor
final class ImageEditPresetStore: ObservableObject {
    static let shared = ImageEditPresetStore()

    @Published private(set) var presets: [ImageEditPreset] = []

    private static let key = "imageEdit.presets"
    private static let cap = 40

    private init() {
        presets = (DiskStore.load([ImageEditPreset].self, key: Self.key) ?? [])
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func save(name: String, params: ImageAdjustParams) -> ImageEditPreset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let existing = presets.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        let preset = ImageEditPreset(
            id: existing?.id ?? UUID(),
            name: trimmed,
            params: ImageAdjustParams.clamped(params),
            createdAt: existing?.createdAt ?? Date())
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.insert(preset, at: 0)
        }
        if presets.count > Self.cap {
            presets.removeLast(presets.count - Self.cap)
        }
        persist()
        return preset
    }

    func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        DiskStore.save(presets, key: Self.key)
    }
}
