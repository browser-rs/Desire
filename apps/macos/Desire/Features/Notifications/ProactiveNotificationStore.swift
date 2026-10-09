import Combine
import Foundation
import os
@preconcurrency import UserNotifications

/// 主动通知的收口（2026-10-09）：urgent 永远直推；routine 过「免打扰时段 +
/// 每日预算」闸——扣下的合并成一条摘要，免打扰结束（60s 定时器检查）或桥
/// flush 时补推。授权保持 TCC 懒请求约定（只在真正要发时请求）。
///
/// 摘要队列只在内存（免打扰中重启的极少场景下丢失，可接受）；预算计数按
/// 日期落 UserDefaults。
@MainActor
final class ProactiveNotificationStore: ObservableObject {
    static let shared = ProactiveNotificationStore()

    @Published var policy: NotificationPolicy {
        didSet {
            guard policy != oldValue else { return }
            if let data = try? JSONEncoder().encode(policy) {
                UserDefaults.standard.set(data, forKey: "proactiveNotificationPolicy")
            }
        }
    }
    /// 被扣下的 routine 通知（摘要素材，最旧先弃）。
    @Published private(set) var heldLines: [String] = []
    /// 今天已直推的 routine 条数（预算依据）。
    @Published private(set) var routineDeliveredToday: Int = 0

    private static let heldLinesCap = 30
    private var flushTimer: Timer?

    init() {
        if let data = UserDefaults.standard.data(forKey: "proactiveNotificationPolicy"),
           let decoded = try? JSONDecoder().decode(NotificationPolicy.self, from: data) {
            policy = decoded
        } else {
            policy = NotificationPolicy()
        }
        rollDayIfNeeded()
        // 免打扰结束后主动补推摘要：每次 deliver 里也顺手 flush（幂等），
        // 定时器兜"结束后再没有新通知"的场景。
        flushTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushDigest()
            }
        }
    }

    // MARK: - 入口

    func deliver(title: String, body: String, tier: NotificationTier) {
        switch tier {
        case .urgent:
            deliverNow(title: title, body: body)
        case .routine:
            rollDayIfNeeded()
            if policy.shouldHoldRoutine(sentToday: routineDeliveredToday,
                                        minutesSinceMidnight: Self.minutesNow()) {
                hold(title: title, body: body)
            } else {
                routineDeliveredToday += 1
                UserDefaults.standard.set(routineDeliveredToday, forKey: "notificationCountValue")
                deliverNow(title: title, body: body)
            }
        }
    }

    /// 补推摘要。force=false 只在非免打扰时段执行（定时器路径）；force=true
    /// 无条件推（桥手动 flush）。返回本条摘要覆盖的条数（0 = 没有积压）。
    @discardableResult
    func flushDigest(force: Bool = false) -> Int {
        guard !heldLines.isEmpty else { return 0 }
        if !force && policy.isQuietTime(minutesSinceMidnight: Self.minutesNow()) { return 0 }
        let plan = NotificationPolicy.digestPlan(lines: heldLines)
        var body = plan.included.map { "• " + $0 }.joined(separator: "\n")
        if plan.extraCount > 0 {
            body += "\n" + String(localized: "…and \(plan.extraCount) more")
        }
        deliverNow(title: String(localized: "Notification Digest"), body: body)
        heldLines.removeAll()
        return plan.included.count + plan.extraCount
    }

    // MARK: - 内部

    private func hold(title: String, body: String) {
        heldLines.append("\(title): \(body)")
        if heldLines.count > Self.heldLinesCap {
            heldLines.removeFirst(heldLines.count - Self.heldLinesCap)
        }
    }

    /// 跨天时清零当日预算计数（deliver 路径幂等调用）。
    private func rollDayIfNeeded() {
        let today = Self.dayKey(Date())
        if UserDefaults.standard.string(forKey: "notificationCountDay") == today {
            routineDeliveredToday = UserDefaults.standard.integer(forKey: "notificationCountValue")
        } else {
            routineDeliveredToday = 0
            UserDefaults.standard.set(today, forKey: "notificationCountDay")
            UserDefaults.standard.set(0, forKey: "notificationCountValue")
        }
    }

    private func deliverNow(title: String, body: String) {
        // 不把 UNUserNotificationCenter 捕获进 @Sendable 回调——需要时各自取 .current()。
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                Self.post(title: title, body: body)
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
                    guard granted else { return }
                    Self.post(title: title, body: body)
                }
            default:
                break
            }
        }
    }

    private nonisolated static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // 深链标记：点击由 NotificationRouter 接住（激活应用并确保面板打开）。
        content.userInfo = ["deepLink": "agent"]
        center.add(UNNotificationRequest(
            identifier: "desire.agent.\(UUID().uuidString)", content: content, trigger: nil))
    }

    private static func minutesNow() -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    private static func dayKey(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}
