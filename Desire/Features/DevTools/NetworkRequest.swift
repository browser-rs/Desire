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