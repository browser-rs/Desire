import Combine
import Foundation
import WebKit

/// Window-owned browsing identity. The context is the migration seam between
/// the process-wide AppState and genuinely window-scoped browser state.
@MainActor
final class WindowBrowsingContext: ObservableObject {
    let windowID: UUID
    let tabManager: TabManager

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
    }

    func setProfile(_ id: UUID?) {
        profileID = id
        tabManager.profileID = id
        tabManager.profileDataStore = profileDataStore
    }
}
