import Foundation

struct NetworkRequest: Identifiable, Codable {
    let id: UUID
    let url: String
    let method: String
    let statusCode: Int?
    let statusText: String?
    let mimeType: String?
    let startTime: Date
    let endTime: Date?
    let duration: TimeInterval?
    /// 资源计时的分段（秒）；拿不到的段为 nil。
    struct Timing: Codable, Hashable {
        var blocked: Double?
        var dns: Double?
        var connect: Double?
        var tls: Double?
        var ttfb: Double?
        var download: Double?
    }

    let timing: Timing?
    /// 命中缓存（PerformanceResourceTiming：transferSize 为 0 但解出了内容）。
    let fromCache: Bool?

    /// 传输字节数（PerformanceObserver / fetch 钩子提供；导航路径用
    /// `expectedContentLength`）。仅用于面板汇总与排序。
    let size: Int64?
    let requestHeaders: [String: String]?
    let responseHeaders: [String: String]?
    let requestBody: String?
    let responseBody: String?
    let resourceType: ResourceType
    let failed: Bool
    let errorMessage: String?
    /// 发起这条请求的标签页（面板是 app 级共享 store，靠它按标签页过滤；
    /// 桥注入/外部来源可以为 nil）。
    let tabID: UUID?
    /// 发起者：页面里调用它的位置（`url:行`）。只有被钩住的 fetch/XHR/WS/SSE
    /// 拿得到——资源计时的条目没有调用栈。
    let initiator: String?
    /// 长连接（WebSocket / SSE）：不会"完成"，消息以 `frames` 累积。
    let streaming: Bool
    /// WebSocket / SSE 的消息帧（上限见 DevToolsStore）。
    let frames: [Frame]

    /// 一条消息帧。
    struct Frame: Codable, Hashable, Identifiable {
        let id: UUID
        let direction: Direction
        let payload: String
        let timestamp: Date

        enum Direction: String, Codable {
            case inbound = "in"
            case outbound = "out"
            case system = "system"
        }

        init(direction: Direction, payload: String) {
            self.id = UUID()
            self.direction = direction
            self.payload = payload
            self.timestamp = Date()
        }
    }

    /// 追加一帧（超出上限时丢最旧的）。
    func addingFrame(_ frame: Frame, cap: Int) -> NetworkRequest {
        var next = frames + [frame]
        if next.count > cap { next.removeFirst(next.count - cap) }
        return replacing(frames: next)
    }

    /// 只换 `frames` 的副本（其余字段原样带走）。
    private func replacing(frames: [Frame]) -> NetworkRequest {
        NetworkRequest(
            id: id,
            url: url,
            method: method,
            statusCode: statusCode,
            statusText: statusText,
            mimeType: mimeType,
            startTime: startTime,
            endTime: endTime,
            duration: duration,
            timing: timing,
            fromCache: fromCache,
            size: size,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            requestBody: requestBody,
            responseBody: responseBody,
            resourceType: resourceType,
            failed: failed,
            errorMessage: errorMessage,
            tabID: tabID,
            initiator: initiator,
            streaming: streaming,
            frames: frames
        )
    }

    /// 排序键：`Table` 的 `value:` 列要求非可选 `Comparable`，而这三个字段在
    /// 请求未完成时是 nil。用 0 兜底，未完成/无值的行自然排在最前/最后。
    var sortStatusCode: Int { statusCode ?? 0 }
    var sortSize: Int64 { size ?? 0 }
    var sortDuration: Double { duration ?? 0 }

    enum ResourceType: String, Codable, CaseIterable {
        case document = "document"
        case script = "script"
        case stylesheet = "stylesheet"
        case image = "image"
        case font = "font"
        case media = "media"
        case xhr = "xhr"
        case fetch = "fetch"
        case websocket = "websocket"
        case other = "other"
    }

    init(
        url: String,
        method: String,
        resourceType: ResourceType,
        requestHeaders: [String: String]? = nil,
        requestBody: String? = nil,
        tabID: UUID? = nil,
        initiator: String? = nil,
        streaming: Bool = false
    ) {
        self.tabID = tabID
        self.initiator = initiator
        self.streaming = streaming
        self.frames = []
        self.id = UUID()
        self.url = url
        self.method = method
        self.statusCode = nil
        self.statusText = nil
        self.mimeType = nil
        self.startTime = Date()
        self.endTime = nil
        self.duration = nil
        self.timing = nil
        self.fromCache = nil
        self.size = nil
        self.requestHeaders = requestHeaders
        self.responseHeaders = nil
        self.responseBody = nil
        self.requestBody = requestBody
        self.resourceType = resourceType
        self.failed = false
        self.errorMessage = nil
    }

