import Foundation
import os

/// **诊断文件清理**（v0.8.76 批 1，Foundation-only 进 tests/run.sh）。
///
/// 只管四类带时间戳的诊断文件名（停滞采样 / MetricKit 指标与诊断 / 导出的系统
/// 日志），其余文件一律不碰——`last-stall.json`、`launch-audit.json` 这类当前
/// 状态文件不在范围内。
///
/// 背景：`health/stall-*.txt` 此前没有任何修剪，每次停滞取证留下最大 1.2MB 的
/// 采样，实测 11 天堆到 22.6MB，占整个 Desire 目录的 85%。MetricKit 的两类已有
/// "每类保留 30 份"的数量修剪、系统日志保留 3 份——这里沿用各自的份数，另加一条
/// 统一的年龄线（默认 30 天）：份数内的旧文件同样会被清掉。
///
/// 纪律：删除只针对"30 天外 **且** 不在最近 N 份之内"的文件——两个条件同时满足
/// 才删，宁可多留。
nonisolated enum DiagnosticGC {

    struct Entry: Equatable, Sendable {
        let name: String
        let modifiedAt: Date
    }

    /// 受管的文件名类别：组名 → (匹配正则, 保留份数)。
    /// 文件名里的时间戳是应用自己写的是 ISO/本地格式，可排序；这里按修改时间
    /// 排序，与文件名无关。
    struct Kind: Sendable {
        let group: String
        let keep: Int
        let pattern: String
    }

    static let kinds: [Kind] = [
        Kind(group: "stall", keep: 20,
             pattern: #"^stall-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z\.txt$"#),
        Kind(group: "diagnostics", keep: 30,
             pattern: #"^diagnostics-\d{4}-\d{2}-\d{2}_\d{6}\.json$"#),
        Kind(group: "metrics", keep: 30,
             pattern: #"^metrics-\d{4}-\d{2}-\d{2}_\d{6}\.json$"#),
        Kind(group: "oslog", keep: 3,
             pattern: #"^oslog-\d{8}-\d{6}\.log$"#),
    ]

    /// 年龄线（秒）。份数内超过这个天数的也清。
    static let maxAge: TimeInterval = 30 * 86_400

    /// 文件属于哪个受管类别；nil = 不受管（永不删除）。
    /// 正则每次现编译现用，不缓存任何 range。
    static func group(forName name: String) -> String? {
        for kind in kinds {
            guard let regex = try? NSRegularExpression(pattern: kind.pattern) else { continue }
            let range = NSRange(name.startIndex..., in: name)
            if regex.firstMatch(in: name, range: range) != nil { return kind.group }
        }
        return nil
    }

    /// 给定一个目录的条目，返回应当删除的那些。按类别分组、每组按修改时间倒序：
    /// 名次 < 保留份数，或修改时间在年龄线内的，保留；其余删除。
    static func victims(_ entries: [Entry], now: Date = Date(),
                        kinds: [Kind] = kinds, maxAge: TimeInterval = maxAge) -> [Entry] {
        // uniquingKeysWith：静态表 group 唯一，但调用方可传自定义表——重复键
        // 走合并而不是崩溃。
        let keepByGroup = Dictionary(kinds.map { ($0.group, $0.keep) }, uniquingKeysWith: { first, _ in first })
        var grouped: [String: [Entry]] = [:]
        for entry in entries {
            guard let group = group(forName: entry.name) else { continue }
            grouped[group, default: []].append(entry)
        }
        var out: [Entry] = []
        for (group, items) in grouped {
            let keep = keepByGroup[group] ?? 0
            let sorted = items.sorted { lhs, rhs in
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
                return lhs.name > rhs.name
            }
            for (rank, entry) in sorted.enumerated() {
                let withinAge = now.timeIntervalSince(entry.modifiedAt) <= maxAge
                if rank < keep || withinAge { continue }
                out.append(entry)
            }
        }
        return out
    }

    /// 清理一个目录（只扫一层）。返回删除的文件数；失败静默——清理失败不该
    /// 影响任何功能，下次启动会再试。
    @discardableResult
    static func sweep(directory: URL, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return 0 }
        var entries: [Entry] = []
        for url in urls {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            entries.append(Entry(name: url.lastPathComponent, modifiedAt: date))
        }
        var removed = 0
        for victim in victims(entries, now: now) {
            if (try? fm.removeItem(at: directory.appendingPathComponent(victim.name))) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// 启动后延迟清理（默认 15 秒后，后台 utility 队列）：不占启动路径，也不在
    /// 启动恢复会话的 IO 高峰期抢磁盘。
    static func scheduleAll(directories: [URL], delay: TimeInterval = 15) {
        let dirs = Set(directories.map(\.standardizedFileURL))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            var removed = 0
            for dir in dirs { removed += sweep(directory: dir) }
            if removed > 0 {
                Logger(subsystem: "me.siwi.Desire", category: "health").info(
                    "diagnostics gc: removed \(removed, privacy: .public) expired file(s)")
            }
        }
    }
}
