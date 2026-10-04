import Foundation

/// A media resource (video/audio/stream playlist) observed on a page.
///
/// Two detection paths feed `BrowserState.detectedMedia`:
/// - network sniffing (`media-sniffer.js` hooks fetch/XHR at documentStart
///   and reports every media-typed response — this is what catches the real
///   CDN URLs behind blob:-based players), and
/// - on-demand DOM/meta scanning (`__desireScanMedia` in dom-tools.js:
///   <video>/<source>/<audio> srcs, media-file links, og:video, JSON-LD).
struct MediaResource: Identifiable, Hashable {
    enum Kind: String {
        case video
        case audio
        /// Playlist or manifest (HLS m3u8 / DASH mpd).
        case stream
    }

    let url: String
    let kind: Kind
    let mime: String
    let sizeBytes: Int
    /// How it was found: "fetch", "xhr" (network sniffing) or "dom", "link",
    /// "meta" (DOM/meta scanning). Free-form — display only.
    let source: String
    let detectedAt: Date

    var id: String { url }

    /// blob: URLs only work inside the page that minted them — they can't be
    /// downloaded or opened elsewhere. The sniffer never reports them; the
    /// DOM scanner may (a <video src="blob:…"> player), and the UI/tool says
    /// so instead of handing the agent a dead address.
    var isBlob: Bool { url.hasPrefix("blob:") }

    var displaySize: String? {
        guard sizeBytes > 0 else { return nil }
        let mb = Double(sizeBytes) / 1_048_576
        return mb >= 1 ? String(format: "%.1f MB", mb) : "\(sizeBytes / 1024) KB"
    }
}
