import AppKit
import Combine
import SwiftUI

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

        guard let url = URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=32") else {
            return nil
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let img = NSImage(data: data) {
                memoryCache[domain] = img
                try? data.write(to: diskPath, options: .atomic)
                return img
            }
        } catch {
            return nil
        }
        return nil
    }

    private func sanitized(_ domain: String) -> String {
        domain.replacingOccurrences(of: "/", with: "_")
               .replacingOccurrences(of: ":", with: "_")
    }
}

struct FaviconView: View {
    let urlString: String
    var size: CGFloat = 16

    @State private var image: NSImage?
    @State private var loadedDomain: String?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: FaviconStore.domainKey(from: urlString)) {
            let key = FaviconStore.domainKey(from: urlString)
            if loadedDomain != key {
                image = nil
                loadedDomain = key
                if key != nil {
                    image = await FaviconStore.shared.favicon(for: urlString)
                }
            }
        }
    }
}
