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
    let requestHeaders: [String: String]?
    let responseHeaders: [String: String]?
    let requestBody: String?
    let responseBody: String?
    let resourceType: ResourceType
    let failed: Bool
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case id, url, method, statusCode, statusText, mimeType, startTime, endTime, duration, requestHeaders, responseHeaders, requestBody, responseBody, resourceType, failed, errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        url = try container.decode(String.self, forKey: .url)
        method = try container.decode(String.self, forKey: .method)
        statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode)
        statusText = try container.decodeIfPresent(String.self, forKey: .statusText)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        startTime = try container.decode(Date.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        requestHeaders = try container.decodeIfPresent([String: String].self, forKey: .requestHeaders)
        responseHeaders = try container.decodeIfPresent([String: String].self, forKey: .responseHeaders)
        requestBody = try container.decodeIfPresent(String.self, forKey: .requestBody)
        responseBody = try container.decodeIfPresent(String.self, forKey: .responseBody)
        resourceType = try container.decode(ResourceType.self, forKey: .resourceType)
        failed = try container.decode(Bool.self, forKey: .failed)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(statusCode, forKey: .statusCode)
        try container.encodeIfPresent(statusText, forKey: .statusText)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encode(startTime, forKey: .startTime)
        try container.encodeIfPresent(endTime, forKey: .endTime)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(requestHeaders, forKey: .requestHeaders)
        try container.encodeIfPresent(responseHeaders, forKey: .responseHeaders)
        try container.encodeIfPresent(requestBody, forKey: .requestBody)
        try container.encodeIfPresent(responseBody, forKey: .responseBody)
        try container.encode(resourceType, forKey: .resourceType)
        try container.encode(failed, forKey: .failed)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
    }

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

    init(url: String, method: String, resourceType: ResourceType, requestHeaders: [String: String]? = nil, requestBody: String? = nil) {
        self.id = UUID()
        self.url = url
        self.method = method
        self.statusCode = nil
        self.statusText = nil
        self.mimeType = nil
        self.startTime = Date()
        self.endTime = nil
        self.duration = nil
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
        requestHeaders: [String: String]?,
        responseHeaders: [String: String]?,
        requestBody: String?,
        responseBody: String?,
        resourceType: ResourceType,
        failed: Bool,
        errorMessage: String?
    ) {
        self.id = id
        self.url = url
        self.method = method
        self.statusCode = statusCode
        self.statusText = statusText
        self.mimeType = mimeType
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.requestBody = requestBody
        self.responseBody = responseBody
        self.resourceType = resourceType
        self.failed = failed
        self.errorMessage = errorMessage
    }

    func completed(statusCode: Int, statusText: String?, mimeType: String?, responseHeaders: [String: String]?, responseBody: String?) -> NetworkRequest {
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
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            requestBody: requestBody,
            responseBody: responseBody,
            resourceType: resourceType,
            failed: false,
            errorMessage: nil
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
            requestHeaders: requestHeaders,
            responseHeaders: nil,
            requestBody: requestBody,
            responseBody: nil,
            resourceType: resourceType,
            failed: true,
            errorMessage: error
        )
    }
}