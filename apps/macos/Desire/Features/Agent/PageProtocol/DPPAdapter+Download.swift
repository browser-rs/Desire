import Foundation

/// **站点下载规则**（v0.8.77 批 2，Foundation-only 进 tests/run.sh）：挂在 DPP 适配器
/// 顶层的 `download` 段——按主机/路径绑定、纯数据、没有代码；批量下载的隐藏解析器与
/// 智能体执行同一份。
///
/// 为什么是适配器而不是技能（2026-11-25 用户定调）：每个站点情况不同，规则只能对本站
/// 生效；DPP 适配器本来就按主机绑定、纯 JSON、有编写界面与健康记录。技能只留说明。
///
/// 三类字段：
/// - **提取**：详情页怎么拿到流地址（对页面文本求正则，或选择器 + 属性）、每页正片数、
///   列表页用哪个视图、排除什么；
/// - **参数**：每路连接数、签名地址有效期——**每次任务都可能被改好一点**；
/// - **打磨记录**：最近命中/失败、修订历史。
///
/// 规则段是**顶层**类型：嵌套在 `extension DPPAdapter` 里的类型会被推成主 actor 隔离
/// （Equatable/Codable 一致性也随之隔离），而外层的 `DPPAdapter` 是 nonisolated——
/// 在它里面存一个 `DownloadRules?` 就会报"隔离的一致性用在非隔离上下文"。
nonisolated struct DPPDownloadRules: Codable, Equatable {
    /// 详情页提取规则：
    /// - `regex:<pattern>`（无前缀也是正则）：对页面的 HTML + 内联脚本文本求正则，
    ///   第 1 个捕获组 = 媒体地址（没有捕获组 = 整个命中）；
    /// - `selector:<css>@<attr>`：页内选择器 + 属性，可多个命中。
    var detail: String?
    /// 每页正片数：`one`（只取第一个命中）/ `many`（全部命中）。nil = 按命中数。
    var perPage: String?
    /// 列表页视图名（协议体 `views` 的键）：智能体用 `pageExtract(view, all: true)`
    /// 一次取全详情页链接。
    var listView: String?
    /// 排除特征（正则，对媒体地址求值）。
    var exclude: [String]?
    /// 每路连接数（分片并发）；nil = 默认 8。
    var connections: Int?
    /// 下载方式（2026-11-26 用户定调：方式可以由站点规则决定）：auto / parallel / ffmpeg / builtin。
    /// nil = auto（按流的事实研判最优的一种）。
    var engine: String?
    /// 签名地址有效期（分钟）；nil = 默认 50。中途过期会自动缩短。
    var tokenMinutes: Int?

    /// **站点实测画像**（v0.8.79）：同一个网站的速度变化不大——最近一次实测在 7 天内且
    /// 样本 ≥2 就直接采用画像参数，不再逐次测速（用户定调："不是每个都要测速"）。
    struct Measured: Codable, Equatable {
        var singleBytesPerSecond: Double
        var parallelBytesPerSecond: Double
        var connections: Int
        var samples: Int
        var lastMeasuredAt: Date
    }
    var measured: Measured?

    // 打磨记录（引擎回写；用户在 Studio 里改规则时不必填）
    var lastMatchAt: Date?
    var lastFailureAt: Date?
    var lastError: String?
    var consecutiveFailures: Int?
    /// 修订历史（最近在前，上限 20）。
    var revisions: [Revision]?

    struct Revision: Codable, Equatable {
        var at: Date
        var change: String
    }

    init() {}
}

/// `detail` 规则的两种形态。
nonisolated enum DPPDetailRule: Equatable {
    case regex(String)
    case selector(css: String, attribute: String)
}

extension DPPAdapter {
    typealias DownloadRules = DPPDownloadRules
    typealias DetailRule = DPPDetailRule
}

extension DPPDownloadRules {

    enum PerPage: String, Equatable { case one, many }

