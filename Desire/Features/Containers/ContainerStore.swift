import Combine
import Foundation
import WebKit

/// Owns tab containers and their persistent website data stores.
///
/// Each container maps to `WKWebsiteDataStore(forIdentifier:)` keyed by the
/// container's UUID — cookies, sessions, and site storage are fully isolated
/// per container and persist across launches. The singleton keeps resolved
/// data stores cached so repeated tab creations don't re-query WebKit.
@MainActor
class ContainerStore: ObservableObject {
    static let shared = ContainerStore()

    @Published private(set) var containers: [TabContainer] = []

    private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    private let storageKey = "tab-containers"

    private init() {
        containers = DiskStore.load([TabContainer].self, key: storageKey) ?? []
    }

    func container(for id: UUID?) -> TabContainer? {
        guard let id else { return nil }
        return containers.first(where: { $0.id == id })
    }

    /// The persistent data store for a container, or nil for `nil`/unknown
    /// ids (callers then use the default store).
    func dataStore(for id: UUID?) -> WKWebsiteDataStore? {
        guard let id, containers.contains(where: { $0.id == id }) else { return nil }
        if let cached = dataStores[id] { return cached }
        let store = WKWebsiteDataStore(forIdentifier: id)
        dataStores[id] = store
        return store
    }

    @discardableResult
    func addContainer(name: String) -> TabContainer {
        let container = TabContainer(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            colorIndex: containers.count % TabContainer.palette.count
        )
        containers.append(container)
        save()
        return container
    }

    /// Removes the container from the list. The underlying website data store
    /// is intentionally NOT wiped here — tabs may still be using it; use
    /// `purgeData(for:)` to wipe a container's data explicitly.
    func removeContainer(_ id: UUID) {
        containers.removeAll { $0.id == id }
        dataStores[id] = nil
        save()
    }

    /// Wipes ALL website data of a container (cookies, storage, caches).
    /// Every site logged into through this container will sign out.
    func purgeData(for id: UUID) async {
        guard let store = dataStore(for: id) else { return }
        let types: Set<String> = [
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeServiceWorkerRegistrations,
        ]
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    private func save() {
        DiskStore.save(containers, key: storageKey)
    }
}
