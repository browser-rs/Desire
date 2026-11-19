import Foundation

struct QuickDial: Identifiable, Codable {
    let id: UUID
    var title: String
    var url: String
    var icon: String
    /// 同步/排序位次（Store 在每次结构变更后重编号为 0..n，数组保持按 sort 有序）
    var sort: Int = 0
    /// 云同步 LWW 戳（optional + 合成 Codable：旧文件缺键解码为 nil，不清数据）
    var updatedAt: Date? = nil

    init(id: UUID = UUID(), title: String, url: String, icon: String = "globe",
         sort: Int = 0, updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.icon = icon
        self.sort = sort
        self.updatedAt = updatedAt
    }
}

/// **默认集用固定 UUID**（v0.8.64）：id 若每次启动随机生成，空桶误判重写
/// 会在同步层变成"同内容不同 id"的成对重复（实测 8 组）；固定后即便重写，
/// LWW 也按同 id 收敛，不再新增。
let defaultDials: [QuickDial] = [
    QuickDial(id: UUID(uuidString: "7A1F4C3E-0001-4A6B-9C2D-111111111111")!, title: "Google", url: "https://www.google.com", icon: "magnifyingglass"),
    QuickDial(id: UUID(uuidString: "7A1F4C3E-0002-4A6B-9C2D-222222222222")!, title: "YouTube", url: "https://www.youtube.com", icon: "play.rectangle"),
    QuickDial(id: UUID(uuidString: "7A1F4C3E-0003-4A6B-9C2D-333333333333")!, title: "GitHub", url: "https://github.com", icon: "chevron.left.forwardslash.chevron.right"),
    QuickDial(id: UUID(uuidString: "7A1F4C3E-0004-4A6B-9C2D-444444444444")!, title: "Wikipedia", url: "https://www.wikipedia.org", icon: "book"),
    QuickDial(id: UUID(uuidString: "7A1F4C3E-0005-4A6B-9C2D-555555555555")!, title: "Reddit", url: "https://www.reddit.com", icon: "bubble.left.and.bubble.right"),
    QuickDial(id: UUID(uuidString: "7A1F4C3E-0006-4A6B-9C2D-666666666666")!, title: "Apple", url: "https://www.apple.com", icon: "apple.logo"),
    QuickDial(id: UUID(uuidString: "7A1F4C3E-0007-4A6B-9C2D-777777777777")!, title: "Twitter/X", url: "https://x.com", icon: "bird"),
    QuickDial(id: UUID(uuidString: "7A1F4C3E-0008-4A6B-9C2D-888888888888")!, title: "Baidu", url: "https://www.baidu.com", icon: "globe"),
]

/// **快拨 URL 去重**（v0.8.64 收敛修复，Foundation-only 进 tests/run.sh）：
/// 快拨是"地址即身份"的平铺域——同 URL 双份没有意义。实测事故：默认集
/// 被某次启动误判空桶重写（新 UUID + nil 戳被盖成当前时间），同步并集语义
/// 把两套默认集落成 8 组成对重复；去重保留 updatedAt 最新的一条，被剔除
/// 的 id 由 Store 记 tombstone 推上服务端（其他设备跟着收敛）。
nonisolated enum QuickDialDedupe {

    /// URL 归一化：trim + 小写 + 去尾斜杠（`https://GitHub.com/` 与
    /// `https://github.com` 视为同址）。
    static func normalizeURL(_ url: String) -> String {
        var key = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while key.count > 1 && key.hasSuffix("/") { key.removeLast() }
        return key
    }

    /// 新旧判定：updatedAt 为 nil 视为最旧；相同时间戳保留先出现者。
    static func isNewer(_ a: QuickDial, than b: QuickDial) -> Bool {
        switch (a.updatedAt, b.updatedAt) {
        case let (l?, r?): return l > r
        case (nil, .some): return false
        case (.some, nil): return true
        case (nil, nil): return false
        }
    }

    /// 同址去重：按输入顺序扫描，同组保留最新；返回保留集（按原 sort 排序）
    /// 与被剔除 id 清单（调用方记 tombstone）。
    static func dedupe(_ dials: [QuickDial]) -> (kept: [QuickDial], removedIDs: [UUID]) {
        var byURL: [String: QuickDial] = [:]
        var removedIDs: [UUID] = []
        for dial in dials {
            let key = normalizeURL(dial.url)
            guard !key.isEmpty else {
                removedIDs.append(dial.id)
                continue
            }
            if let existing = byURL[key] {
                let keep = isNewer(dial, than: existing) ? dial : existing
                let drop = keep.id == dial.id ? existing : dial
                byURL[key] = keep
                removedIDs.append(drop.id)
            } else {
                byURL[key] = dial
            }
        }
        let kept = byURL.values.sorted { $0.sort < $1.sort }
        return (kept, removedIDs)
    }
}
