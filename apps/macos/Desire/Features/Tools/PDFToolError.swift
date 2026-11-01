import Foundation

/// PDF 工具的用户可见错误（v0.8.33 文档批）。
nonisolated enum PDFToolError: LocalizedError {
    case cannotOpen(String)
    case passwordRequired(String)
    case wrongPassword(String)
    case noPages
    case invalidPageRange
    case writeFailed(String)
    case imageLoadFailed(String)
    case renderFailed(String)
    case locked(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let name):
            return String(localized: "Could not open \(name).")
        case .passwordRequired(let name):
            return String(localized: "\(name) is password-protected. Enter the password.")
        case .wrongPassword(let name):
            return String(localized: "Wrong password for \(name).")
        case .noPages:
            return String(localized: "No pages to write.")
        case .invalidPageRange:
            return String(localized: "Invalid page range.")
        case .writeFailed(let name):
            return String(localized: "Could not write \(name).")
        case .imageLoadFailed(let name):
            return String(localized: "Could not load \(name) as an image.")
        case .renderFailed(let name):
            return String(localized: "Could not render \(name).")
        case .locked(let name):
            return String(localized: "\(name) is locked.")
        }
    }
}
