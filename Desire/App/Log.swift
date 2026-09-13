import os

/// Central OSLog facade. All diagnostics go through here — `print` output
/// is invisible in production builds and unfilterable in Console.app, while
/// these logs are queryable via:
///
///     log stream --predicate 'subsystem == "me.siwi.Desire"'
///
/// Interpolated strings default to `.private` redaction in non-debugger
/// capture; pass `privacy: .public` only for non-sensitive content
/// (error codes, resource names, status codes).
enum Log {
    private static let subsystem = "me.siwi.Desire"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let tabs = Logger(subsystem: subsystem, category: "tabs")
    static let ai = Logger(subsystem: subsystem, category: "ai")
    static let contentBlocking = Logger(subsystem: subsystem, category: "content-blocking")
    static let privacy = Logger(subsystem: subsystem, category: "privacy")
    static let extensions = Logger(subsystem: subsystem, category: "extensions")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let userScripts = Logger(subsystem: subsystem, category: "user-scripts")
}
