import Foundation
import os

/// NSException 落点捕获（v0.8.58 批 1）：主 actor 僵尸的成因是 ObjC 异常
/// （NSException）穿进 Swift async 帧后被运行时吞掉——**没有崩溃报告、
/// 没有统一日志**，事后只能靠 lldb 探针确认"死了"。装一个全局
/// UncaughtExceptionHandler：异常向上传播到 Foundation 顶层时把 name/reason/
/// 调用栈写进应用支持目录（`exceptions/`），僵尸现场就能看到抛出点。
/// 对"已捕获后吞掉"的异常无效（那类仍需复现现场 lldb），但 ObjC 异常穿
/// async 帧的场景里顶层 handler 是唯一落点。
@MainActor
enum ExceptionTrap {
    private static let log = Logger(subsystem: "me.siwi.Desire", category: "app")
    private nonisolated(unsafe) static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        NSSetUncaughtExceptionHandler { exception in
            let directory = Self.directory
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("exception-\(Int(Date().timeIntervalSince1970)).log")
            let text = """
            name: \(exception.name.rawValue)
            reason: \(exception.reason ?? "-")
            user info: \(String(describing: exception.userInfo))
            call stack:
            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            try? text.write(to: file, atomically: true, encoding: .utf8)
            Foundation.NSLog("uncaught exception trapped: \(exception.name.rawValue) — \(file.path)")
        }
        log.info("exception trap installed")
    }

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Desire/exceptions", isDirectory: true)
    }

    /// 最近一份异常报告（诊断端点用）。
    nonisolated static func latest() -> (file: URL, content: String)? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard let latest = files?.first, let content = try? String(contentsOf: latest, encoding: .utf8) else {
            return nil
        }
        return (latest, content)
    }
}
