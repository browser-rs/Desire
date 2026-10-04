import Foundation

/// A one-shot "upload this file" intent armed by the agent's setUploadFile
/// tool. When the armed file's page opens the native file picker
/// (WKUIDelegate.runOpenPanel), the intent is consumed instead: the picker
/// never appears and the file is submitted directly — which is how the
/// agent can drive uploads on bilibili / YouTube / Douyin upload pages
/// (their pickers are triggered by a click on the page's file input).
@MainActor
final class UploadIntent {
    static let shared = UploadIntent()

    private var pending: [URL] = []

    var isArmed: Bool { !pending.isEmpty }

    func arm(_ urls: [URL]) {
        pending = urls
    }

    /// Returns (and disarms) the pending file URLs. Respects the picker's
    /// constraints: collapses to a single file when multi-select is off.
    func consume(allowMultiple: Bool) -> [URL]? {
        guard !pending.isEmpty else { return nil }
        let urls = pending
        pending = []
        if urls.count > 1 && !allowMultiple {
            return [urls[0]]
        }
        return urls
    }
}
