import Combine
import Foundation

@MainActor
class ResponsiveDesignStore: ObservableObject {
    @Published var allPresets: [DevicePreset] = devicePresets
    @Published var customPresets: [DevicePreset] = []

    private let saveKey = "desire.responsiveCustomPresets"

    init() {
        loadCustomPresets()
    }

    func presets(for category: DeviceCategory) -> [DevicePreset] {
        allPresets.filter { $0.category == category }
    }

    func devicePreset(for id: UUID) -> DevicePreset? {
        allPresets.first { $0.id == id }
    }

    func saveCustomPreset(_ preset: DevicePreset) {
        customPresets.append(preset)
        persistCustomPresets()
    }

    func deleteCustomPreset(_ preset: DevicePreset) {
        customPresets.removeAll { $0.id == preset.id }
        persistCustomPresets()
    }

    private func loadCustomPresets() {
        if let presets = DiskStore.load([DevicePreset].self, key: saveKey) {
            customPresets = presets
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let presets = try? JSONDecoder().decode([DevicePreset].self, from: data) {
            customPresets = presets
            persistCustomPresets()
            UserDefaults.standard.removeObject(forKey: saveKey)
        }
    }

    private func persistCustomPresets() {
        DiskStore.save(customPresets, key: saveKey)
    }
}
