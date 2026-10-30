import Foundation

/// IPv4 / CIDR 计算——纯逻辑。
nonisolated enum CIDRCore {
    struct Info: Equatable, Sendable {
        var input: String
        var prefix: Int
        var network: String
        var broadcast: String
        var mask: String
        var firstHost: String
        var lastHost: String
        var hostCount: UInt64
        var isPrivate: Bool
    }

    static func parseIPv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let byte = UInt32(part), byte <= 255 else { return nil }
            value = value << 8 | byte
        }
        return value
    }

    static func formatIPv4(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    static func parse(_ raw: String) -> Result<Info, ToolboxError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else {
            return .failure(ToolboxError(message: "Format: 192.168.1.0/24"))
        }
        let prefix: Int
        if parts.count == 2 {
            guard let value = Int(parts[1]), (0...32).contains(value) else {
                return .failure(ToolboxError(message: "Prefix must be 0–32"))
            }
            prefix = value
        } else {
            prefix = 32
        }
        guard let address = parseIPv4(String(parts[0])) else {
            return .failure(ToolboxError(message: "Invalid IPv4 address"))
        }
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - UInt32(prefix))
        let network = address & mask
        let broadcast = network | ~mask
        let hosts: UInt64
        if prefix >= 31 {
            hosts = prefix == 32 ? 1 : 2
        } else {
            hosts = (UInt64(1) << (32 - UInt64(prefix))) - 2
        }
        let first: UInt32 = prefix >= 31 ? network : network + 1
        let last: UInt32 = prefix >= 31 ? broadcast : broadcast - 1
        let isPrivate = (network & 0xFF000000) == 0x0A000000
            || (network & 0xFFF00000) == 0xAC100000
            || (network & 0xFFFF0000) == 0xC0A80000
        return .success(Info(input: trimmed, prefix: prefix,
                             network: formatIPv4(network),
                             broadcast: formatIPv4(broadcast),
                             mask: formatIPv4(mask),
                             firstHost: formatIPv4(first),
                             lastHost: formatIPv4(last),
                             hostCount: hosts,
                             isPrivate: isPrivate))
    }
}

/// 常见 HTTP 状态码说明。
nonisolated enum HTTPStatusCore {
    static let all: [(code: Int, title: String, description: String)] = [
        (100, "Continue", "客户端应继续请求"),
        (101, "Switching Protocols", "服务器应客户端要求切换协议"),
        (200, "OK", "请求成功"),
        (201, "Created", "资源已创建"),
        (202, "Accepted", "请求已接受，尚未处理完"),
        (204, "No Content", "成功但无返回内容"),
        (206, "Partial Content", "返回部分内容（断点续传）"),
        (301, "Moved Permanently", "资源永久重定向"),
        (302, "Found", "资源临时重定向"),
        (303, "See Other", "用 GET 查看另一个地址"),
        (304, "Not Modified", "缓存仍然有效"),
        (307, "Temporary Redirect", "保持方法的临时重定向"),
        (308, "Permanent Redirect", "保持方法的永久重定向"),
        (400, "Bad Request", "请求格式错误"),
        (401, "Unauthorized", "需要登录/凭证无效"),
        (403, "Forbidden", "无权限访问"),
        (404, "Not Found", "资源不存在"),
        (405, "Method Not Allowed", "方法不被允许"),
        (408, "Request Timeout", "请求超时"),
        (409, "Conflict", "资源冲突"),
        (410, "Gone", "资源已永久删除"),
        (413, "Payload Too Large", "请求体过大"),
        (415, "Unsupported Media Type", "不支持的媒体类型"),
        (422, "Unprocessable Entity", "语义校验失败"),
        (429, "Too Many Requests", "请求过于频繁（限流）"),
        (500, "Internal Server Error", "服务器内部错误"),
        (501, "Not Implemented", "服务器不支持该功能"),
        (502, "Bad Gateway", "网关收到无效响应"),
        (503, "Service Unavailable", "服务暂不可用"),
        (504, "Gateway Timeout", "网关超时"),
        (505, "HTTP Version Not Supported", "不支持的 HTTP 版本"),
    ]

    static func lookup(_ code: Int) -> (code: Int, title: String, description: String)? {
        all.first { $0.code == code }
    }

    static func search(_ query: String) -> [(code: Int, title: String, description: String)] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter {
            String($0.code).contains(needle)
                || $0.title.lowercased().contains(needle)
                || $0.description.contains(needle)
        }
    }
}

/// 常见扩展名 ↔ MIME。
nonisolated enum MIMECore {
    static let table: [String: String] = [
        "html": "text/html", "htm": "text/html", "css": "text/css",
        "js": "text/javascript", "mjs": "text/javascript", "json": "application/json",
        "xml": "application/xml", "txt": "text/plain", "md": "text/markdown",
        "csv": "text/csv", "pdf": "application/pdf", "zip": "application/zip",
        "gz": "application/gzip", "tar": "application/x-tar", "7z": "application/x-7z-compressed",
        "rar": "application/vnd.rar", "png": "image/png", "jpg": "image/jpeg",
        "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "svg": "image/svg+xml", "heic": "image/heic", "tiff": "image/tiff",
        "mp3": "audio/mpeg", "wav": "audio/wav", "m4a": "audio/mp4",
        "mp4": "video/mp4", "webm": "video/webm", "mov": "video/quicktime",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf",
        "doc": "application/msword", "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls": "application/vnd.ms-excel", "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt": "application/vnd.ms-powerpoint", "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ]

    static func mime(forExtension ext: String) -> String? {
        table[ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))]
    }

    static func extensions(forMIME mime: String) -> [String] {
        table.filter { $0.value == mime.lowercased() }.map(\.key).sorted()
    }
}

/// 简易 User-Agent 解析（浏览器 / 系统 / 内核）。
nonisolated enum UACore {
    struct Info: Equatable, Sendable {
        var browser: String
        var browserVersion: String
        var os: String
        var engine: String
    }

    static func parse(_ ua: String) -> Info? {
        let text = ua.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        func firstMatch(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        var browser = "Unknown"
        var version = ""
        if text.contains("Edg/") {
            browser = "Edge"; version = firstMatch("Edg/([\\d.]+)") ?? ""
        } else if text.contains("OPR/") {
            browser = "Opera"; version = firstMatch("OPR/([\\d.]+)") ?? ""
        } else if text.contains("Chrome/") {
            browser = "Chrome"; version = firstMatch("Chrome/([\\d.]+)") ?? ""
        } else if text.contains("Firefox/") {
            browser = "Firefox"; version = firstMatch("Firefox/([\\d.]+)") ?? ""
        } else if text.contains("Version/") && text.contains("Safari/") {
            browser = "Safari"; version = firstMatch("Version/([\\d.]+)") ?? ""
        }
        let os: String
        if text.contains("iPhone") { os = "iOS" }
        else if text.contains("iPad") { os = "iPadOS" }
        else if text.contains("Android") { os = "Android" }
        else if text.contains("Mac OS X") { os = "macOS" }
        else if text.contains("Windows") { os = "Windows" }
        else if text.contains("Linux") { os = "Linux" }
        else { os = "Unknown" }
        let engine: String
        if text.contains("Gecko/") { engine = "Gecko" }
        else if text.contains("AppleWebKit/") { engine = "WebKit" }
        else { engine = "Unknown" }
        return Info(browser: browser, browserVersion: version, os: os, engine: engine)
    }
}
