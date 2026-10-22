import Combine
import Foundation
import os
import WebKit

/// Store + engine for page watches (0.1.10). A 20 s clock fires due
/// watches; each check loads the URL in an offscreen webview, extracts
/// normalized text, and diffs it against the previous snapshot. Changes
/// update the watch, post a system notification, and publish a
/// `pageWatchChanged` bridge event.
@MainActor
final class PageWatchStore: ObservableObject {
    static let shared = PageWatchStore()

    @Published private(set) var watches: [PageWatch] = []
    @Published private(set) var isChecking = false
    /// 每日摘要（v0.8.1）：到点把 24h 内变化/告警/错误汇总成一条通知。
    /// 由设置页或桥修改；跨启动记忆"今天已发过"。
    @Published var digestEnabled: Bool {
        didSet { defaults.set(digestEnabled, forKey: Self.digestEnabledKey) }
    }
    @Published var digestHour: Int {
        didSet { defaults.set(digestHour, forKey: Self.digestHourKey) }
    }

    private let defaults = UserDefaults.standard
    private static let digestEnabledKey = "pageWatch.digest.enabled"
    private static let digestHourKey = "pageWatch.digest.hour"
    private static let lastDigestDayKey = "pageWatch.digest.lastDay"

    private var clock: Timer?
    private var offscreenWebView: WKWebView?
    private static let log = Log.agent
    private static let storageKey = "page-watches"
    private static let maxTextLength = 20_000

    private init() {
        digestEnabled = UserDefaults.standard.object(forKey: Self.digestEnabledKey) as? Bool ?? false
        let storedHour = UserDefaults.standard.object(forKey: Self.digestHourKey) as? Int ?? 9
        digestHour = min(23, max(0, storedHour))
        watches = DiskStore.load([PageWatch].self, key: Self.storageKey) ?? []
        startClock()
    }

    private func startClock() {
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
    }

    // MARK: - Management

