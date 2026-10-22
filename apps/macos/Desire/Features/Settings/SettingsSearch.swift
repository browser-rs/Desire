import Foundation

/// 设置全文检索的静态目录（Foundation-only，进 harness）。
///
/// 设置页是手写 SwiftUI，无法像 SwiftUI Form 那样自动反射行标题；这里维护
/// 一份**分区 + 关键行**的目录（标题/副标题/中英文关键词），搜索命中后跳到
/// 对应分区。新增设置行时记得补一条——目录条数由 harness 断言下限，防止
/// 越加越少。
nonisolated struct SettingsSearchEntry: Identifiable, Equatable {
    let id: String
    /// `SettingsView.Section.rawValue`（general/ai/ball/pageWatch/sync/remote/
    /// privacy/autofill/keyboardShortcuts/batchDownloads）。
    let section: String
    let title: String
    var subtitle: String? = nil
    var keywords: [String] = []
}

nonisolated struct SettingsSearchHit: Equatable {
    let entry: SettingsSearchEntry
    let score: Int
}

nonisolated enum SettingsSearch {
    static let entries: [SettingsSearchEntry] = [
        // General
        .init(id: "general.language", section: "general", title: "Language",
              subtitle: "App language", keywords: ["语言", "中文", "English", "繁体", "language"]),
        .init(id: "general.appearance", section: "general", title: "Appearance",
              subtitle: "Theme and accent color", keywords: ["外观", "主题", "深色", "浅色", "dark", "light", "accent", "强调色", "颜色"]),
        .init(id: "general.startup", section: "general", title: "Startup Behavior",
              subtitle: "Restore session, homepage or page set", keywords: ["启动", "恢复会话", "主页", "页面集", "startup", "restore"]),
        .init(id: "general.homepage", section: "general", title: "Homepage",
              keywords: ["主页", "首页", "home"]),
        .init(id: "general.newtab", section: "general", title: "New Tab Position",
              keywords: ["新标签", "位置", "new tab"]),
        .init(id: "general.downloadFolder", section: "general", title: "Download Folder",
              keywords: ["下载目录", "文件夹", "downloads", "folder"]),
        .init(id: "general.conflict", section: "general", title: "Download Conflicts",
              subtitle: "Ask, rename or replace existing files", keywords: ["重名", "冲突", "覆盖", "重命名", "conflict", "replace"]),
        .init(id: "general.defaultBrowser", section: "general", title: "Default Browser",
              keywords: ["默认浏览器", "default browser", "http", "https"]),
        .init(id: "general.updates", section: "general", title: "Check for Updates",
              keywords: ["更新", "升级", "update", "release"]),
        .init(id: "general.diagnostics", section: "general", title: "Diagnostics",
              subtitle: "Crash reports and logs", keywords: ["诊断", "日志", "崩溃", "diagnostics", "log", "crash"]),
        .init(id: "general.backup", section: "general", title: "Backup & Restore",
              keywords: ["备份", "恢复", "导入", "导出", "backup", "restore"]),
        .init(id: "general.import", section: "general", title: "Import Browser Data",
              subtitle: "Chrome, Edge, Brave, Arc, Safari", keywords: ["导入", "书签", "历史", "浏览器", "chrome", "edge", "brave", "arc", "safari", "import"]),
        .init(id: "general.pageText", section: "general", title: "Search Page Text",
              subtitle: "Local history full-text index", keywords: ["正文检索", "历史", "索引", "全文", "page text", "history", "search"]),
        .init(id: "general.downloadPolicy", section: "general", title: "Downloads",
              subtitle: "Low Power pause and organize by type", keywords: ["下载", "低电量", "归档", "类型", "low power", "organize"]),
        .init(id: "general.menuBar", section: "general", title: "Menu Bar Quick Entry",
              keywords: ["菜单栏", "状态栏", "menu bar", "status bar"]),
        .init(id: "general.zoom", section: "general", title: "Page Zoom",
              keywords: ["缩放", "zoom"]),
        .init(id: "general.autoPlay", section: "general", title: "Auto-Play",
              keywords: ["自动播放", "视频", "autoplay", "media"]),
        .init(id: "general.font", section: "general", title: "Page Font",
              keywords: ["字体", "字号", "font", "size"]),
        // Agent
        .init(id: "ai.profiles", section: "ai", title: "Service Profiles",
              subtitle: "Endpoint, model and API key per service", keywords: ["服务", "档案", "端点", "API", "profiles", "endpoint"]),
        .init(id: "ai.key", section: "ai", title: "API Key",
              keywords: ["密钥", "key", "keychain", "钥匙串"]),
        .init(id: "ai.model", section: "ai", title: "Model",
              keywords: ["模型", "model"]),
        .init(id: "ai.prompt", section: "ai", title: "System Prompt",
              keywords: ["系统提示词", "提示词", "prompt", "persona", "人设"]),
        .init(id: "ai.rules", section: "ai", title: "Output Rules",
              keywords: ["输出规则", "规则", "rules"]),
        .init(id: "ai.memory", section: "ai", title: "Agent Memory",
              keywords: ["记忆", "memory"]),
        .init(id: "ai.budget", section: "ai", title: "Token Budget",
              keywords: ["预算", "token", "budget", "成本", "cost"]),
        .init(id: "ai.routing", section: "ai", title: "Model Routing",
              keywords: ["路由", "回退", "routing", "fallback"]),
        .init(id: "ai.fallback", section: "ai", title: "Fallback Profile",
              keywords: ["备用档案", "fallback", "failover"]),
        .init(id: "ai.personas", section: "ai", title: "Personas",
              keywords: ["人设", "persona"]),
        .init(id: "ai.mcp", section: "ai", title: "MCP Servers",
              keywords: ["MCP", "模型上下文协议", "server"]),
        // Floating ball
        .init(id: "ball.enable", section: "ball", title: "Floating Ball",
              keywords: ["悬浮球", "球", "floating ball"]),
        .init(id: "ball.size", section: "ball", title: "Ball Size and Behavior",
              keywords: ["悬浮球", "大小", "尺寸", "size"]),
        // Page Watch
        .init(id: "watch.center", section: "pageWatch", title: "Watch Center",
              subtitle: "Status and 24h digest", keywords: ["监视中心", "摘要", "watch center", "digest"]),
        .init(id: "watch.add", section: "pageWatch", title: "Add Page Watch",
              keywords: ["监视", "盯页面", "watch", "add"]),
        .init(id: "watch.ai", section: "pageWatch", title: "Page Watch AI Analysis",
              keywords: ["监视", "AI 分析", "analysis"]),
        .init(id: "watch.numeric", section: "pageWatch", title: "Numeric Alerts",
              keywords: ["价格", "阈值", "数值", "alert", "price"]),
        // Sync
        .init(id: "sync.account", section: "sync", title: "Sync Account",
              keywords: ["同步", "账号", "登录", "sync", "account"]),
        .init(id: "sync.server", section: "sync", title: "Sync Server",
              keywords: ["同步", "服务器", "server"]),
        .init(id: "sync.key", section: "sync", title: "Sync Key Fingerprint",
              keywords: ["同步", "密钥", "指纹", "keychain", "钥匙串", "E2E"]),
        .init(id: "sync.domains", section: "sync", title: "Sync Categories",
              keywords: ["同步", "类目", "书签", "历史", "设置", "domains"]),
        .init(id: "sync.migrate", section: "sync", title: "Re-authorize Sync",
              keywords: ["同步", "重新授权", "迁移", "钥匙串", "keychain", "migrate"]),
        // Remote
        .init(id: "remote.control", section: "remote", title: "Remote Control",
              keywords: ["远程", "手机", "remote", "iOS"]),
        .init(id: "remote.pair", section: "remote", title: "Pairing",
              keywords: ["配对", "二维码", "pair", "qr"]),
        // Privacy
        .init(id: "privacy.blocker", section: "privacy", title: "Content Blocker",
              keywords: ["广告拦截", "内容拦截", "blocker", "ads"]),
        .init(id: "privacy.filters", section: "privacy", title: "Filter Lists",
              keywords: ["过滤列表", "EasyList", "filter", "ads"]),
        .init(id: "privacy.cookies", section: "privacy", title: "Cookies",
              keywords: ["Cookie", "网站数据", "cookies"]),
        .init(id: "privacy.permissions", section: "privacy", title: "Site Permissions",
              keywords: ["权限", "摄像头", "麦克风", "定位", "permissions", "camera", "microphone"]),
        .init(id: "privacy.https", section: "privacy", title: "HTTPS Upgrade",
              keywords: ["HTTPS", "升级", "upgrade"]),
        // Autofill
        .init(id: "autofill.profile", section: "autofill", title: "Autofill Profile",
              keywords: ["自动填充", "表单", "autofill", "profile"]),
        .init(id: "autofill.passwords", section: "autofill", title: "Passwords",
              keywords: ["密码", "钥匙串", "password", "keychain"]),
        // Keyboard
        .init(id: "keys.shortcuts", section: "keyboardShortcuts", title: "Keyboard Shortcuts",
              keywords: ["快捷键", "键盘", "shortcuts", "keyboard"]),
        // Batch downloads
        .init(id: "batch.settings", section: "batchDownloads", title: "Batch Downloads",
              keywords: ["批量下载", "视频", "并发", "batch", "download"]),
        .init(id: "batch.folder", section: "batchDownloads", title: "Batch Download Folder",
              keywords: ["批量下载", "目录", "分卷", "folder"]),
        .init(id: "batch.reserve", section: "batchDownloads", title: "Disk Space Reserve",
              keywords: ["磁盘", "空间", "预留", "disk", "reserve"]),
    ]

    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: .current)
    }

    static func search(_ query: String, entries: [SettingsSearchEntry] = SettingsSearch.entries) -> [SettingsSearchHit] {
        let q = normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let tokens = q.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var hits: [SettingsSearchHit] = []
        for entry in entries {
            let title = normalize(entry.title)
            let subtitle = normalize(entry.subtitle ?? "")
            let section = normalize(entry.section)
            let keywords = normalize(entry.keywords.joined(separator: " "))
            let haystack = "\(title) \(subtitle) \(section) \(keywords)"
            guard tokens.allSatisfy({ haystack.contains($0) }) else { continue }
            var score = 1
            if title == q { score += 100 }
            else if title.hasPrefix(q) { score += 50 }
            else if title.contains(q) { score += 30 }
            if subtitle.contains(q) { score += 10 }
            if keywords.contains(q) { score += 5 }
            hits.append(SettingsSearchHit(entry: entry, score: score))
        }
        hits.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.entry.title < $1.entry.title
        }
        return hits
    }
}
