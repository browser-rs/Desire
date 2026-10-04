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

let defaultDials: [QuickDial] = [
    QuickDial(title: "Google", url: "https://www.google.com", icon: "magnifyingglass"),
    QuickDial(title: "YouTube", url: "https://www.youtube.com", icon: "play.rectangle"),
    QuickDial(title: "GitHub", url: "https://github.com", icon: "chevron.left.forwardslash.chevron.right"),
    QuickDial(title: "Wikipedia", url: "https://www.wikipedia.org", icon: "book"),
    QuickDial(title: "Reddit", url: "https://www.reddit.com", icon: "bubble.left.and.bubble.right"),
    QuickDial(title: "Apple", url: "https://www.apple.com", icon: "apple.logo"),
    QuickDial(title: "Twitter/X", url: "https://x.com", icon: "bird"),
    QuickDial(title: "Baidu", url: "https://www.baidu.com", icon: "globe"),
]
