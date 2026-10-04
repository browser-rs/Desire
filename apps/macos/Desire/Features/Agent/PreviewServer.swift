import Combine
import Foundation
import Network

/// Minimal localhost HTTP server serving the agent working directory, so
/// prototypes and generated sites render over real http:// (file:// breaks
/// relative assets and several web APIs).
///
/// Security: binds to 127.0.0.1 only; GET-only; serves files strictly under
/// the working directory (percent-decoded, ".." rejected).
///
/// Static namespace with `nonisolated(unsafe)` storage: connection callbacks
/// run on a POSIX queue, and this shape has zero self-capture — the
/// strict-concurrency default isolation stays clean with no warnings.
@MainActor
enum PreviewServer {
    nonisolated(unsafe) private static var listener: NWListener?
    nonisolated(unsafe) private static var baseURL: URL?
    nonisolated(unsafe) private static var started = false
    private static let queue = DispatchQueue(label: "me.siwi.Desire.preview")

    static func ensureRunning() -> URL {
        if !started { start() }
        if let baseURL { return baseURL }
        start()
        return baseURL ?? URL(string: "http://127.0.0.1:8766/")!
    }

    private static func start() {
        for rawPort in [UInt16(8766), 8767, 8768, 8769] {
            guard let port = NWEndpoint.Port(rawValue: rawPort) else { continue }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let listener = try? NWListener(using: params, on: port) else { continue }
            listener.newConnectionHandler = { connection in
                Task { @MainActor in receiveHead(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
            baseURL = URL(string: "http://127.0.0.1:\(rawPort)/")
            started = true
            return
        }
    }

    private static func receiveHead(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private nonisolated static func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            var buffer = accumulated
            if let data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: buffer.subdata(in: buffer.startIndex..<range.lowerBound), encoding: .utf8) ?? ""
                let requestLine = head.components(separatedBy: "\r\n").first ?? "GET / HTTP/1.1"
                let rawPath = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                Task { await respond(connection: connection, rawPath: rawPath) }
                return
            }
            if error == nil {
                receive(connection, accumulated: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private static func respond(connection: NWConnection, rawPath: String) async {
        var path = rawPath.split(separator: "?").first.map(String.init) ?? "/"
        path = path.removingPercentEncoding ?? path
        if path.contains("..") {
            send(connection, body: "Forbidden", mime: "text/plain; charset=utf-8")
            return
        }

        var fileURL = workingDirectory.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            fileURL = fileURL.appendingPathComponent("index.html")
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                send(connection, body: listing(root: workingDirectory), mime: "text/html; charset=utf-8")
                return
            }
        }
        // 大产物(mp4/pdf)的磁盘读取移出调用方线程——此前在主线程
        // 同步读,生成的产物越大卡顿越久。
        let mimeHint = mime(for: fileURL.pathExtension)
        let readTask = Task.detached(priority: .utility) { () -> Data? in
            try? Data(contentsOf: fileURL)
        }
        guard let data = await readTask.value else {
            send(connection, body: "404 Not Found", mime: "text/plain; charset=utf-8", status: "404 Not Found")
            return
        }
        send(connection, data: data, mime: mimeHint)
    }

    private static func send(_ connection: NWConnection, body: String, mime: String, status: String = "200 OK") {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        let payload = Data(header.utf8) + bodyData
        let completion = NWConnection.SendCompletion.contentProcessed { _ in
            connection.cancel()
        }
        connection.send(content: payload, contentContext: NWConnection.ContentContext.finalMessage, isComplete: true, completion: completion)
    }

    private static func send(_ connection: NWConnection, data: Data, mime: String) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        let payload = Data(header.utf8) + data
        let completion = NWConnection.SendCompletion.contentProcessed { _ in
            connection.cancel()
        }
        connection.send(content: payload, contentContext: NWConnection.ContentContext.finalMessage, isComplete: true, completion: completion)
    }

    private static func listing(root: URL) -> String {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let items = entries.map { "<li><a href=\"\($0.lastPathComponent)\">\($0.lastPathComponent)</a></li>" }.joined()
        return "<html><head><meta charset='utf-8'><title>Desire Preview</title></head><body><h1>Workspace</h1><ul>\(items)</ul></body></html>"
    }

    private static func mime(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js", "mjs": "application/javascript"
        case "json": "application/json"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "mp4", "m4v": "video/mp4"
        case "mp3", "m4a": "audio/mpeg"
        case "pdf": "application/pdf"
        case "txt", "md": "text/plain; charset=utf-8"
        default: "application/octet-stream"
        }
    }

    private static var workingDirectory: URL { SystemCommandStore.shared.workingDirectory }
}