    private init(
        id: UUID,
        url: String,
        method: String,
        statusCode: Int?,
        statusText: String?,
        mimeType: String?,
        startTime: Date,
        endTime: Date?,
        duration: TimeInterval?,
        timing: Timing?,
        fromCache: Bool?,
        size: Int64?,
        requestHeaders: [String: String]?,
        responseHeaders: [String: String]?,
        requestBody: String?,
        responseBody: String?,
        resourceType: ResourceType,
        failed: Bool,
        errorMessage: String?,
        tabID: UUID?,
        initiator: String? = nil,
        streaming: Bool = false,
        frames: [Frame] = []
    ) {
        self.tabID = tabID
        self.initiator = initiator
        self.streaming = streaming
        self.frames = frames
        self.id = id
        self.url = url
        self.method = method
        self.statusCode = statusCode
        self.statusText = statusText
        self.mimeType = mimeType
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.timing = timing
        self.fromCache = fromCache
        self.size = size
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.requestBody = requestBody
        self.responseBody = responseBody
        self.resourceType = resourceType
        self.failed = failed
        self.errorMessage = errorMessage
    }

    func completed(statusCode: Int, statusText: String?, mimeType: String?, responseHeaders: [String: String]?, responseBody: String?, size: Int64? = nil) -> NetworkRequest {
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        return NetworkRequest(
            id: id,
            url: url,
            method: method,
            statusCode: statusCode,
            statusText: statusText,
            mimeType: mimeType,
            startTime: startTime,
            endTime: endTime,
            duration: duration,
            timing: self.timing,
            fromCache: self.fromCache,
            size: size ?? self.size,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            requestBody: requestBody,
            responseBody: responseBody,
            resourceType: resourceType,
            failed: false,
            errorMessage: nil,
            tabID: tabID,
            initiator: initiator,
            streaming: streaming,
            frames: frames
        )
    }

    /// JS 侧（fetch/XHR 钩子、PerformanceObserver）补全：允许只带部分信息，
    /// 缺失的沿用原值（钩子先报 start、再报 complete/body）。
    func completedFromJS(
        statusCode: Int? = nil,
        duration: TimeInterval? = nil,
        timing: Timing? = nil,
        fromCache: Bool? = nil,
        size: Int64? = nil,
        mimeType: String? = nil,
        requestHeaders: [String: String]? = nil,
        responseHeaders: [String: String]? = nil,
        requestBody: String? = nil,
        responseBody: String? = nil
    ) -> NetworkRequest {
        NetworkRequest(
            id: id,
            url: url,
            method: method,
            statusCode: statusCode ?? self.statusCode,
            statusText: statusText,
            mimeType: mimeType ?? self.mimeType,
            startTime: startTime,
            endTime: Date(),
            duration: duration ?? self.duration,
            timing: timing ?? self.timing,
            fromCache: fromCache ?? self.fromCache,
            size: size ?? self.size,
            requestHeaders: requestHeaders ?? self.requestHeaders,
            responseHeaders: responseHeaders ?? self.responseHeaders,
            requestBody: requestBody ?? self.requestBody,
            responseBody: responseBody ?? self.responseBody,
            resourceType: resourceType,
            failed: false,
            errorMessage: nil,
            tabID: tabID,
            initiator: initiator,
            streaming: streaming,
            frames: frames
        )
    }

    func failed(error: String, keepingStatus: Bool = false) -> NetworkRequest {
        // P1-E：4xx/5xx 的挑战需要保留 statusCode/headers/body——此前全置
        // nil，Network 面板对失败请求永远显示时钟（无状态码）。
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        return NetworkRequest(
            id: id,
            url: url,
            method: method,
            statusCode: keepingStatus ? statusCode : nil,
            statusText: keepingStatus ? statusText : nil,
            mimeType: mimeType,
            startTime: startTime,
            endTime: endTime,
            duration: duration,
            timing: self.timing,
            fromCache: self.fromCache,
            size: self.size,
            requestHeaders: requestHeaders,
            responseHeaders: keepingStatus ? responseHeaders : nil,
            requestBody: requestBody,
            responseBody: keepingStatus ? responseBody : nil,
            resourceType: resourceType,
            failed: true,
            errorMessage: error,
            tabID: tabID,
            initiator: initiator,
            streaming: streaming,
            frames: frames
        )
    }
}

