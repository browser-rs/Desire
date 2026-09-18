import Combine
import Foundation
import os

/// Fan-out hub for bridge events. Stores and the webview coordinator
/// publish semantic moments (page ready, download finished, approval
/// pending, tabs changed); `AutomationServer` subscribes one sink per
/// connected SSE client (`GET /events`) and writes frames out.
///
/// Frame format is server-sent events: `event:` + single-line JSON `data:`.
/// With no subscribers `publish` is a no-op, so instrumentation is free to
/// call from anywhere on the main actor.
@MainActor
final class BridgeEventBus {
    static let shared = BridgeEventBus()

    private var sinks: [UUID: @MainActor (String) -> Void] = [:]

    private init() {}

    /// Registers a sink that receives raw SSE frames. Returns the id to
    /// `unsubscribe` with when the connection dies.
    @discardableResult
    func subscribe(_ sink: @MainActor @escaping (String) -> Void) -> UUID {
        let id = UUID()
        sinks[id] = sink
        sink(": connected to desire events\n\n")
        Log.agent.info("bridge events: subscriber added (\(self.sinks.count, privacy: .public) total)")
        return id
    }

    func unsubscribe(_ id: UUID) {
        sinks.removeValue(forKey: id)
    }

    var subscriberCount: Int { sinks.count }

    /// Emits `event: <kind>` + `data: <single-line JSON>` to every sink.
    func publish(_ kind: String, _ payload: [String: Any]) {
        guard !sinks.isEmpty else { return }
        Log.agent.debug("bridge events: publishing \(kind, privacy: .public) to \(self.sinks.count, privacy: .public) sink(s)")
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // SSE data lines must not contain raw newlines — sortedKeys JSON
        // serialization is single-line already.
        let frame = "event: \(kind)\ndata: \(json)\n\n"
        for sink in sinks.values {
            sink(frame)
        }
    }
}
