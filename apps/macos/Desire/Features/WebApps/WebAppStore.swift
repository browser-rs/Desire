import Combine
import Foundation
import WebKit

/// Web Apps 列表 + 每个应用的独立数据仓（v0.8.0）。
///
/// 存储走 DiskStore（500ms 防抖）；`dataStore(for:)` 对独立应用用
/// `WKWebsiteDataStore(forIdentifier:)`，卸载时清空其数据。共享登录的应用
/// 复用主浏览器默认 data store。
@MainActor
final class WebAppStore: ObservableObject {
    static let shared = WebAppStore()

    @Published private(set) var apps: [WebApp] = []
    private let storageKey = "desire.webapps"
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]

    private init() {
        apps = DiskStore.load([WebApp].self, key: storageKey) ?? []
    }

    @discardableResult
    func add(url: URL, name: String?, shareSession: Bool) -> WebApp? {
        guard let app = WebApp.make(url: url, name: name, shareSession: shareSession) else {
            return nil
        }
        if let existing = apps.first(where: { $0.startURL == app.startURL }) {
            return existing
        }
        apps.append(app)
        save()
        return app
    }

    func remove(_ app: WebApp) {
        apps.removeAll { $0.id == app.id }
        save()
        guard !app.shareSession else { return }
        let store = dataStore(for: app)
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                         modifiedSince: .distantPast) { [weak self] in
            Task { @MainActor in self?.dataStores.removeValue(forKey: app.id) }
        }
    }

    func dataStore(for app: WebApp) -> WKWebsiteDataStore {
        if app.shareSession { return .default() }
        if let cached = dataStores[app.id] { return cached }
        let store = WKWebsiteDataStore(forIdentifier: app.id)
        dataStores[app.id] = store
        return store
    }

    func app(id: UUID) -> WebApp? {
        apps.first { $0.id == id }
    }

    /// 记录上次停留页（v0.8.1）：同域才记，避免登录跳转把一次性地址留成
    /// 恢复点。didFinish 时调用。
    func recordVisit(id: UUID, url: String?) {
        guard let url, !url.isEmpty,
              let idx = apps.firstIndex(where: { $0.id == id }) else { return }
        guard let host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return }
        let scope = apps[idx].host.lowercased()
        guard host == scope || host.hasSuffix("." + scope) else { return }
        apps[idx].lastVisitedAt = Date()
        if apps[idx].lastURL != url { apps[idx].lastURL = url }
        save()
    }

    /// 清掉恢复点（管理器「Open Start Page」用）。
    func clearLastVisit(id: UUID) {
        guard let idx = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[idx].lastURL = nil
        apps[idx].lastVisitedAt = nil
        save()
    }

    private func save() {
        DiskStore.save(apps, key: storageKey)
    }
}