    @discardableResult
    func add(name: String, url: String, selector: String?, minutes: Int,
             aiAnalysis: Bool = false,
             numericSelector: String? = nil,
             alertAbove: Double? = nil,
             alertBelow: Double? = nil) -> PageWatch? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty, let parsed = URL(string: trimmedURL) else { return nil }
        var watch = PageWatch(
            id: UUID(), name: trimmedName, url: parsed.absoluteString,
            selector: selector?.isEmpty == true ? nil : selector,
            intervalMinutes: max(5, minutes), isEnabled: true, createdAt: Date(),
            lastCheckedAt: nil, lastChangedAt: nil, previousText: nil,
            changeCount: 0, lastError: nil, aiAnalysis: aiAnalysis
        )
        let trimmedNumeric = numericSelector?.trimmingCharacters(in: .whitespaces)
        watch.numericSelector = (trimmedNumeric?.isEmpty == true) ? nil : trimmedNumeric
        watch.alertAbove = alertAbove
        watch.alertBelow = alertBelow
        watches.append(watch)
        save()
        return watch
    }

    /// 设置子页/桥：开关智能分析。
    func setAIAnalysis(_ enabled: Bool, for name: String) {
        guard let idx = watches.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else { return }
        watches[idx].aiAnalysis = enabled
        save()
    }

    func remove(named name: String) -> Bool {
        let before = watches.count
        watches.removeAll { $0.name.lowercased() == name.lowercased() }
        let removed = watches.count < before
        if removed { save() }
        return removed
    }

    func setEnabled(_ enabled: Bool, for name: String) {
        guard let idx = watches.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else { return }
        watches[idx].isEnabled = enabled
        save()
    }

    func find(named name: String) -> PageWatch? {
        watches.first { $0.name.lowercased() == name.lowercased() }
    }

    private func save() {
        DiskStore.save(watches, key: Self.storageKey)
    }

    // MARK: - Daily digest

    /// 设置页/桥：开关每日摘要并可选改小时（0–23）。
    func setDigest(enabled: Bool, hour: Int? = nil) {
        digestEnabled = enabled
        if let hour { digestHour = min(23, max(0, hour)) }
    }

    private var lastDigestDay: String? {
        get { defaults.string(forKey: Self.lastDigestDayKey) }
        set { defaults.set(newValue, forKey: Self.lastDigestDayKey) }
    }

    /// 每个时钟 tick 调一次：到点且今天未发过 → 把 24h 摘要作为 routine
    /// 通知投递（免打扰/预算照旧由通知策略收口）。**无变化不发**，但仍记
    /// “今天已处理”，避免每 20 秒重复判断。
    private func maybeDeliverDailyDigest(now: Date = Date()) {
        guard digestEnabled else { return }
        guard Calendar.current.component(.hour, from: now) >= digestHour else { return }
        let today = Self.dayKey(now)
        guard lastDigestDay != today else { return }
        lastDigestDay = today
        let summary = PageWatchDigest.make(watches: watches, now: now)
        guard summary.changed > 0 || summary.alerts > 0 || summary.errors > 0 else {
            Self.log.info("page watch daily digest: nothing to report")
            return
        }
        ProactiveNotificationStore.shared.deliver(
            title: String(localized: "Page Watch daily digest"),
            body: summary.text,
            tier: .routine)
        Self.log.info("page watch daily digest delivered: \(summary.changed) changed, \(summary.alerts) alerts, \(summary.errors) errors")
    }

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Checks

    /// Fires every due, enabled watch — serialized (the offscreen webview
    /// is shared).
    private func evaluate() {
        maybeDeliverDailyDigest()
        guard !isChecking else { return }
        for idx in watches.indices where watches[idx].isEnabled {
            let watch = watches[idx]
            let last = watch.lastCheckedAt ?? watch.createdAt
            let due = Date().timeIntervalSince(last) >= Double(watch.intervalMinutes) * 60
            if due {
                Task { [weak self] in
                    _ = await self?.check(named: watch.name)
                }
                return // one check per clock tick; the rest run next tick
            }
        }
    }

    /// Forces a check now. Returns whether the content CHANGED relative to
    /// the previous snapshot (first check establishes the baseline).
    @discardableResult
    func check(named name: String) async -> Bool {
        guard let idx = watches.firstIndex(where: { $0.name.lowercased() == name.lowercased() }),
              watches[idx].isEnabled else { return false }
        guard !isChecking else {
            Self.log.info("page watch: check skipped, another check is running")
            return false
        }
        isChecking = true
        defer { isChecking = false }

        // P1-6：await 前捕获 watch 快照与 id——检查最长 ~12s，期间增删会令
        // idx 失配（写穿到别的 watch，越界即崩）。写回全部按 id 定位；id 消失
        // = 该 watch 已被删，丢弃本次结果。
        let watch = watches[idx]
        let watchID = watch.id
        do {
            let pair = try await fetchTexts(url: URL(string: watch.url)!,
                                            selector: watch.selector,
                                            numericSelector: watch.numericSelector)
            let text = pair.text
            let normalized = normalize(text)
            guard let cur = watches.firstIndex(where: { $0.id == watchID }) else {
                Self.log.info("page watch '\(watch.name, privacy: .public)' removed during check — discarding result")
                return false
            }
            watches[cur].lastCheckedAt = Date()
            watches[cur].lastError = nil

            let baseline = watch.previousText
            let changed = baseline != nil && baseline != normalized
            if changed {
                watches[cur].changeCount += 1
                watches[cur].lastChangedAt = Date()
                watches[cur].previousText = String(normalized.prefix(Self.maxTextLength))
                let diff = "chars \(baseline?.count ?? 0) → \(normalized.count)"
                save()
                notifyChange(watch: watches[cur], diff: diff)
                BridgeEventBus.shared.publish("pageWatchChanged", [
                    "name": watches[cur].name,
                    "url": watches[cur].url,
                    "changeCount": watches[cur].changeCount,
                    "diff": diff,
                ])
                // v0.7.5 智能监视：opt-in 的 AI 分析（后台静默回合，结果写回
                // lastAnalysis 并补发带分析的通知）。
                if watches[cur].wantsAIAnalysis {
                    let oldText = baseline ?? ""
                    let name = watches[cur].name
                    let url = watches[cur].url
                    Task { @MainActor [weak self] in
                        await self?.runAnalysis(watchID: watchID, name: name, url: url,
                                                oldText: oldText, newText: normalized)
                    }
                }
            } else if baseline == nil {
                watches[cur].previousText = String(normalized.prefix(Self.maxTextLength))
                save()
            } else {
                save()
            }

            // 数值盯梢（v0.7.18）：无论文本是否变化都记一笔（封顶 60）；
            // 跨阈值只在**穿越**那一刻告警一次（与 diff 通知同一分级管线）。
            if watch.watchesNumbers {
                if let numericText = pair.numeric, let value = NumericWatch.parseValue(from: numericText) {
                    let point = PageWatch.ValuePoint(at: Date(), value: value)
                    watches[cur].valueHistory = NumericWatch.appendCap(watches[cur].valueHistory ?? [], point)
                    if let alert = NumericWatch.crossingAlert(previous: watch.latestValue, new: value,
                                                              above: watch.alertAbove, below: watch.alertBelow) {
                        watches[cur].lastAlert = NumericWatch.alertText(alert, value: value)
                        watches[cur].lastAlertAt = Date()
                        notifyNumericAlert(watch: watches[cur], value: value)
                        BridgeEventBus.shared.publish("pageWatchNumericAlert", [
                            "name": watches[cur].name,
                            "url": watches[cur].url,
                            "value": value,
                            "alert": watches[cur].lastAlert ?? "",
                        ])
                    }
                    save()
                } else if let numericSelector = watch.numericSelector {
                    watches[cur].lastError = "numeric selector not found: \(numericSelector)"
                    save()
                }
            }
            return changed
        } catch {
            guard let cur = watches.firstIndex(where: { $0.id == watchID }) else { return false }
            watches[cur].lastCheckedAt = Date()
            watches[cur].lastError = error.localizedDescription
            save()
            Self.log.error("page watch '\(watch.name, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Whitespace-collapsed comparison key.
    private func normalize(_ text: String) -> String {
        // 噪声过滤（0.8.1）：时间戳/相对时间/计数不参与 diff，避免
        // “每 20 秒都变”的假更新（见 PageWatchNoise）。
        PageWatchNoise.normalize(text)
    }

    // MARK: - Offscreen fetch

    private func offscreenWebview() -> WKWebView {
        if let offscreenWebView { return offscreenWebView }
        let webview = WKWebView(frame: .zero)
        self.offscreenWebView = webview
        return webview
    }

    private func fetchText(url: URL, selector: String?) async throws -> String {
        let pair = try await fetchTexts(url: url, selector: selector, numericSelector: nil)
        return pair.text
    }

    /// 一把加载、两路取文（v0.7.18 数值盯梢：diff 文本 + 数值文本共用一次
    /// 离屏装载，别为盯一个价格把页面加载两遍）。数值选择器未命中返回
    /// numeric=nil（不炸整次检查；调用侧记 lastError）。
    private func fetchTexts(url: URL, selector: String?, numericSelector: String?) async throws -> (text: String, numeric: String?) {
        let webview = offscreenWebview()
        webview.load(URLRequest(url: url))
        // Poll isLoading: up to 12 s.
        for _ in 0..<120 {
            if !webview.isLoading { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(300)) // let late JS render
        func selectorLiteral(_ raw: String) -> String {
            raw.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        }
        let textExpr: String
        if let selector, !selector.isEmpty {
            textExpr = "(function(){var el=document.querySelector('\(selectorLiteral(selector))');return el?(el.innerText||el.textContent||''):'__NO_MATCH__';})()"
        } else {
            textExpr = "(document.body ? document.body.innerText : '')"
        }
        let numericExpr: String
        if let numericSelector, !numericSelector.isEmpty {
            numericExpr = "(function(){var el=document.querySelector('\(selectorLiteral(numericSelector))');return el?(el.innerText||el.textContent||''):null;})()"
        } else {
            numericExpr = "null"
        }
        let js = """
        (function(){
          return JSON.stringify({ text: \(textExpr), numeric: \(numericExpr) });
        })()
        """
        let raw: Any = await withCheckedContinuation { continuation in
            webview.evaluateJavaScript(js) { value, _ in
                continuation.resume(returning: value ?? "")
            }
        }
        guard let rawString = raw as? String,
              let data = rawString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WatchError.selectorNotFound(selector ?? "")
        }
        let text = (object["text"] as? String) ?? ""
        if text == "__NO_MATCH__" {
            throw WatchError.selectorNotFound(selector ?? "")
        }
        return (text, object["numeric"] as? String)
    }

    enum WatchError: LocalizedError {
        case selectorNotFound(String)
        var errorDescription: String? {
            switch self {
            case .selectorNotFound(let selector): return "selector not found: \(selector)"
            }
        }
    }

    // MARK: - AI 分析（v0.7.5 智能监视）

    /// 变化发生 → 提取变化片段 → 静默 agent 回合分析 → 写回 lastAnalysis
    /// 并补发带分析的通知。回合走 deliverScheduled（自动排队，不打断进行中
    /// 的用户回合），完成 hook 里按 id 写回（期间可能被删）。
    private func runAnalysis(watchID: UUID, name: String, url: String,
                             oldText: String, newText: String) async {
        guard let target = AgentScheduler.shared.deliveryTarget else { return }
        guard let idx = watches.firstIndex(where: { $0.id == watchID }) else { return }
        watches[idx].lastAnalysis = "分析中…"
        save()

        let region = PageWatchDiff.extractChangedRegion(old: oldText, new: newText, context: 240)
        let clipped = region.count > 1500 ? "\(region.prefix(1500))…[truncated]" : region
        let prompt = """
        页面「\(name)」（\(url)）的内容监测器捕获到以下变化片段：

        \(clipped)

        请用不超过三句话说明这次变化的内容，并在最后单独一行给出结论：值得关注 或 仅例行更新。
        """
        target.deliverScheduled(prompt, from: "PageWatch · \(name)") { [weak self] outcome in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let idx = self.watches.firstIndex(where: { $0.id == watchID }) else { return }
                guard outcome.success,
                      let answer = target.messages.last(where: { $0.role == .assistant })?.content,
                      !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.watches[idx].lastAnalysis = "分析失败：\(outcome.error ?? "empty answer")"
                    self.save()
                    return
                }
                let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                self.watches[idx].lastAnalysis = trimmed
                self.save()
                self.notifyAnalysis(watch: self.watches[idx], analysis: trimmed)
            }
        }
    }

    /// 带分析的系统通知（变化时刻的裸通知之外的增值信息）。走主动通知收口
    /// （routine：免打扰时段/超预算时合并进摘要）。
    private func notifyAnalysis(watch: PageWatch, analysis: String) {
        ProactiveNotificationStore.shared.deliver(
            title: String(localized: "Page watch · AI analysis"),
            body: "\(watch.name)：\(analysis.prefix(180))",
            tier: .routine)
    }

    // MARK: - Notification

    /// 数值跨阈值通知（routine 档：免打扰/预算由通知策略收口，不绕过分级）。
    private func notifyNumericAlert(watch: PageWatch, value: Double) {
        ProactiveNotificationStore.shared.deliver(
            title: String(localized: "Page watch “\(watch.name)”"),
            body: watch.lastAlert ?? String(format: "%.2f", value),
            tier: .routine)
        Self.log.info("page watch '\(watch.name, privacy: .public)' numeric alert: \(value, privacy: .public)")
    }

    private func notifyChange(watch: PageWatch, diff: String) {
        ProactiveNotificationStore.shared.deliver(
            title: String(localized: "Page changed"),
            body: "\(watch.name) (\(diff))",
            tier: .routine)
    }
}
