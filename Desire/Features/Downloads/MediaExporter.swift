import CommonCrypto
import Foundation

/// Downloads media to the user's Downloads folder: direct files (mp4/webm/…)
/// and HLS playlists (m3u8 → segments → single concatenated file).
///
/// HLS notes:
/// - Master playlists are followed once to the highest-bandwidth variant.
/// - Relative segment URLs resolve against the playlist URL.
/// - EXT-X-MAP (fMP4 init segment) is prepended to the output, so fMP4
///   streams export as playable .mp4; MPEG-TS streams concatenate as .ts.
/// - AES-128 encrypted segments (EXT-X-KEY) are decrypted with CommonCrypto;
///   the key is fetched with the same Referer/UA as the segments. SAMPLE-AES
///   is not supported.
/// - Live playlists (no EXT-X-ENDLIST) export the segments available now,
///   with a warning in the result.
///
/// Runs through its own URLSession (NOT WebKit's): the player's CDN usually
/// serves segments without cookies, and hotlink protection is handled by
/// sending the page URL as Referer plus the webview's Safari user agent.
@MainActor
enum MediaExporter {
    struct Result {
        let fileURL: URL
        let segmentCount: Int
        let bytes: Int64
        let warnings: [String]

        var displayBytes: String {
            let mb = Double(bytes) / 1_048_576
            return mb >= 1 ? String(format: "%.1f MB", mb) : "\(bytes / 1024) KB"
        }
    }

    enum ExportError: LocalizedError {
        case notAPlaylist
        case unsupportedEncryption(String)
        case tooManySegmentFailures
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notAPlaylist: "URL did not return an m3u8 playlist or a media file"
            case .unsupportedEncryption(let method): "Playlist uses unsupported encryption: \(method)"
            case .tooManySegmentFailures: "Too many segments failed to download"
            case .timedOut: "Export exceeded the 30-minute time limit"
            }
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    // MARK: - Entry point

    /// Exports `url` (direct media file or HLS playlist) into ~/Downloads.
    /// `progress` reports (completedSegments, totalSegments); total is 1 for
    /// direct files. Hard-capped at 30 minutes.
    static func download(
        url: URL,
        referer: URL?,
        userAgent: String?,
        fileNameHint: String?,
        progress: @MainActor @escaping (Int, Int) -> Void
    ) async throws -> Result {
        let started = Date()
        let deadline = started.addingTimeInterval(30 * 60)

        func deadlineCheck() throws {
            guard Date() < deadline else { throw ExportError.timedOut }
        }

        if url.pathExtension.lowercased() == "m3u8" {
            return try await exportHLS(
                url: url, referer: referer, userAgent: userAgent,
                fileNameHint: fileNameHint, deadlineCheck: deadlineCheck,
                progress: progress
            )
        }

        // Could be a master/variant playlist without the extension — sniff.
        let (data, response) = try await fetch(url: url, referer: referer, userAgent: userAgent)
        if let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") {
            return try await exportHLS(
                url: url, playlistText: text, referer: referer, userAgent: userAgent,
                fileNameHint: fileNameHint, deadlineCheck: deadlineCheck,
                progress: progress
            )
        }

