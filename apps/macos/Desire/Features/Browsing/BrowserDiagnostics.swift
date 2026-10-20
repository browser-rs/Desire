import Combine
import Foundation

/// 内容进程崩溃的持久诊断（v0.7.28）：此前只在日志里留一行、崩溃/自动重载
/// 是否发生完全不可查。这里只记**计数与最近 20 次**（URL/时间/是否自动重载），
/// 不含页面内容——设置页与桥 `/diag/browser` 共用。
@MainActor
final class BrowserDiagnostics: ObservableObject {
    static let shared = BrowserDiagnostics()

    struct CrashRecord: Codable, Identifiable, Equatable {
        var id = UUID()
        var url: String
        var at: Date
        var autoReloaded: Bool
    }

    @Published private(set) var recentCrashes: [CrashRecord] = []
    @Published private(set) var totalCrashes: Int = 0

    private static let recentKey = "diag.contentCrashes.recent"
    private static let totalKey = "diag.contentCrashes.total"
    private static let cap = 20

    private init() { load() }

    func recordContentProcessCrash(url: String, autoReloaded: Bool) {
        totalCrashes += 1
        recentCrashes.insert(CrashRecord(url: url, at: Date(), autoReloaded: autoReloaded), at: 0)
        if recentCrashes.count > Self.cap { recentCrashes.removeLast(recentCrashes.count - Self.cap) }
        save()
    }

    func reset() {
        totalCrashes = 0
        recentCrashes = []
        save()
    }

    /// 桥/设置页共用的可序列化摘要。
    func summary() -> [String: Any] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return [
            "ok": true,
            "appVersion": version,
            "totalCrashes": totalCrashes,
            "recent": recentCrashes.map {
                ["url": $0.url,
                 "at": $0.at.timeIntervalSince1970,
                 "autoReloaded": $0.autoReloaded] as [String: Any]
            },
        ]
    }

    private func load() {
        totalCrashes = UserDefaults.standard.integer(forKey: Self.totalKey)
        if let data = UserDefaults.standard.data(forKey: Self.recentKey),
           let decoded = try? JSONDecoder().decode([CrashRecord].self, from: data) {
            recentCrashes = Array(decoded.prefix(Self.cap))
        }
    }

    private func save() {
        UserDefaults.standard.set(totalCrashes, forKey: Self.totalKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(recentCrashes), forKey: Self.recentKey)
    }
}
