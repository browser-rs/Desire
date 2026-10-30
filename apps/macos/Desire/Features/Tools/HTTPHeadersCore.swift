import Foundation

/// 常见 HTTP 请求/响应头速查——纯数据。
nonisolated enum HTTPHeadersCore {
    struct Header: Equatable, Sendable {
        var name: String
        var direction: String   // request / response / both
        var description: String
    }

    static let all: [Header] = [
        .init(name: "Accept", direction: "request", description: "客户端可接受的内容类型"),
        .init(name: "Accept-Encoding", direction: "request", description: "可接受的压缩算法（gzip/br）"),
        .init(name: "Authorization", direction: "request", description: "认证凭证（Bearer/Basic）"),
        .init(name: "Cookie", direction: "request", description: "携带的 Cookie"),
        .init(name: "Content-Type", direction: "both", description: "请求/响应体的媒体类型"),
        .init(name: "Content-Length", direction: "both", description: "请求/响应体的字节长度"),
        .init(name: "Host", direction: "request", description: "目标主机与端口（HTTP/1 必带）"),
        .init(name: "If-None-Match", direction: "request", description: "条件请求（配合 ETag）"),
        .init(name: "Origin", direction: "request", description: "请求来源（CORS 用）"),
        .init(name: "Referer", direction: "request", description: "来源页面地址"),
        .init(name: "User-Agent", direction: "request", description: "客户端标识"),
        .init(name: "Cache-Control", direction: "both", description: "缓存策略（max-age/no-cache）"),
        .init(name: "ETag", direction: "response", description: "资源版本标识（缓存协商）"),
        .init(name: "Location", direction: "response", description: "重定向目标地址"),
        .init(name: "Set-Cookie", direction: "response", description: "下发 Cookie"),
        .init(name: "Access-Control-Allow-Origin", direction: "response", description: "CORS 允许的来源"),
        .init(name: "Content-Disposition", direction: "response", description: "附件下载/内联展示"),
        .init(name: "Retry-After", direction: "response", description: "限流/维护后的重试时间"),
        .init(name: "Server", direction: "response", description: "服务器软件标识"),
        .init(name: "Strict-Transport-Security", direction: "response", description: "强制 HTTPS（HSTS）"),
        .init(name: "X-Frame-Options", direction: "response", description: "防点击劫持（frame-ancestors 替代）"),
        .init(name: "X-Request-ID", direction: "both", description: "请求追踪 ID"),
    ]

    static func search(_ query: String) -> [Header] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(needle)
                || $0.direction.contains(needle)
                || $0.description.contains(needle)
        }
    }
}