        // Direct file: stream to disk.
        let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let fileURL = try destinationURL(for: url, hint: fileNameHint, isMP4: mime.contains("mp4"))
        try data.write(to: fileURL)
        progress(1, 1)
        return Result(
            fileURL: fileURL,
            segmentCount: 1,
            bytes: Int64(data.count),
            warnings: mime.isEmpty ? [] : []
        )
    }

    // MARK: - HLS

    private static func exportHLS(
        url: URL,
        playlistText: String? = nil,
        referer: URL?,
        userAgent: String?,
        fileNameHint: String?,
        deadlineCheck: () throws -> Void,
        progress: @MainActor (Int, Int) -> Void
    ) async throws -> Result {
        var warnings: [String] = []
        var text = playlistText
        var playlistURL = url
        if text == nil {
            let (data, _) = try await fetch(url: url, referer: referer, userAgent: userAgent)
            guard let fetched = String(data: data, encoding: .utf8), fetched.contains("#EXTM3U") else {
                throw ExportError.notAPlaylist
            }
            text = fetched
        }
        guard let playlistText = text else { throw ExportError.notAPlaylist }

        // Master playlist → follow the highest-bandwidth variant once.
        if playlistText.contains("#EXT-X-STREAM-INF") {
            let lines = playlistText.components(separatedBy: .newlines)
            var best: (bandwidth: Int, url: URL)?
            var pendingBandwidth = 0
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#EXT-X-STREAM-INF") {
                    pendingBandwidth = Int(attribute("BANDWIDTH", in: trimmed) ?? "") ?? 0
                } else if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                    if let variant = URL(string: trimmed, relativeTo: url),
                       let abs = URL(string: variant.absoluteString),
                       pendingBandwidth > (best?.bandwidth ?? -1) {
                        best = (pendingBandwidth, abs)
                    }
                    pendingBandwidth = 0
                }
            }
            guard let variant = best?.url else { throw ExportError.notAPlaylist }
            let (data, _) = try await fetch(url: variant, referer: referer, userAgent: userAgent)
            guard let fetched = String(data: data, encoding: .utf8) else { throw ExportError.notAPlaylist }
            text = fetched
            playlistURL = variant
            warnings.append("master playlist → selected variant \(variant.lastPathComponent)")
        }
        guard let finalText = text else { throw ExportError.notAPlaylist }

        // Parse the media playlist.
        let lines = finalText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var segments: [(url: URL, index: Int)] = []
        var initSegment: URL?
        var keyURI: String?
        var keyIV: Data?
        var mediaSequence = 0
        var hasEndList = false

        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let method = attribute("METHOD", in: line)
                if method == "NONE" {
                    keyURI = nil
                } else if method == "AES-128" {
                    keyURI = attribute("URI", in: line)
                    if let ivHex = attribute("IV", in: line) {
                        keyIV = Self.data(fromHex: ivHex)
                    }
                } else if let method, !method.isEmpty {
                    throw ExportError.unsupportedEncryption(method)
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                if let uri = attribute("URI", in: line) {
                    initSegment = URL(string: uri, relativeTo: playlistURL).flatMap { URL(string: $0.absoluteString) }
                }
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                hasEndList = true
            } else if line.hasPrefix("#") {
                continue
            } else if !line.isEmpty {
                if let seg = URL(string: line, relativeTo: playlistURL),
                   let abs = URL(string: seg.absoluteString) {
                    segments.append((abs, mediaSequence + segments.count))
                }
            }
        }
        guard !segments.isEmpty else { throw ExportError.notAPlaylist }
        if !hasEndList {
            warnings.append("live stream (no ENDLIST) — exporting the segments available now")
        }

        // Fetch the AES key once, if any.
        var keyData: Data?
        if let keyURI {
            guard let keyURL = URL(string: keyURI, relativeTo: playlistURL).flatMap({ URL(string: $0.absoluteString) }) else {
                throw ExportError.unsupportedEncryption("unreadable key URI")
            }
            let (data, _) = try await fetch(url: keyURL, referer: referer, userAgent: userAgent)
            keyData = data
        }

        // Destination: .mp4 when fMP4 (EXT-X-MAP), else .ts (MPEG-TS).
        let isFMP4 = initSegment != nil && (initSegment!.pathExtension.lowercased() == "mp4" || initSegment!.pathExtension.lowercased() == "m4s")
        let fileURL = try destinationURL(for: playlistURL, hint: fileNameHint, isMP4: isFMP4)

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        if let initSegment {
            let (data, _) = try await fetch(url: initSegment, referer: referer, userAgent: userAgent)
            try handle.write(contentsOf: data)
        }

        var bytes: Int64 = 0
        var done = 0
        var failures = 0
        for segment in segments {
            try deadlineCheck()
            var data: Data?
            for attempt in 0..<2 {
                do {
                    let (fetched, _) = try await fetch(url: segment.url, referer: referer, userAgent: userAgent)
                    data = fetched
                    break
                } catch {
                    if attempt == 1 { failures += 1 }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            guard var payload = data else {
                if failures >= 5 { throw ExportError.tooManySegmentFailures }
                continue
            }
            if let keyData {
                let iv = keyIV ?? Self.sequenceIV(mediaSequence + done)
                payload = try Self.decrypt(payload, key: keyData, iv: iv)
            }
            try handle.write(contentsOf: payload)
            bytes += Int64(payload.count)
            done += 1
            progress(done, segments.count)
        }

        return Result(
            fileURL: fileURL,
            segmentCount: done,
            bytes: bytes,
            warnings: failures > 0
                ? warnings + ["\(failures) segment(s) failed and were skipped"]
                : warnings
        )
    }

    // MARK: - Plumbing

    private static func fetch(url: URL, referer: URL?, userAgent: String?) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ExportError.notAPlaylist
        }
        return (data, response)
    }

    private static func destinationURL(for source: URL, hint: String?, isMP4: Bool) throws -> URL {
        let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let ext = isMP4 ? "mp4" : (source.pathExtension.lowercased() == "mp4" ? "mp4" : "ts")
        var base = hint ?? source.deletingPathExtension().lastPathComponent
        base = base.components(separatedBy: "?").first ?? base
        base = base.replacingOccurrences(of: "/", with: "-")
        if base.isEmpty { base = "export-\(Int(Date().timeIntervalSince1970))" }
        var candidate = downloads.appendingPathComponent("\(base).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = downloads.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// `KEY="value"` extractor for EXT attribute lines (double-quoted values).
    private static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: "\(name)=\"") else {
            // Unquoted form (BANDWIDTH=1234)
            guard let eq = line.range(of: "\(name)=") else { return nil }
            let tail = line[eq.upperBound...]
            let value = tail.prefix { !$0.isWhitespace && $0 != "," }
            return value.isEmpty ? nil : String(value)
        }
        let tail = line[range.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        return String(tail[..<end])
    }

    private static func data(fromHex hex: String) -> Data? {
        var string = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? String(hex.dropFirst(2)) : hex
        guard string.count % 2 == 0 else { return nil }
        var data = Data()
        while !string.isEmpty {
            let pair = string.prefix(2)
            guard let byte = UInt8(pair, radix: 16) else { return nil }
            data.append(byte)
            string = String(string.dropFirst(2))
        }
        return data
    }

    /// Default IV when EXT-X-KEY omits one: the 128-bit big-endian media
    /// sequence number of the segment (per the HLS spec).
    private static func sequenceIV(_ sequence: Int) -> Data {
        var bigEndianSequence = UInt64(sequence).bigEndian
        var iv = Data(count: 8)
        withUnsafeBytes(of: &bigEndianSequence) { iv.append(contentsOf: $0) }
        iv.insert(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0], at: 0)
        return iv
    }

    private static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 16 else { throw ExportError.unsupportedEncryption("key is \(key.count) bytes") }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                iv.withUnsafeBytes { ivPtr in
                    key.withUnsafeBytes { keyPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, data.count,
                            outPtr.baseAddress, outPtr.count, &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ExportError.unsupportedEncryption("CCCrypt status \(status)") }
        out.removeSubrange(moved..<out.count)
        return out
    }
}
