import Combine
import Foundation
import WebKit

@MainActor
class CookieStore: ObservableObject {
    @Published var cookies: [CookieEntry] = []
    @Published var searchQuery = ""
    @Published var isLoading = false

    private let dataStore = WKWebsiteDataStore.default()
    private var cookieMap: [UUID: HTTPCookie] = [:]

    var filteredCookies: [CookieEntry] {
        guard !searchQuery.isEmpty else { return cookies }
        let q = searchQuery.lowercased()
        return cookies.filter { $0.domain.lowercased().contains(q) || $0.name.lowercased().contains(q) }
    }

    var domains: [String] {
        let allDomains = Set(cookies.map(\.domain))
        guard !searchQuery.isEmpty else { return allDomains.sorted() }
        let q = searchQuery.lowercased()
        return allDomains.filter { $0.lowercased().contains(q) }.sorted()
    }

    func cookies(for domain: String) -> [CookieEntry] {
        guard !searchQuery.isEmpty else { return cookies.filter { $0.domain == domain } }
        let q = searchQuery.lowercased()
        return cookies.filter { $0.domain == domain && ($0.name.lowercased().contains(q) || $0.domain.lowercased().contains(q)) }
    }

    func refresh() {
        isLoading = true
        dataStore.httpCookieStore.getAllCookies { [weak self] httpCookies in
            guard let self else { return }
            let mapped: [(CookieEntry, HTTPCookie)] = httpCookies.map { httpCookie in
                let entry = CookieEntry(
                    domain: httpCookie.domain,
                    name: httpCookie.name,
                    value: httpCookie.value,
                    path: httpCookie.path,
                    expiryDate: httpCookie.expiresDate,
                    isSecure: httpCookie.isSecure,
                    isHttpOnly: httpCookie.isHTTPOnly,
                    sameSitePolicy: httpCookie.sameSitePolicy?.rawValue
                )
                return (entry, httpCookie)
            }
            Task { @MainActor in
                self.cookieMap.removeAll(keepingCapacity: true)
                self.cookies = mapped.map(\.0)
                for (entry, httpCookie) in mapped {
                    self.cookieMap[entry.id] = httpCookie
                }
                self.isLoading = false
            }
        }
    }

    func delete(_ entry: CookieEntry) {
        guard let httpCookie = cookieMap[entry.id] else {
            refresh()
            return
        }
        dataStore.httpCookieStore.delete(httpCookie) { [weak self] in
            Task { @MainActor in
                self?.cookies.removeAll { $0.id == entry.id }
                self?.cookieMap.removeValue(forKey: entry.id)
            }
        }
    }

    func deleteAll(for domain: String) {
        let toRemove = cookies.filter { $0.domain == domain }
        let group = DispatchGroup()
        for entry in toRemove {
            guard let httpCookie = cookieMap[entry.id] else { continue }
            group.enter()
            dataStore.httpCookieStore.delete(httpCookie) { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            Task { @MainActor in
                self?.cookies.removeAll { $0.domain == domain }
                toRemove.forEach { self?.cookieMap.removeValue(forKey: $0.id) }
            }
        }
    }

    func clearAll() {
        let types: Set = [WKWebsiteDataTypeCookies]
        dataStore.removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            Task { @MainActor in
                self?.cookies.removeAll()
                self?.cookieMap.removeAll()
            }
        }
    }
}
