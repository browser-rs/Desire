import Combine
import Foundation

@MainActor
class QuickDialStore: ObservableObject {
    @Published var dials: [QuickDial] = []
    private let storageKey = "desire.quickdials"
    /// Profile 作用域（0.3.5），模式同 BookmarkStore。
    private var scopeID: UUID?
    private var scopedKey: String {
        guard let scopeID else { return storageKey }
        return storageKey + "." + scopeID.uuidString
    }

    init() {
        load()
    }

    func add(title: String, url: String) {
        let dial = QuickDial(title: title, url: url)
        dials.append(dial)
        save()
    }

    func delete(id: UUID) {
        dials.removeAll { $0.id == id }
        save()
    }

    func update(id: UUID, title: String, url: String) {
        guard let index = dials.firstIndex(where: { $0.id == id }) else { return }
        dials[index].title = title
        dials[index].url = url
        save()
    }

    func move(from source: Int, to destination: Int) {
        guard dials.indices.contains(source), dials.indices.contains(destination) else { return }
        let moved = dials.remove(at: source)
        let insert = source < destination ? destination - 1 : destination
        dials.insert(moved, at: min(insert, dials.count))
        save()
    }

    private func load() {
        if let decoded = DiskStore.load([QuickDial].self, key: storageKey), !decoded.isEmpty {
            dials = decoded
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([QuickDial].self, from: data),
           !decoded.isEmpty {
            dials = decoded
            save()
            UserDefaults.standard.removeObject(forKey: storageKey)
            return
        }
        dials = defaultDials
    }

    private func save() {
        DiskStore.save(dials, key: scopedKey)
    }

    /// AppState.applyProfile 驱动（0.3.5）。新桶为空回退默认快拨。
    func applyScope(profileID: UUID?) {
        guard scopeID != profileID else { return }
        save()
        scopeID = profileID
        dials = DiskStore.load([QuickDial].self, key: scopedKey) ?? defaultDials
    }
}