// MARK: - HAR 1.2 导出（0.7.5 DevTools 迭代）

/// 作用域内请求 → HAR 1.2 文档（面板导出按钮与桥端点共用，勿另算一套）。
/// 全部收敛在 nonisolated enum 里（NetworkRequest 是 Sendable 值类型，
/// 字段读取无隔离问题；computed entry 挂在类型上会被默认 MainActor 隔离，
/// key path 会炸——勿挪回 extension）。
nonisolated enum HARExport {

    private static let harISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func headers(_ dict: [String: String]?) -> [[String: String]] {
        (dict ?? [:]).sorted { $0.key < $1.key }.map { ["name": $0.key, "value": $0.value] }
    }

    /// 单条请求 → HAR entry（字段缺失按规范给 -1/0，不臆造）。
    static func entry(for r: NetworkRequest) -> [String: Any] {
        var timings: [String: Any] = ["send": 0, "wait": -1, "receive": -1,
                                      "blocked": -1, "dns": -1, "connect": -1, "ssl": -1]
        if let t = r.timing {
            func ms(_ v: Double?) -> Any { v.map { ($0 * 1000 * 100).rounded() / 100 } ?? -1 }
            timings["blocked"] = ms(t.blocked)
            timings["dns"] = ms(t.dns)
            timings["connect"] = ms(t.connect)
            timings["ssl"] = t.tls == nil ? -1 : ms(t.tls)
            timings["wait"] = ms(t.ttfb)
            timings["receive"] = ms(t.download)
        }
        let total: Double = r.duration.map { ($0 * 1000 * 100).rounded() / 100 }
            ?? (r.endTime.map { $0.timeIntervalSince(r.startTime) * 1000 } ?? 0)
        let requestHeaders = headers(r.requestHeaders)
        var request: [String: Any] = [
            "method": r.method,
            "url": r.url,
            "httpVersion": "HTTP/1.1",
            "cookies": [] as [[String: String]],
            "headers": requestHeaders,
            "queryString": (URLComponents(string: r.url)?.queryItems ?? []).map {
                ["name": $0.name, "value": $0.value ?? ""]
            },
            "headersSize": -1,
            "bodySize": r.requestBody.map { $0.utf8.count } ?? 0,
        ]
        if let requestBody = r.requestBody, !requestBody.isEmpty {
            let contentType = r.requestHeaders?["Content-Type"]
                ?? r.requestHeaders?["content-type"] ?? "text/plain"
            request["postData"] = ["mimeType": contentType, "text": requestBody]
        }
        var content: [String: Any] = ["size": r.size ?? -1, "mimeType": r.mimeType ?? "x-unknown"]
        if let body = r.responseBody { content["text"] = body }
        var entry: [String: Any] = [
            "startedDateTime": harISO.string(from: r.startTime),
            "time": total,
            "request": request,
            "response": [
                "status": r.failed ? 0 : (r.statusCode ?? 0),
                "statusText": r.errorMessage ?? (r.statusText ?? ""),
                "httpVersion": "HTTP/1.1",
                "cookies": [] as [[String: String]],
                "headers": headers(r.responseHeaders),
                "content": content,
                "redirectURL": "",
                "headersSize": -1,
                "bodySize": r.size ?? -1,
            ],
            "cache": [:] as [String: Any],
            "timings": timings,
            "_resourceType": r.resourceType.rawValue,
        ]
        if r.failed {
            entry["_error"] = r.errorMessage ?? "request failed"
        }
        if let initiator = r.initiator { entry["_initiator"] = initiator }
        if r.streaming, !r.frames.isEmpty {
            // Chrome 约定的 WS 帧扩展字段（SSE 顺带：direction 同语义）。
            entry["_webSocketMessages"] = r.frames.map { frame in
                ["type": frame.direction == .outbound ? "send" : "receive",
                 "time": harISO.string(from: frame.timestamp),
                 "opcode": 1,
                 "data": frame.payload]
            }
        }
        return entry
    }

    static func document(from requests: [NetworkRequest]) -> [String: Any] {
        [
            "log": [
                "version": "1.2",
                "creator": ["name": "Desire DevTools", "version": "1.0"],
                "pages": [] as [[String: Any]],
                "entries": requests.sorted { $0.startTime < $1.startTime }.map { entry(for: $0) },
            ],
        ]
    }

    static func jsonString(from requests: [NetworkRequest]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: document(from: requests),
                                                     options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
