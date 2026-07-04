import Foundation

struct AddressSuggestion: Identifiable {
    enum Kind {
        case navigate
        case searchDefault
        case searchSuggestion
        case bookmark
        case history
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let url: String
    let domain: String?
}
