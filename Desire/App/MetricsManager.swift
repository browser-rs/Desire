import AppKit
import Foundation
import MetricKit
import os

/// Receives MetricKit payloads and files them under
/// `Application Support/Desire/diagnostics/` (newest 30 kept per kind).
///
/// Crash diagnostics are delivered by the system on the launch AFTER a
/// crash — this is the only production visibility into failures without a
/// telemetry backend (ARCHITECTURE.md debt A10). To inspect on a user
/// machine: open the diagnostics folder, or
/// `log stream --predicate 'subsystem == "me.siwi.Desire"'`.
///
/// Delivery happens on MetricKit's own queue, so the subscriber methods are
/// `nonisolated` and only touch nonisolated helpers (DiagnosticsStore).
@MainActor
final class MetricsManager: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsManager()

    private var subscribed = false

    /// Idempotent — call once at app init.
    func start() {
        guard !subscribed else { return }
        subscribed = true
        MXMetricManager.shared.add(self)
        Log.app.info("MetricKit subscriber registered")
    }

    /// Reveals (creating if needed) the diagnostics folder in Finder.
    func revealDiagnosticsFolder() {
        try? FileManager.default.createDirectory(at: DiagnosticsStore.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([DiagnosticsStore.directory])
    }

    /// 诊断目录里的报告数。设置页用它显示"已收集 N 份"、并在为 0 时把 Export 置灰——
    /// 此前没有报告时 Export 会静默改成"打开文件夹"，用户以为导出了。
    var reportCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: DiagnosticsStore.directory.path))?.count ?? 0
    }

    /// Zips the diagnostics folder into `~/Downloads/desire-diagnostics-<stamp>.zip`
    /// and returns the archive URL (nil when the folder is empty/missing or
    /// ditto failed). The app runs unsandboxed, so spawning `/usr/bin/ditto`
    /// is permitted.
    @MainActor
    func exportDiagnosticsArchive() -> URL? {
        let fm = FileManager.default
        let directory = DiagnosticsStore.directory
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path),
              !entries.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = .current
        let destination = (fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory)
            .appendingPathComponent("desire-diagnostics-\(formatter.string(from: Date())).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", directory.path, destination.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        return process.terminationStatus == 0 ? destination : nil
    }

    /// Daily/weekly performance metrics: launch times, hang rate, memory,
    /// disk writes. Delivered at most once a day.
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            DiagnosticsStore.write(payload.jsonRepresentation(),
                                   kind: "metrics",
                                   stamp: payload.timeStampEnd)
        }
        let log = Logger(subsystem: "me.siwi.Desire", category: "app")
        log.info("filed \(payloads.count, privacy: .public) MetricKit metric payload(s)")
    }

    /// Crash / hang / CPU-exception / disk-write-exception diagnostics.
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let log = Logger(subsystem: "me.siwi.Desire", category: "app")
        for payload in payloads {
            DiagnosticsStore.write(payload.jsonRepresentation(),
                                   kind: "diagnostics",
                                   stamp: payload.timeStampEnd)
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            let cpuExceptions = payload.cpuExceptionDiagnostics?.count ?? 0
            let diskWrites = payload.diskWriteExceptionDiagnostics?.count ?? 0
            if crashes > 0 || hangs > 0 || cpuExceptions > 0 || diskWrites > 0 {
                log.fault("MetricKit diagnostics: \(crashes) crash(es), \(hangs) hang(s), \(cpuExceptions) cpu exception(s), \(diskWrites) disk write exception(s)")
            }
        }
    }
}

/// File store for MetricKit payload JSON. Nonisolated: plain atomic file
/// writes callable from MetricKit's delivery queue.
private nonisolated enum DiagnosticsStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Desire", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func write(_ data: Data, kind: String, stamp: Date) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.timeZone = .current
        let name = "\(kind)-\(formatter.string(from: stamp)).json"
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        prune(kind: kind)
    }

    /// Names embed sortable timestamps — keep the newest N per kind.
    private static func prune(kind: String, keep: Int = 30) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let files = entries
            .filter { $0.lastPathComponent.hasPrefix("\(kind)-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count > keep else { return }
        for stale in files.prefix(files.count - keep) {
            try? fm.removeItem(at: stale)
        }
    }
}
