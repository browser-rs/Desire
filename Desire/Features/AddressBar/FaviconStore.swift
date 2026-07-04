import AppKit
import Foundation

@MainActor
class FaviconStore {
    static let shared = FaviconStore()

    private var memoryCache: [String: NSImage] = [:]
    private let diskCacheDir: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        diskCacheDir = caches.appendingPathComponent("DesireFavicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)
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

    func favicon(for urlString: String) async -> NSImage? {
        guard let domain = Self.domainKey(from: urlString) else { return nil }

        if let cached = memoryCache[domain] {
            return cached
        }

        let diskPath = diskCacheDir.appendingPathComponent("\(sanitized(domain)).bin")
        if FileManager.default.fileExists(atPath: diskPath.path),
           let data = try? Data(contentsOf: diskPath),
           let img = NSImage(data: data) {
            memoryCache[domain] = img
            return img
        }

        // Try multiple favicon sources in order of reliability
        let sources = [
            "https://www.google.com/s2/favicons?domain=\(domain)&sz=64",
            "https://icons.duckduckgo.com/ip3/\(domain).ico",
            "https://\(domain)/favicon.ico",
            "https://www.\(domain)/favicon.ico"
        ]

        for source in sources {
            guard let url = URL(string: source) else { continue }
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { continue }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { continue }
            // Reject tiny 1x1 placeholder images that some CDNs return
            if data.count < 32 { continue }
            if let img = NSImage(data: data), img.size.width >= 4 {
                memoryCache[domain] = img
                try? data.write(to: diskPath, options: .atomic)
                return img
            }
        }
        return nil
    }

    private func sanitized(_ domain: String) -> String {
        domain.replacingOccurrences(of: "/", with: "_")
               .replacingOccurrences(of: ":", with: "_")
    }
}
