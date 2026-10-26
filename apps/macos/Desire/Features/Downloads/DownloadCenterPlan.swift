import Foundation

/// 下载中心 v2（v0.8.10）纯逻辑：重复下载检测与失败批量重试清单。
/// Foundation-only，进 harness。按日聚合走面板的 groupingMode = .date（已有）。
nonisolated enum DownloadCenterPlan {

    // MARK: - 重复检测

    struct Repeat: Equatable {
        /// 源 URL（规范化的键）。
        let key: String
        /// 最近一次下载（提示"复用它"的对象）。
        let recentID: UUID
        let recentFilename: String
        let recentAt: Date
        /// 更早的重复次数（不含最近一次）。
        let earlierCount: Int
    }

    /// 同源 URL 近 `windowDays` 天内下过 → 提示复用。输入任意序的
    /// (id, sourceURL, filename, startTime) 行（活动+历史合并视图由调用方给）。
    static func repeats(rows: [(id: UUID, sourceURL: String?, filename: String, startTime: Date)],
                        now: Date = Date(), windowDays: Int = 7) -> [Repeat] {
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        var byKey: [String: [(id: UUID, filename: String, at: Date)]] = [:]
        for r in rows {
            guard let url = r.sourceURL, !url.isEmpty else { continue }
            byKey[normalize(url), default: []].append((r.id, r.filename, r.startTime))
        }
        return byKey.compactMap { _, list -> Repeat? in
            let sorted = list.sorted { $0.at > $1.at }
            guard let recent = sorted.first, recent.at >= cutoff, sorted.count >= 2 else { return nil }
            return Repeat(key: "", recentID: recent.id,
                          recentFilename: recent.filename, recentAt: recent.at,
                          earlierCount: sorted.count - 1)
        }
        .sorted { $0.recentAt > $1.recentAt }
    }

    /// 规范化：去 query（临时链接令牌）、小写 host——同文件不同签名 URL 归一。
    static func normalize(_ urlString: String) -> String {
        guard var comps = URLComponents(string: urlString) else { return urlString }
        comps.query = nil
        comps.fragment = nil
        if let host = comps.host?.lowercased() { comps.host = host }
        return comps.string ?? urlString
    }

    // MARK: - 失败批量重试

    /// 可重试清单：failed 态、带源 URL 的行 id（顺序 = 最新优先）。
    static func retryable(rows: [(id: UUID, sourceURL: String?, isFailed: Bool, startTime: Date)]) -> [UUID] {
        rows.filter { $0.isFailed && $0.sourceURL != nil }
            .sorted { $0.startTime > $1.startTime }
            .map(\.id)
    }
}
