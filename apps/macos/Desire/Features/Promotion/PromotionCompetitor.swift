import Foundation

/// 竞品/市场监测来源（v0.8.3）：一个页面 + 上次快照 + 最近变化摘要。
/// 数据是用户主动添加的公开页面；检查在后台标签里只读进行，不做大规模爬取。
///
/// Foundation-only，进 harness。
nonisolated struct PromotionCompetitorSource: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var url: String
    var note: String
    var isEnabled: Bool
    var lastCheckedAt: Date?
    var lastChangeAt: Date?
    /// 归一化后的页面快照（上限见 Checker；用于下次 diff）。
    var lastSnapshot: String?
    var lastChangeSummary: String?
    let createdAt: Date

    init(id: UUID = UUID(), name: String, url: String, note: String = "",
         isEnabled: Bool = true, lastCheckedAt: Date? = nil,
         lastChangeAt: Date? = nil, lastSnapshot: String? = nil,
         lastChangeSummary: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.url = url
        self.note = note
        self.isEnabled = isEnabled
        self.lastCheckedAt = lastCheckedAt
        self.lastChangeAt = lastChangeAt
        self.lastSnapshot = lastSnapshot
        self.lastChangeSummary = lastChangeSummary
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, note, isEnabled, lastCheckedAt, lastChangeAt,
             lastSnapshot, lastChangeSummary, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        lastCheckedAt = (try? c.decodeIfPresent(Date.self, forKey: .lastCheckedAt)) ?? nil
        lastChangeAt = (try? c.decodeIfPresent(Date.self, forKey: .lastChangeAt)) ?? nil
        lastSnapshot = (try? c.decodeIfPresent(String.self, forKey: .lastSnapshot)) ?? nil
        lastChangeSummary = (try? c.decodeIfPresent(String.self, forKey: .lastChangeSummary)) ?? nil
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
    }
}

/// 竞品页面快照 diff（纯逻辑）：按行归一化后比较新增/删除，输出可读摘要；
/// 不试图理解页面语义（结构化视图在 Checker 里已经展平成行）。
nonisolated enum PromotionCompetitorDiff {
    static func normalize(_ text: String, limit: Int = 20_000) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { line in
                line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        return String(lines.joined(separator: "\n").prefix(limit))
    }

    struct Result: Equatable {
        var changed: Bool
        var summary: String
        var added: [String]
        var removed: [String]
    }

    static func diff(old: String?, new: String, maxLines: Int = 3) -> Result {
        guard let old, !old.isEmpty else {
            let count = new.split(separator: "\n").count
            return Result(changed: !new.isEmpty,
                          summary: new.isEmpty ? "" : String(localized: "First snapshot (\(count) lines)"),
                          added: [], removed: [])
        }
        let oldLines = old.split(separator: "\n").map(String.init)
        let newLines = new.split(separator: "\n").map(String.init)
        let oldSet = Set(oldLines)
        let newSet = Set(newLines)
        let added = newLines.filter { !oldSet.contains($0) }
        let removed = oldLines.filter { !newSet.contains($0) }
        guard !added.isEmpty || !removed.isEmpty else {
            return Result(changed: false, summary: "", added: [], removed: [])
        }
        var parts: [String] = []
        for line in added.prefix(maxLines) {
            parts.append("+ " + String(line.prefix(120)))
        }
        for line in removed.prefix(maxLines) {
            parts.append("- " + String(line.prefix(120)))
        }
        return Result(changed: true, summary: parts.joined(separator: " · "),
                      added: added, removed: removed)
    }
}
