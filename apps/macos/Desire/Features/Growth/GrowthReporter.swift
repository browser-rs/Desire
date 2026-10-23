import Foundation

/// 匿名增长事件发送（v0.8.3）：只发事件名 + UTM/版本/路径；不发 IP/Cookie/设备标识。
/// 失败静默（归因是旁路，不影响任何用户操作）。
nonisolated enum GrowthEventClient {
    struct Event: Codable {
        var event: String
        var source: String
        var medium: String
        var campaign: String
        var content: String
        var path: String
        var app_version: String
    }

    /// 返回是否被服务端接受（2xx）。网络失败/未部署返回 false。
    @discardableResult
    static func send(baseURL: String, event: String,
                     source: String = "", medium: String = "",
                     campaign: String = "", content: String = "",
                     path: String = "", appVersion: String = "") async -> Bool {
        let trimmedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedBase.isEmpty,
              let url = URL(string: trimmedBase + "/growth/event") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = Event(event: event, source: source, medium: medium,
                            campaign: campaign, content: content,
                            path: path, app_version: appVersion)
        request.httpBody = try? JSONEncoder().encode(payload)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}

/// 首启上报（v0.8.3）：只在第一次成功上报后写标记；用户可在归因面板关闭。
@MainActor
final class GrowthReporter {
    static let shared = GrowthReporter()

    static let enabledKey = "growth.telemetryEnabled"
    private static let reportedKey = "growth.firstLaunchReported"

    private init() {}

    /// 默认开启；显式关掉后不再上报（产品页 beacon 有独立的 localStorage 关闭项）。
    var isEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Self.enabledKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    func reportFirstLaunchIfNeeded() {
        guard UserDefaults.standard.object(forKey: Self.reportedKey) == nil else { return }
        guard isEnabled else { return }
        let base = UserDefaults.standard.string(forKey: "sync.serverBaseURL")
            ?? SyncStore.defaultServerBaseURL
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        Task { @MainActor in
            // 一次尝试即写标记：服务未部署/离线时不每次启动都打一枪。
            _ = await GrowthEventClient.send(
                baseURL: base, event: "first_launch",
                source: "app", campaign: "install", appVersion: version)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.reportedKey)
        }
    }
}