    // 常量显式 nonisolated：下载引擎在非隔离上下文里也要读它们（默认参数、任务组）。
    nonisolated static let defaultTokenMinutes = 50
    nonisolated static let defaultConnections = 8
    nonisolated static let minTokenMinutes = 5
    nonisolated static let minConnections = 2
    /// 连续提取不到这么多次 → 规则待重学（页面多半改版了）。
    nonisolated static let staleAfterFailures = 3
    nonisolated static let revisionCap = 20
    nonisolated static let matchCap = 50
    /// 画像有效期与样本门槛（0.8.79）：过期或样本不足就重新测一次。
    nonisolated static let measuredTTL: TimeInterval = 7 * 86_400
    nonisolated static let measuredMinSamples = 2
    nonisolated static let measuredSampleCap = 5

    /// 可用的缓存证据（新鲜且样本够）；nil = 需要重新测。
    func cachedEvidence(now: Date = Date()) -> ParallelTuning.Evidence? {
        guard let measured, measured.samples >= Self.measuredMinSamples,
              now.timeIntervalSince(measured.lastMeasuredAt) <= Self.measuredTTL,
              measured.singleBytesPerSecond > 0, measured.parallelBytesPerSecond > 0 else { return nil }
        return ParallelTuning.Evidence(singleBytesPerSecond: measured.singleBytesPerSecond,
                                       parallelBytesPerSecond: measured.parallelBytesPerSecond,
                                       connectionsTested: measured.connections)
    }

    /// 把一次实测并入画像（EMA，样本封顶 5；连接数变了就重新起算）。
    func recording(_ evidence: ParallelTuning.Evidence, now: Date = Date()) -> DPPDownloadRules {
        var out = self
        if let current = measured, current.connections == evidence.connectionsTested {
            let n = min(max(current.samples, 1), Self.measuredSampleCap)
            out.measured = Measured(
                singleBytesPerSecond: (current.singleBytesPerSecond * Double(n) + evidence.singleBytesPerSecond) / Double(n + 1),
                parallelBytesPerSecond: (current.parallelBytesPerSecond * Double(n) + evidence.parallelBytesPerSecond) / Double(n + 1),
                connections: current.connections, samples: min(n + 1, Self.measuredSampleCap),
                lastMeasuredAt: now)
        } else {
            out.measured = Measured(singleBytesPerSecond: evidence.singleBytesPerSecond,
                                    parallelBytesPerSecond: evidence.parallelBytesPerSecond,
                                    connections: evidence.connectionsTested, samples: 1, lastMeasuredAt: now)
        }
        return out
    }

    /// 站点规则指定的下载方式；nil / auto = 交给研判。
    nonisolated var enginePreference: DownloadRouting.EnginePreference? {
        guard let preference = DownloadRouting.EnginePreference.parse(engine), preference != .auto else { return nil }
        return preference
    }

