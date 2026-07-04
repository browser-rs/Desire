import Foundation

struct QuickDial: Identifiable, Codable {
    let id: UUID
    var title: String
    var url: String
    var icon: String

    init(id: UUID = UUID(), title: String, url: String, icon: String = "globe") {
        self.id = id
        self.title = title
        self.url = url
        self.icon = icon
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
    QuickDial(title: "Baidu", url: "https://www.baidu.com", icon: "spider"),
]
