import Foundation
import WebKit

/// 登录态快照（v0.8.24）：把默认档案的 **cookies** 拷进某个容器。
///
/// 只迁 cookie：localStorage / IndexedDB / 扩展状态不在通用迁移范围内，部分站点
/// 仍会要求重登——UI 必须如实说明（与业界同类实现的边界一致）。
@MainActor
enum CookieSeeder {
    static func seed(into containerID: UUID) async -> Int {
        guard let target = ContainerStore.shared.dataStore(for: containerID)?.httpCookieStore else {
            return 0
        }
        let cookies = await allCookies(of: WKWebsiteDataStore.default().httpCookieStore)
        for cookie in cookies {
            await setCookie(cookie, on: target)
        }
        return cookies.count
    }

    private static func allCookies(of store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private static func setCookie(_ cookie: HTTPCookie, on store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) {
                continuation.resume()
            }
        }
    }
}