    /// 规则内容的指纹（**不含**实测画像与打磨记录）：说明性技能只随规则变化重写，
    /// 每天的回写不该每下载一次就重写一次技能。
    var contentFingerprint: String {
        var copy = self
        copy.measured = nil
        copy.lastMatchAt = nil
        copy.lastFailureAt = nil
        copy.lastError = nil
        copy.consecutiveFailures = nil
        copy.revisions = nil
        guard let data = try? JSONEncoder().encode(copy) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated var perPageRule: PerPage? {
        PerPage(rawValue: (perPage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// `detail` 的解析；写得不完整（选择器缺属性等）= nil。
    nonisolated func detailRule() -> DPPDetailRule? {
        guard let raw = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("selector:") {
            let body = raw.dropFirst("selector:".count).trimmingCharacters(in: .whitespaces)
            guard let at = body.lastIndex(of: "@") else { return nil }
            let css = String(body[..<at]).trimmingCharacters(in: .whitespaces)
            let attribute = String(body[body.index(after: at)...]).trimmingCharacters(in: .whitespaces)
            guard !css.isEmpty, !attribute.isEmpty else { return nil }
            return .selector(css: css, attribute: attribute)
        }
        let pattern = raw.hasPrefix("regex:")
            ? String(raw.dropFirst("regex:".count)).trimmingCharacters(in: .whitespaces)
            : raw
        return .regex(pattern)
    }

    /// 对页面文本（HTML + 内联脚本）求正则。只有正则规则能在这里求值；选择器规则
    /// 要进页面，由解析器执行。正则非法 = 空（解析器据此回退通用识别）。
    func extract(fromText text: String) -> [String] {
        guard case .regex(let pattern)? = detailRule(),
              let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var out: [String] = []
        for match in regex.matches(in: text, range: range) {
            let group = match.numberOfRanges > 1 ? 1 : 0
            guard let found = Range(match.range(at: group), in: text) else { continue }
            let value = String(text[found]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !out.contains(value) { out.append(value) }
            if out.count >= Self.matchCap { break }
        }
        return out
    }

    /// 命中排除特征（非法正则忽略，不误杀）。
    func isExcluded(_ url: String) -> Bool {
        for pattern in exclude ?? [] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            if regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil { return true }
        }
        return false
    }

    /// 按规则收口：先排除，再按每页正片数取前 N。返回被拒的（地址 + 理由）。
    func applying(to urls: [String]) -> (kept: [String], rejected: [(url: String, reason: String)]) {
        var kept: [String] = []
        var rejected: [(url: String, reason: String)] = []
        for url in urls {
            if isExcluded(url) {
                rejected.append((url, "site rule exclude pattern"))
            } else {
                kept.append(url)
            }
        }
        if perPageRule == .one, kept.count > 1 {
            rejected += kept.dropFirst().map { ($0, "site rule: one video per page") }
            kept = Array(kept.prefix(1))
        }
        return (kept, rejected)
    }

    // MARK: - 打磨

    enum AdaptationSignal: Equatable {
        /// 地址在下载中途过期（403）→ 缩短有效期。
        case signatureExpired
        /// 被限流 / 大量连接错误 → 降并发。
        case rateLimited
        /// 规则在页面上提取不到 → 记失败；连续达到阈值即待重学。
        case ruleMatchedNothing
        /// 规则提取成功。
        case matched
    }

    /// 这个信号会不会改变规则（不改就不必落盘）。
    func needsWrite(for signal: AdaptationSignal) -> Bool {
        switch signal {
        case .signatureExpired:
            return (tokenMinutes ?? Self.defaultTokenMinutes) > Self.minTokenMinutes
        case .rateLimited:
            return (connections ?? Self.defaultConnections) > Self.minConnections
        case .ruleMatchedNothing:
            return true
        case .matched:
            return (consecutiveFailures ?? 0) > 0 || lastError != nil
        }
    }

    /// 按一次任务的结果调整并留修订记录；`needsWrite` 为假时原样返回。
    func adapting(to signal: AdaptationSignal, now: Date = Date()) -> DPPDownloadRules {
        var out = self
        switch signal {
        case .signatureExpired:
            let current = tokenMinutes ?? Self.defaultTokenMinutes
            let next = max(Self.minTokenMinutes, Int((Double(current) * 0.6).rounded(.down)))
            guard next < current else { break }
            out.tokenMinutes = next
            out.note("address expired mid-download — tokenMinutes \(current) → \(next)", now: now)
        case .rateLimited:
            let current = connections ?? Self.defaultConnections
            let next = max(Self.minConnections, current / 2)
            guard next < current else { break }
            out.connections = next
            out.note("rate limited / connection errors — connections \(current) → \(next)", now: now)
        case .ruleMatchedNothing:
            out.lastFailureAt = now
            out.lastError = "rule matched nothing on the page"
            out.consecutiveFailures = (consecutiveFailures ?? 0) + 1
        case .matched:
            out.lastMatchAt = now
            out.consecutiveFailures = 0
            out.lastError = nil
        }
        return out
    }

    /// 连续提取不到达到阈值：规则待重学（页面多半改版了）。
    var needsRelearn: Bool {
        (consecutiveFailures ?? 0) >= Self.staleAfterFailures
    }

    private mutating func note(_ change: String, now: Date) {
        var list = revisions ?? []
        list.insert(Revision(at: now, change: change), at: 0)
        if list.count > Self.revisionCap { list = Array(list.prefix(Self.revisionCap)) }
        revisions = list
    }
}

extension DPPAdapter {

    /// 改写下载规则段（没有就新建），返回新适配器。纯值操作，落盘由仓库负责。
    func withDownloadRules(_ mutate: (inout DownloadRules) -> Void) -> DPPAdapter {
        var out = self
        var rules = out.download ?? DownloadRules()
        mutate(&rules)
        out.download = rules
        return out
    }
}
