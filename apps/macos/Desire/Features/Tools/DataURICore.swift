import Foundation

/// Data URI 编解码——纯逻辑。
nonisolated enum DataURICore {
    struct Parsed {
        var mime: String
        var isBase64: Bool
        var data: Data
        var text: String?
    }

    static func make(text: String, mime: String = "text/plain") -> String {
        make(data: Data(text.utf8), mime: mime)
    }

    static func make(data: Data, mime: String = "application/octet-stream") -> String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }

    static func parse(_ raw: String) -> Result<Parsed, ToolboxError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else {
            return .failure(ToolboxError(message: "Not a data URI (must start with data:)"))
        }
        guard let comma = trimmed.firstIndex(of: ",") else {
            return .failure(ToolboxError(message: "Missing comma in data URI"))
        }
        let header = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<comma])
        let payload = String(trimmed[trimmed.index(after: comma)...])
        let parts = header.components(separatedBy: ";")
        let mime = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "text/plain"
        let isBase64 = parts.dropFirst().contains { $0.lowercased() == "base64" }
        let data: Data
        if isBase64 {
            var base64 = payload
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let padding = base64.count % 4
            if padding > 0 { base64 += String(repeating: "=", count: 4 - padding) }
            guard let decoded = Data(base64Encoded: base64) else {
                return .failure(ToolboxError(message: "Invalid base64 payload"))
            }
            data = decoded
        } else {
            guard let decoded = payload.removingPercentEncoding else {
                return .failure(ToolboxError(message: "Invalid percent-encoding"))
            }
            data = Data(decoded.utf8)
        }
        return .success(Parsed(mime: mime, isBase64: isBase64, data: data,
                               text: String(data: data, encoding: .utf8)))
    }
}
