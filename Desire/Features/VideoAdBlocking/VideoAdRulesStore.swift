import AppKit
import Combine
import Foundation

/// 视频站广告拦截规则的**热插拔**层：把"规则"从二进制里拿出来，按下面的
/// 优先级解析（先命中先用）：
///
///   1. **本地覆盖** `~/Library/Application Support/Desire/VideoAdRules/<site>.css|.js`
///   2. **远程规则包** `…/VideoAdRules/remote/rules.json`（由 `refreshRemote()` 拉取）
///   3. **内置规则** `VideoSiteScripts.swift` 的默认值（兜底）
///
/// `<site>` 是 `VideoSite.key`（youtube / bilibili / tencent / iqiyi / youku /
/// mgtv / tiktok / twitter）。所以改一个选择器不再需要重新构建：存盘 → 设置里
/// 点"重新加载"（或 `POST /rules/refresh`）→ 重新加载页面即可生效。
///
/// **信任边界**：远程包的 CSS 直接生效（只影响显示）；远程包的 **JS 默认不生效**
/// ——它会被内联进页面上下文执行，等于把"浏览器里跑什么代码"交给规则源服务器。
/// 要放行必须在设置里显式打开"信任远程规则脚本"。本地覆盖文件的 JS 不受此限制：
/// 那是用户自己机器上的文件。
@MainActor
final class VideoAdRulesStore: ObservableObject {
    static let shared = VideoAdRulesStore()

    /// 规则来源，供设置界面与 `GET /rules` 显示。
    enum Source: String {
        case builtin
        case local
        case remote
    }

    struct SiteRules: Codable {
        var css: String?
        var js: String?
    }

    /// 远程规则包格式：
    /// `{"version":"2026-09-20","sites":{"youtube":{"css":"…","js":"…"}}}`
    struct RemoteBundle: Codable {
        var version: String?
        var updatedAt: String?
        var sites: [String: SiteRules]
    }

    /// 远程规则包地址。nil = 不启用远程层（默认）。
    /// 启用方式：把这里改成你的 raw 地址，或写 UserDefaults 键
    /// `videoAdRulesRemoteURL`（优先于本常量，便于自建源与自动化测试）。
    static let defaultRemoteURL: URL? = nil

    /// 远程包大小上限（防御性）：整包超过则拒绝，避免一条坏 URL 把内存/页面
    /// 撑爆。
    private static let maxBundleBytes = 512 * 1024
    /// 远程包自动检查间隔。
    private static let remoteCheckInterval: TimeInterval = 24 * 60 * 60

    // MARK: - Published state

    @Published private(set) var localOverrides: [String: SiteRules] = [:]
    @Published private(set) var remoteBundle: RemoteBundle?
    @Published private(set) var remoteFetchedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false

    /// 是否信任远程规则源下发的 JS。默认关（见文件头注释）。
    @Published private(set) var remoteScriptsTrusted: Bool

    private static let trustKey = "videoAdRulesTrustRemoteJS"
    private static let fetchedAtKey = "videoAdRulesRemoteFetchedAt"

    // MARK: - Locations

