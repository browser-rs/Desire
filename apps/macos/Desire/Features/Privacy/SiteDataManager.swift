import Foundation
import WebKit

/// 站点数据管理 2.0（v0.8.25）：按站点 × 类型查看与清除。
///
/// 为什么不用"按保留天数清理"：WebKit 的记录级删除不带修改时间，按天数只能整库清
/// （会误伤登录态）；按站点点名 + 按类型删是可行且可预期的形态。
nonisolated struct SiteDataRecord: Sendable, Equatable {
    var displayName: String
    /// 归一化短名（cookies / cache / localStorage / indexeddb / …）。
    var types: [String]
}

@MainActor
enum SiteDataManager {
    static func records(in store: WKWebsiteDataStore? = nil) async -> [SiteDataRecord] {
        let store = store ?? .default()
        let all = WKWebsiteDataStore.allWebsiteDataTypes()
        let raw = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: all) { records in
                continuation.resume(returning: records)
            }
        }
        return raw.map {
            SiteDataRecord(displayName: $0.displayName,
                           types: $0.dataTypes.map(shortName).sorted())
        }
        .sorted { $0.displayName < $1.displayName }
    }

    /// 删除某站点的一类/全部数据；返回实际删除的数据类型数（0 = 没找到）。
    static func remove(_ displayName: String, types: [String]? = nil,
                       in store: WKWebsiteDataStore? = nil) async -> Int {
        let store = store ?? .default()
        let all = WKWebsiteDataStore.allWebsiteDataTypes()
        let raw = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: all) { records in
                continuation.resume(returning: records)
            }
        }
        guard let record = raw.first(where: { $0.displayName == displayName }) else { return 0 }
        let chosen: Set<String>
        if let types, !types.isEmpty {
            chosen = Set(types.compactMap(longName))
        } else {
            chosen = all
        }
        let toRemove = record.dataTypes.filter { chosen.contains($0) }
        guard !toRemove.isEmpty else { return 0 }
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: Set(toRemove), for: [record]) {
                continuation.resume()
            }
        }
        return toRemove.count
    }

    // MARK: - 类型短名

    static func shortName(_ type: String) -> String {
        switch type {
        case WKWebsiteDataTypeCookies: return "cookies"
        case WKWebsiteDataTypeDiskCache: return "cache"
        case WKWebsiteDataTypeMemoryCache: return "memory-cache"
        case WKWebsiteDataTypeLocalStorage: return "localstorage"
        case WKWebsiteDataTypeSessionStorage: return "sessionstorage"
        case WKWebsiteDataTypeIndexedDBDatabases: return "indexeddb"
        case WKWebsiteDataTypeWebSQLDatabases: return "websql"
        default: return type
        }
    }

    static func longName(_ short: String) -> String? {
        switch short.lowercased() {
        case "cookies": return WKWebsiteDataTypeCookies
        case "cache": return WKWebsiteDataTypeDiskCache
        case "memory-cache": return WKWebsiteDataTypeMemoryCache
        case "localstorage": return WKWebsiteDataTypeLocalStorage
        case "sessionstorage": return WKWebsiteDataTypeSessionStorage
        case "indexeddb": return WKWebsiteDataTypeIndexedDBDatabases
        case "websql": return WKWebsiteDataTypeWebSQLDatabases
        default: return nil
        }
    }
}
