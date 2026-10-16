import Dispatch
import Foundation

/// 备忘录（v0.7.19）：AppleScript 驱动 Notes.app——系统级协作第三件（提醒/日历
/// 走 EventKit，Notes 没有原生非沙盒 API）。
///
/// 权限两条：① Hardened Runtime 下发 Apple Events 需要
/// `com.apple.security.automation.apple-events` entitlement（已加进
/// Desire.entitlements）；② TCC「自动化」授权按既定纪律**懒请求**——第一次真
/// 调用时系统才弹「Desire 想控制备忘录」。弹窗可能永远不渲染（adhoc 构建的已知
/// 形态），所以 osascript 调用带 30 秒超时、超时如实回报"点了允许再试"。
@MainActor
enum NotesBridge {

    struct NoteItem {
        let title: String
        let folder: String
        let modified: String
        /// 纯文本正文（searchNotes 才有；listNotes 为 nil）
        let plainBody: String?
    }

    enum NotesError: LocalizedError {
        case scriptFailed(String)
        case notAuthorized
        case timedOut

        var errorDescription: String? {
            switch self {
            case .scriptFailed(let message):
                return message
            case .notAuthorized:
                return "Automation permission for Notes is not granted. A \"Desire wants to control Notes\" prompt may be waiting — approve it, then retry."
            case .timedOut:
                return "Notes did not respond within 30s (permission prompt still open?). Approve it and retry."
            }
        }
    }

    static let defaultFolder = "Desire"

    /// AppleScript 字符串字面量转义（换行转 \n——AppleScript 支持该转义）。
    private static func lit(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "") + "\""
    }

    /// 跑一段 AppleScript：后台等待 + 30 秒超时（TCC 弹窗悬置 / Notes 卡死都
    /// 不能拖死回合）。失败按 stderr 归类（-1743 = Apple Events 未授权）。
    private static func run(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let killer = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
            process.terminationHandler = { finished in
                killer.cancel()
                let outStr = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errStr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if finished.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: NotesError.timedOut)
                    return
                }
                guard finished.terminationStatus == 0 else {
                    let trimmed = errStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.contains("-1743") || trimmed.contains("Not authorized")
                        || trimmed.contains("not allowed") || trimmed.contains("不允许") {
                        continuation.resume(throwing: NotesError.notAuthorized)
                    } else {
                        continuation.resume(throwing: NotesError.scriptFailed(trimmed.isEmpty ? "osascript failed" : trimmed))
                    }
                    return
                }
                continuation.resume(returning: outStr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: NotesError.scriptFailed(error.localizedDescription))
            }
        }
    }

    /// 建一条笔记（缺省落「Desire」文件夹，不存在则建）。返回实际文件夹名。
    static func addNote(title: String, body: String, folder: String?) async throws -> String {
        let requested = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (requested?.isEmpty == false) ? requested! : defaultFolder
        let script = """
        tell application "Notes"
            if not (exists folder \(lit(target))) then
                make new folder with properties {name:\(lit(target))}
            end if
            set theFolder to folder \(lit(target))
            make new note at theFolder with properties {name:\(lit(title)), body:\(lit(body))}
            return "ok"
        end tell
        """
        _ = try await run(script)
        return target
    }

    /// 列笔记（标题/文件夹/修改时间；不带正文——正文走 searchNotes）。
    static func listNotes(folder: String?, limit: Int) async throws -> [NoteItem] {
        let requested = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = (requested?.isEmpty == false) ? "notes of folder \(lit(requested!))" : "notes"
        // 字段分隔用印刷符号 ␟/␞（正文/标题含任意用户文本也不串行）。
        let script = """
        tell application "Notes"
            set out to ""
            set i to 0
            repeat with n in \(scope)
                set i to i + 1
                if i > \(limit) then exit repeat
                set out to out & (name of n) & "␟" & (name of container of n) & "␟" & (modification date of n as string) & "␞"
            end repeat
            return out
        end tell
        """
        let raw = try await run(script)
        return raw.split(separator: "␞").compactMap { record -> NoteItem? in
            let parts = record.split(separator: "␟", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { return nil }
            return NoteItem(title: parts[0], folder: parts[1], modified: parts[2], plainBody: nil)
        }
    }

    /// 搜笔记：扫最近修改的至多 `scanCap` 条（标题 + 正文纯文本，客户端过滤）。
    /// Notes 没有服务端全文检索 API，只能这样；扫完无果如实回"没找到"。
    static func searchNotes(query: String, limit: Int, scanCap: Int = 120) async throws -> [NoteItem] {
        let script = """
        tell application "Notes"
            set out to ""
            set i to 0
            repeat with n in notes
                set i to i + 1
                if i > \(scanCap) then exit repeat
                set out to out & (name of n) & "␟" & (name of container of n) & "␟" & (modification date of n as string) & "␟" & (body of n) & "␞"
            end repeat
            return out
        end tell
        """
        let raw = try await run(script)
        let needle = query.lowercased()
        var hits: [NoteItem] = []
        for record in raw.split(separator: "␞") {
            let parts = record.split(separator: "␟", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { continue }
            let plain = Self.plainText(fromHTML: parts[3])
            if parts[0].lowercased().contains(needle) || plain.lowercased().contains(needle) {
                hits.append(NoteItem(title: parts[0], folder: parts[1], modified: parts[2], plainBody: plain))
                if hits.count >= limit { break }
            }
        }
        return hits
    }

    /// Notes 的正文是 HTML：剥标签 + 常见实体，给模型看的纯文本。
    static func plainText(fromHTML html: String) -> String {
        var text = html
        // <br>/</p>/</div> 当换行，先于剥标签
        for breaker in ["<br>", "<br/>", "<br />", "</p>", "</div>", "</li>"] {
            text = text.replacingOccurrences(of: breaker, with: "\n")
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
