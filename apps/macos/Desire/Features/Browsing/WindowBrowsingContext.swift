import Combine
import Foundation
import WebKit

/// Window-owned browsing identity. The context is the migration seam between
/// the process-wide AppState and genuinely window-scoped browser state.
@MainActor
final class WindowBrowsingContext: ObservableObject {
    let windowID: UUID
    /// manager 唯一实例（init 建一次，不替换）——观察经下面的转发上达。
    let tabManager: TabManager
    private var managerObservation: AnyCancellable?

    @Published private(set) var profileID: UUID?
    var sessionKey: String? {
        get { tabManager.sessionKey }
        set { tabManager.sessionKey = newValue }
    }

    var profileDataStore: WKWebsiteDataStore {
        ProfileStore.shared.dataStore(for: profileID)
    }

    init(windowID: UUID? = nil, profileID: UUID? = nil) {
        self.windowID = windowID ?? UUID()
        let resolvedProfileID = profileID ?? ProfileStore.shared.activeProfileID
        self.profileID = resolvedProfileID
        let manager = TabManager()
        manager.profileID = resolvedProfileID
        manager.profileDataStore = ProfileStore.shared.dataStore(for: resolvedProfileID)
        self.tabManager = manager
        managerObservation = manager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func setProfile(_ id: UUID?) {
        profileID = id
        tabManager.profileID = id
        tabManager.profileDataStore = profileDataStore
    }
    
    /// 仅供观察链：manager 的变化经本 context 转发给 @ObservedObject windowContext。
    var objectWillChangeProxy: ObservableObjectPublisher { objectWillChange }
}
