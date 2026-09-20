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

    func failed(error: String) -> NetworkRequest {
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        return NetworkRequest(
            id: id,
            url: url,
            method: method,
            statusCode: nil,
            statusText: nil,
            mimeType: nil,
            startTime: startTime,
            endTime: endTime,
            duration: duration,
            timing: self.timing,
            fromCache: self.fromCache,
            size: self.size,
            requestHeaders: requestHeaders,
            responseHeaders: nil,
            requestBody: requestBody,
            responseBody: nil,
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