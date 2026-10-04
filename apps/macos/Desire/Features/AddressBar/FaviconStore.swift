import AppKit
import Foundation

@MainActor
class FaviconStore {
    static let shared = FaviconStore()

    /// Bounded in-memory cache. `NSCache` auto-evicts under memory pressure
    /// (replacing the previous unbounded `[String: NSImage]` that grew forever
    /// — one entry per distinct visited domain, never released). Keys are
    /// domain strings, values are the decoded favicons.
    private let memoryCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()
    private let diskCacheDir: URL
    /// Disk-cache entry TTL. Favicons rarely change but the cache shouldn't
    /// grow unbounded forever; entries older than this are swept on launch.
    private let diskCacheTTL: TimeInterval = 30 * 24 * 3600

    /// One fetch task per domain — N suggestion rows for the same host used
    /// to each fire their own 4-source fetch chain in parallel.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    /// Domains with no favicon, with a retry-after date. Without this, every
    /// render of a suggestion row for such a domain re-fired the whole
    /// 4-source chain.
    private var negativeUntil: [String: Date] = [:]
    private let negativeTTL: TimeInterval = 10 * 60

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        diskCacheDir = caches.appendingPathComponent("DesireFavicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)
        // Sweep expired disk entries off-main on init so the cache doesn't
        // grow forever (one file per distinct domain visited).
        Task.detached(priority: .utility) { [diskCacheDir, ttl = diskCacheTTL] in
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(at: diskCacheDir,
                                                            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let cutoff = Date().addingTimeInterval(-ttl)
            for entry in entries {
                if let attrs = try? fm.attributesOfItem(atPath: entry.path),
                   let mtime = attrs[.modificationDate] as? Date, mtime < cutoff {
                    try? fm.removeItem(at: entry)
                }
            }
        }
    }

    static func domainKey(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate),
              let host = url.host,
              host.contains(".") else { return nil }
        return host
    }

    /// `www.` 变体只对注册域名有意义——对 localhost / IP 字面量
    /// (`127.0.0.1`、`[::1]`)生成的变体 URL 不会有任何服务器应答。
    private static func isHostLiteral(_ host: String) -> Bool {
        host == "localhost"
            || host.contains(":")  // bracketed IPv6
            || !host.isEmpty && host.allSatisfy { $0.isNumber || $0 == "." }
    }

    func favicon(for urlString: String) async -> NSImage? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let pageURL = trimmed.contains("://")
            ? URL(string: trimmed)
            : trimmed.isEmpty ? nil : URL(string: "https://" + trimmed)
        guard let domain = Self.domainKey(from: urlString) else { return nil }
        let key = domain as NSString

        if let cached = memoryCache.object(forKey: key) {
            return cached
        }
        if let until = negativeUntil[domain], until > Date() {
            return nil
        }
        if let running = inFlight[domain] {
            return await running.value
        }

        let path = diskPath(for: domain)
        let task = Task<NSImage?, Never> { [weak self] in
            await self?.loadFavicon(domain: domain, pageURL: pageURL, diskPath: path)
        }
        inFlight[domain] = task
        let image = await task.value
        inFlight[domain] = nil
        return image
    }

    private func diskPath(for domain: String) -> URL {
        diskCacheDir.appendingPathComponent("\(sanitized(domain)).bin")
    }

    /// The actual fetch pipeline, run exactly once per domain at a time.
    private func loadFavicon(domain: String, pageURL: URL?, diskPath: URL) async -> NSImage? {
        let key = domain as NSString
        // Disk read off-main: cache misses shouldn't block the main actor
        // (one miss per address-suggestion row on first encounter).
        let path = diskPath.path
        let diskData: Data? = await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }.value
        if let img = await Self.decode(diskData) {
            memoryCache.setObject(img, forKey: key)
            return img
        }

        // Try multiple favicon sources in order of reliability. Third-party
        // services key by bare host; the direct probes use the page's own
        // origin — rebuilding them from the bare host lost custom ports and
        // forced https (`http://127.0.0.1:8877` → `https://127.0.0.1`, and
        // even `https://www.127.0.0.1`, which no server ever answers).
        var sources = [
            "https://www.google.com/s2/favicons?domain=\(domain)&sz=64",
            "https://icons.duckduckgo.com/ip3/\(domain).ico"
        ]
        if let pageURL, let scheme = pageURL.scheme, let host = pageURL.host,
           scheme.hasPrefix("http") {
            // origin = scheme://host[:port] — 保留自定义端口与 http。
            let port = pageURL.port.map { ":\($0)" } ?? ""
            sources.append("\(scheme)://\(host)\(port)/favicon.ico")
        }
        if let host = pageURL?.host, !Self.isHostLiteral(host) {
            sources.append("https://www.\(domain)/favicon.ico")
        }

        for source in sources {
            guard let url = URL(string: source) else { continue }
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { continue }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { continue }
            if let img = await Self.decode(data) {
                memoryCache.setObject(img, forKey: key)
                try? data.write(to: diskPath, options: .atomic)
                return img
            }
        }

        // Remember the failure so suggestion rows for this domain stop
        // re-firing the whole chain on every render.
        negativeUntil[domain] = Date().addingTimeInterval(negativeTTL)
        if negativeUntil.count > 256 {
            let cutoff = Date()
            negativeUntil = negativeUntil.filter { $0.value > cutoff }
        }
        return nil
    }

    /// Decodes image data off the main actor (NSImage(data:) of a favicon
    /// is real work; N rows decoding on main hiccuped the UI) and rejects
    /// tiny 1x1 placeholders some CDNs return.
    private static func decode(_ data: Data?) async -> NSImage? {
        guard let data, data.count >= 32 else { return nil }
        let image = await Task.detached(priority: .userInitiated) { NSImage(data: data) }.value
        guard let image, image.size.width >= 4 else { return nil }
        return image
    }

    private func sanitized(_ domain: String) -> String {
        domain.replacingOccurrences(of: "/", with: "_")
               .replacingOccurrences(of: ":", with: "_")
    }
}
