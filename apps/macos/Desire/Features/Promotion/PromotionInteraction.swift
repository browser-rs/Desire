import Foundation

/// 互动台账（运营中心的第五类数据）：评论 / 私信 / 提及 / 评价——
/// 智能体巡检时登记，用户在面板过目，拟稿 → 确认后回复 → 状态闭环。
/// 「替人干活」里最容易漏掉的一环：评论不回，运营等于没做。
struct PromotionInteraction: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case comment
        case dm
        case mention
        case review
    }

    enum Status: String, Codable {
        /// 待回复（默认）。
        case pending
        case replied
        case ignored
    }

    let id: UUID
    var kind: Kind
    var platform: String
    /// 归属账号（可空——不一定是在自己账号下发现）。
    var accountHandle: String?
    /// 出现在哪篇内容下（可空）。
    var postTitle: String?
    var postURL: String?
    /// 谁写的。
    var author: String
    /// 互动正文（原文摘要）。
    var text: String
    /// 直达链接（评论锚点；能拿就拿——回复时导航用）。
    var url: String?
    var status: Status
    /// 已发出（或待批准）的回复文本。
    var reply: String?
    let createdAt: Date
    var updatedAt: Date
    var repliedAt: Date?

    init(id: UUID = UUID(), kind: Kind = .comment, platform: String,
         accountHandle: String? = nil, postTitle: String? = nil, postURL: String? = nil,
         author: String, text: String, url: String? = nil,
         status: Status = .pending, reply: String? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date(), repliedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.platform = platform
        self.accountHandle = accountHandle
        self.postTitle = postTitle
        self.postURL = postURL
        self.author = author
        self.text = text
        self.url = url
        self.status = status
        self.reply = reply
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.repliedAt = repliedAt
    }

    /// 去重键（纯逻辑，可测）：有直达链接用链接；否则用
    /// 平台+帖子+作者+正文 归一化拼装（空白/标点剥掉、小写）。
    nonisolated static func dedupeKey(url: String?, platform: String, postURL: String?,
                                      author: String, text: String) -> String {
        let cleanURL = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanURL.isEmpty { return "u:" + cleanURL.lowercased() }
        func norm(_ s: String?) -> String {
            (s ?? "").lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        }
        return "k:" + norm(platform) + "|" + norm(postURL) + "|" + norm(author) + "|" + norm(text)
    }

    var dedupeKey: String {
        Self.dedupeKey(url: url, platform: platform, postURL: postURL,
                       author: author, text: text)
    }
}
