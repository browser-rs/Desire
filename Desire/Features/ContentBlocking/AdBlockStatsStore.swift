import Combine
import Foundation

/// 广告拦截统计（聚合层）。
///
/// 数据源与口径（诚实边界）：**只有内置视频广告规则**（按站点 JS 移除/跳过/
/// 快进/首击防护）会上报逐次拦截事件——`videoAdBlocked` 消息经
/// ContentView+WebViewFactory 的钩子进入 `record`。EasyList / 社区过滤列表
/// 由 WebKit 引擎在进程内执行，公开 API 没有"每条规则命中"回调，因此面板
/// 的规则库存另行展示、不进入事件计数。
///
/// 聚合落盘（DiskStore 防抖异步写）：累计 / 今日（按本地日期滚动）/ 分站点
/// 计数（上限 60 站）/ 最近事件（上限 100 条）。
@MainActor
final class AdBlockStatsStore: ObservableObject {
    static let shared = AdBlockStatsStore()

    struct BlockedEvent: Codable, Identifiable, Equatable {
        let id: UUID
        let at: Date
        /// 站点 key（内置规则名如 youtube，或首击防护上报的域名）。
        let site: String
        let count: Int
        let action: String
    }

    private struct Persisted: Codable {
        var total: Int = 0
        var todayCount: Int = 0
        var todayKey: String = ""
        var perDomain: [String: Int] = [:]
        var recent: [BlockedEvent] = []
    }

    @Published private(set) var total: Int = 0
    @Published private(set) var todayCount: Int = 0
    @Published private(set) var todayKey: String = AdBlockStatsStore.dayKey(Date())
    @Published private(set) var perDomain: [String: Int] = [:]
    @Published private(set) var recent: [BlockedEvent] = []

    private static let storageKey = "ad-block-stats"
    private static let maxDomains = 60
    private static let maxRecent = 100

    private init() {
        if let persisted: Persisted = DiskStore.load(Persisted.self, key: Self.storageKey) {
            total = persisted.total
            todayCount = persisted.todayCount
            todayKey = persisted.todayKey
            perDomain = persisted.perDomain
            recent = persisted.recent
            rollDayIfNeeded()
        }
    }

    /// 记录一次拦截上报。count 来自页面脚本的单页计数（可能 >1）。
    func record(count: Int, site: String?, action: String?) {
        let n = max(1, count)
        rollDayIfNeeded()
        total += n
        todayCount += n
        let key = (site?.isEmpty == false) ? site! : "unknown"
        perDomain[key, default: 0] += n
        if perDomain.count > Self.maxDomains {
            // 挤掉计数最小的**非 other** 站，其计数并入 other（总量守恒）；
            // other 自己不做驱逐目标（自并合并不减键数，此前 map 超上限且
            // 平局时反复自并）。
            if let smallest = perDomain
                .filter({ $0.key != "other" })
                .min(by: { $0.value < $1.value })?.key {
                let moved = perDomain.removeValue(forKey: smallest) ?? 0
                perDomain["other", default: 0] += moved
            } else if perDomain.count > Self.maxDomains {
                perDomain.removeValue(forKey: key)
            }
        }
        recent.insert(
            BlockedEvent(id: UUID(), at: Date(), site: key, count: n, action: action ?? ""),
            at: 0
        )
        if recent.count > Self.maxRecent {
            recent.removeLast(recent.count - Self.maxRecent)
        }
        persist()
    }

    func clear() {
        total = 0
        todayCount = 0
        perDomain = [:]
        recent = []
        persist()
    }

    /// 读取前先滚动日期（面板/桥端点入口调用）：过了本地零点但还没发生
    /// 新拦截事件时，todayCount 仍停在昨天——读取即归位。
    func rollDay() {
        rollDayIfNeeded()
    }

    /// 跨过本地零点：昨日计数归零，累计保留。
    private func rollDayIfNeeded() {
        let key = Self.dayKey(Date())
        if key != todayKey {
            todayKey = key
            todayCount = 0
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func persist() {
        DiskStore.save(
            Persisted(
                total: total, todayCount: todayCount, todayKey: todayKey,
                perDomain: perDomain, recent: recent
            ),
            key: Self.storageKey
        )
    }

    /// 站点显示名（与 toast 的映射一致；面板与工具提示共用）。
    static func displayName(forSite key: String) -> String {
        switch key {
        case "youtube": "YouTube"
        case "bilibili": "Bilibili"
        case "tencent": String(localized: "腾讯视频")
        case "iqiyi": String(localized: "爱奇艺")
        case "youku": String(localized: "优酷")
        case "mgtv": String(localized: "芒果TV")
        case "tiktok": "TikTok"
        case "twitter": "X"
        case "unknown": String(localized: "视频")
        default: key
        }
    }
}
