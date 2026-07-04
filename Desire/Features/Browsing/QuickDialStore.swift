import Combine
import Foundation

@MainActor
class QuickDialStore: ObservableObject {
    @Published var dials: [QuickDial] = []
    private let storageKey = "desire.quickdials"

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
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([QuickDial].self, from: data),
              !decoded.isEmpty else {
            dials = defaultDials
            return
        }
        dials = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(dials) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