    /// 规则目录（本地覆盖与远程缓存都在这里）。
    static var rulesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base
            .appendingPathComponent("Desire", isDirectory: true)
            .appendingPathComponent("VideoAdRules", isDirectory: true)
    }

    private static var remoteDirectory: URL {
        rulesDirectory.appendingPathComponent("remote", isDirectory: true)
    }

    private static var remoteCacheURL: URL {
        remoteDirectory.appendingPathComponent("rules.json")
    }

    /// 远程源地址文件：一行 URL。**改这个文件 + 点"重新加载"即生效**，不用重启
    /// （UserDefaults 在被读过的进程里看不到外部改动，命令行写 defaults 那条路
    /// 只适合自动化测试重启后的场景）。
    private static var remoteSourceFileURL: URL {
        remoteDirectory.appendingPathComponent("source.txt")
    }

    /// 生效的远程源，按顺序取第一个可解析的：`remote/source.txt` →
    /// UserDefaults `videoAdRulesRemoteURL` → 编译期常量。
    var remoteURL: URL? {
        if let text = try? String(contentsOf: Self.remoteSourceFileURL, encoding: .utf8),
           let url = Self.parseURL(text) {
            return url
        }
        if let raw = UserDefaults.standard.string(forKey: "videoAdRulesRemoteURL"),
           let url = Self.parseURL(raw) {
            return url
        }
        return Self.defaultRemoteURL
    }

    private static func parseURL(_ raw: String) -> URL? {
        let trimmed = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }

    // MARK: - Lifecycle

    private init() {
        remoteScriptsTrusted = UserDefaults.standard.bool(forKey: Self.trustKey)
        remoteFetchedAt = UserDefaults.standard.object(forKey: Self.fetchedAtKey) as? Date
        prepareDirectory()
        reloadLocalRules()
        loadRemoteCacheFromDisk()
        scheduleRemoteCheckIfNeeded()
    }

    // MARK: - Resolution

    /// 缓存的远程包**只有在配置了源时才参与解析**：否则删掉远程源之后，旧
    /// 缓存会继续生效（等于规则被一条已删除的 URL 长久挟持）。源暂时不可达
    /// （网络故障）时缓存仍然生效，这是想要的离线行为。
    private var activeRemote: RemoteBundle? {
        remoteURL == nil ? nil : remoteBundle
    }

    func css(for site: VideoSite) -> String {
        if let local = localOverrides[site.key]?.css, !local.isEmpty { return local }
        if let remote = activeRemote?.sites[site.key]?.css, !remote.isEmpty { return remote }
        return site.css
    }

    func js(for site: VideoSite) -> String {
        if let local = localOverrides[site.key]?.js, !local.isEmpty { return local }
        if remoteScriptsTrusted,
           let remote = activeRemote?.sites[site.key]?.js,
           !remote.isEmpty {
            return remote
        }
        return site.pageScript
    }

    func source(for site: VideoSite) -> Source {
        if let local = localOverrides[site.key], local.css?.isEmpty == false || local.js?.isEmpty == false {
            return .local
        }
        if let remote = activeRemote?.sites[site.key], remote.css?.isEmpty == false || remote.js?.isEmpty == false {
            return .remote
        }
        return .builtin
    }

    /// 当前生效的远程包（nil = 未配置源）。供 `/rules` 报告。
    var appliedRemoteVersion: String? { activeRemote?.version }

    /// 一行状态摘要，给设置界面与 `/rules` 用。
    func statusLine() -> String {
        var parts: [String] = []
        let localKeys = VideoSite.allCases.filter { source(for: $0) == .local }.map(\.key)
        let remoteKeys = VideoSite.allCases.filter { source(for: $0) == .remote }.map(\.key)
        parts.append("builtin \(VideoSite.allCases.count - localKeys.count - remoteKeys.count)")
        if !localKeys.isEmpty { parts.append("local: \(localKeys.joined(separator: ", "))") }
        if !remoteKeys.isEmpty { parts.append("remote: \(remoteKeys.joined(separator: ", "))") }
        if let version = activeRemote?.version { parts.append("v\(version)") }
        if let fetched = remoteFetchedAt {
            parts.append(DateFormatter.localizedString(from: fetched, dateStyle: .short, timeStyle: .short))
        }
        if !remoteScriptsTrusted, activeRemote != nil { parts.append("remote JS off") }
        if let lastError { parts.append("⚠︎ \(lastError)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Script building（注入用；每次导航都会调用，所以规则改动无需重启）

    /// 规则代数：每次本地/远程规则变化就 +1。注入的 CSS/JS 都带上它——
    /// 页面里若还是旧代数，下一次导航（`didCommit`）会把 CSS 换成新的；
    /// 站点 JS 的外层包装器发现代数变了会清掉站点自己的"只跑一次"标志位，
    /// 让新规则重跑一遍。这样"改规则 → 重新加载 → 刷新页面"就真的生效，
    /// 不需要重开标签页（user script 只在 webview 创建时定格，这正是坑）。
    @Published private(set) var generation: Int = 0

    /// CSS 安装脚本。`replaceStale` 用于导航时的补投：页面里已有旧代数的
    /// `<style>` 就换掉，没有或代数相同就什么都不做（避免每页都重写 style）。
    func cssInstallScript(replaceStale: Bool) -> String {
        let css = VideoSite.allCases.map { self.css(for: $0) }.joined(separator: "\n")
        let escaped = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let gen = generation
        let guardLine = replaceStale
            ? "var cur = document.getElementById('desire-video-ad-css');" +
              "if (cur && cur.getAttribute('data-gen') === '\(gen)') return;" +
              "if (cur) cur.remove();"
            : "if (document.getElementById('desire-video-ad-css')) return;"
        return """
        (function() {
            \(guardLine)
            var s = document.createElement('style');
            s.id = 'desire-video-ad-css';
            s.setAttribute('data-gen', '\(gen)');
            s.textContent = '\(escaped)';
            (document.head || document.documentElement).appendChild(s);
        })();
        """
    }

    /// 某个站点的页面脚本（带代数包装）。host 不匹配任何站点时返回 nil。
    func pageJSScript(for host: String) -> String? {
        let h = host.lowercased()
        guard let site = VideoSite.allCases.first(where: { $0.matches(h) }) else { return nil }
        return pageJSScript(for: site)
    }

    func pageJSScript(for site: VideoSite) -> String {
        let gen = generation
        let body = js(for: site)
        return """
        (function() {
            var GEN = \(gen), SITE = '\(site.key)';
            window.__desireRulesGen = window.__desireRulesGen || {};
            if (window.__desireRulesGen[SITE] === GEN) return;
            window.__desireRulesGen[SITE] = GEN;
            // 规则换代：清掉站点脚本自己的"只跑一次"标志，让它按新规则重跑。
            window.\(site.guardFlag) = false;
            \(body)
        })();
        """
    }

    // MARK: - Local overrides

    /// 重新读取本地覆盖文件。文件缺失/读不动都静默回退到下一层。
    func reloadLocalRules() {
        prepareDirectory()
        var overrides: [String: SiteRules] = [:]
        let directory = Self.rulesDirectory
        for site in VideoSite.allCases {
            let css = read(directory.appendingPathComponent("\(site.key).css"))
            let js = read(directory.appendingPathComponent("\(site.key).js"))
            if css != nil || js != nil {
                overrides[site.key] = SiteRules(css: css, js: js)
            }
        }
        localOverrides = overrides
        generation += 1
    }

    private func read(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    func setRemoteScriptsTrusted(_ trusted: Bool) {
        guard trusted != remoteScriptsTrusted else { return }
        remoteScriptsTrusted = trusted
        UserDefaults.standard.set(trusted, forKey: Self.trustKey)
    }

    // MARK: - Remote bundle

    private func loadRemoteCacheFromDisk() {
        guard let data = try? Data(contentsOf: Self.remoteCacheURL),
              data.count <= Self.maxBundleBytes,
              let bundle = try? JSONDecoder().decode(RemoteBundle.self, from: data) else { return }
        remoteBundle = bundle
    }

    private func scheduleRemoteCheckIfNeeded() {
        guard remoteURL != nil else { return }
        if let fetched = remoteFetchedAt,
           Date().timeIntervalSince(fetched) < Self.remoteCheckInterval {
            return
        }
        Task { await refreshRemote() }
    }

    /// 拉取远程规则包并写入缓存。失败只记录 `lastError`（内置规则继续兜底），
    /// 不会让页面注入失败。
    func refreshRemote() async {
        guard let url = remoteURL else {
            lastError = nil
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw Refusal.http(http.statusCode)
            }
            guard data.count <= Self.maxBundleBytes else { throw Refusal.tooLarge(data.count) }
            let bundle = try JSONDecoder().decode(RemoteBundle.self, from: data)
            try? FileManager.default.createDirectory(
                at: Self.remoteCacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: Self.remoteCacheURL, options: .atomic)
            remoteBundle = bundle
            remoteFetchedAt = Date()
            generation += 1
            UserDefaults.standard.set(remoteFetchedAt, forKey: Self.fetchedAtKey)
            lastError = nil
        } catch {
            lastError = (error as? Refusal)?.message ?? error.localizedDescription
        }
    }

    /// 本地 + 远程一起重来一遍（设置里的"重新加载"按钮与 `/rules/refresh`）。
    func reloadAll() async {
        reloadLocalRules()
        await refreshRemote()
    }

    private enum Refusal: Error {
        case http(Int)
        case tooLarge(Int)

        var message: String {
            switch self {
            case .http(let code): "HTTP \(code)"
            case .tooLarge(let bytes): "rules.json too large (\(bytes) bytes)"
            }
        }
    }

    // MARK: - Directory helpers

    func revealRulesDirectory() {
        prepareDirectory()
        NSWorkspace.shared.activateFileViewerSelecting([Self.rulesDirectory])
    }

    /// 目录不存在就建，并写一份 README（只写一次）——用户与未来的 agent 都靠
    /// 它知道文件命名与优先级。
    private func prepareDirectory() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.rulesDirectory, withIntermediateDirectories: true)
        let readme = Self.rulesDirectory.appendingPathComponent("README.txt")
        guard !fm.fileExists(atPath: readme.path) else { return }
        let text = """
        Desire 视频广告拦截规则（热插拔）

        解析优先级（先命中先用）：本地覆盖文件 > 远程规则包 > 内置规则。

        本地覆盖：把 <site>.css / <site>.js 放在本目录即可生效。
          site ∈ youtube, bilibili, tencent, iqiyi, youku, mgtv, tiktok, twitter
          · youtube.css 替换内置的 YouTube 隐藏规则（会被注入 <style>）
          · youtube.js  替换内置的 YouTube 页面脚本（documentEnd 注入，直接内联执行）
        改完在「设置 ▸ 通用 ▸ 媒体 ▸ 视频广告规则」点“重新加载”，或重开页面。

        远程规则包：remote/rules.json，格式
          {"version":"2026-09-20","sites":{"youtube":{"css":"…","js":"…"}}}
        其中 CSS 直接生效；JS 只有在设置里打开“信任远程规则脚本”后才生效
        （远程 JS 会在页面上下文执行，等于信任该规则源）。
        远程源地址（按优先级）：本目录 remote/source.txt 里的 URL（一行，改完点
        “重新加载”即生效）→ UserDefaults 键 videoAdRulesRemoteURL → 代码常量
        VideoAdRulesStore.defaultRemoteURL。
        """
        try? text.write(to: readme, atomically: true, encoding: .utf8)
    }
}
