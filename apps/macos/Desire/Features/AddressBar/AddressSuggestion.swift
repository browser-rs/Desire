import Foundation

struct AddressSuggestion: Identifiable {
    enum Kind: String {
        case navigate
        case searchDefault
        case searchSuggestion
        case bookmark
        case history
    }

    let kind: Kind
    let title: String
    let url: String
    let domain: String?

    /// Content-stable identity: the same (kind, url) pair keeps its id
    /// across rebuilds, so SwiftUI's ForEach diffs rows incrementally
    /// instead of treating every keystroke's rebuild as all-new rows.
    var id: String { "\(kind.rawValue)|\(url)" }
}
