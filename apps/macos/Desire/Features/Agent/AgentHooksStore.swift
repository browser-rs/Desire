import Combine
import Foundation
import JavaScriptCore
import os

/// Agent 生命周期钩子（hooks v1）：
/// `hooks/` 目录下每个 `.js` 文件在一个独立的 JavaScriptCore 上下文里加载，
/// agent 事件发生时调用同名全局函数：
/// - `beforeToolCall(event)` → 返回 `{decision:"deny", reason:"…"}` 即否决该
///   工具调用（与 deny 规则同级：任何访问等级都生效，含完全访问豁免之外的
///   全部快捷道）；返回空/其他一律放行。
/// - `turnFinish(event)` → 通知型钩子（回合收尾），返回值忽略。
///
/// 信任模型：钩子 = 用户放在自己机器上的代码（与 runCommand 执行的命令同
/// 级信任）；上下文**不注入任何宿主对象**，只有收集到 `__logs` 的 console
/// shim（每次派发后写入统一日志）。单文件解析/运行异常只禁用该文件。
/// JSC 无内置中断，钩子应短小——文档与设置页副标题都有说明。
@MainActor
final class AgentHooksStore: ObservableObject {
    static let shared = AgentHooksStore()

    struct HookFile: Identifiable, Equatable {
        let id: String   // 文件名
        var isEnabled: Bool
        var hasError: String?
    }

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "agentHooksEnabled") }
    }
    @Published private(set) var files: [HookFile] = []

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Desire/hooks", isDirectory: true)
    }

    private static let disabledKey = "agentHooksDisabledFiles"
    /// 文件名 → 已加载上下文（仅启用且解析成功的）。
    private var contexts: [String: JSContext] = [:]

    init() {
        isEnabled = UserDefaults.standard.object(forKey: "agentHooksEnabled") as? Bool ?? true
        load()
    }

    // MARK: - 装载

    /// 扫描目录 + 重建上下文。设置页出现、桥 reload、启停切换时调用。
    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let names = ((try? fm.contentsOfDirectory(atPath: Self.directory.path)) ?? [])
            .filter { $0.hasSuffix(".js") }
            .sorted()
        let disabled = Set(UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? [])
        files = names.map { HookFile(id: $0, isEnabled: !disabled.contains($0)) }
        rebuildContexts()
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        var disabled = Set(UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? [])
        if enabled {
            disabled.remove(id)
        } else {
            disabled.insert(id)
        }
        UserDefaults.standard.set(Array(disabled).sorted(), forKey: Self.disabledKey)
        if let idx = files.firstIndex(where: { $0.id == id }) {
            files[idx].isEnabled = enabled
        }
        rebuildContexts()
    }

    private func rebuildContexts() {
        contexts.removeAll()
        guard isEnabled else {
            files = files.map { $0 }  // 触发发布（UI 即时反映）
            return
        }
        for index in files.indices {
            let id = files[index].id
            let url = Self.directory.appendingPathComponent(id)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                files[index].hasError = "unreadable"
                continue
            }
            let ctx = JSContext()!
            let fileName = id
            ctx.name = fileName
            ctx.exceptionHandler = { _, exception in
                Log.agent.error("hook \(fileName, privacy: .public) exception: \(exception?.toString() ?? "?", privacy: .public)")
            }
            // console shim：参数收集进 __logs，派发后统一写统一日志。
            ctx.evaluateScript("""
            var __logs = [];
            var console = { log: function() {
                __logs.push(Array.prototype.slice.call(arguments).join(' '));
            } };
            """)
            ctx.evaluateScript(source)
            if let exception = ctx.exception {
                files[index].hasError = exception.toString()
                continue
            }
            contexts[id] = ctx
        }
        files = files.map { $0 }
    }

    // MARK: - 事件派发

    /// beforeToolCall：返回否决理由（nil = 放行）。第一个 deny 的钩子生效。
    func denyReason(tool: String, argumentsJSON: String, goal: String) -> String? {
        guard isEnabled, !contexts.isEmpty else { return nil }
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any]
        let payload: [String: Any] = [
            "event": "beforeToolCall",
            "tool": tool,
            "arguments": args ?? NSNull(),
            "argumentsJSON": argumentsJSON,
            "goal": String(goal.prefix(400)),
        ]
        for (id, ctx) in contexts {
            let function = ctx.objectForKeyedSubscript("beforeToolCall")
            guard let function, function.isObject, !function.isNull, !function.isUndefined else { continue }
            guard let event = JSValue(object: payload, in: ctx) else { continue }
            let result = function.call(withArguments: [event])
            flushLogs(ctx, file: id)
            guard let dict = result?.toDictionary() as? [String: Any] else { continue }
            let decision = (dict["decision"] as? String ?? "").lowercased()
            if decision == "deny" || decision == "block" {
                let reason = dict["reason"] as? String
                return reason?.isEmpty == false ? reason! : "denied by hook \(id)"
            }
        }
        return nil
    }

    /// turnFinish：通知型钩子（fire-and-forget，返回值忽略）。
    func dispatchTurnFinish(success: Bool, error: String?, answer: String, toolCount: Int) {
        guard isEnabled, !contexts.isEmpty else { return }
        var payload: [String: Any] = [
            "event": "turnFinish",
            "success": success,
            "answer": String(answer.prefix(600)),
            "toolCount": toolCount,
        ]
        if let error, !error.isEmpty { payload["error"] = error }
        for (id, ctx) in contexts {
            let function = ctx.objectForKeyedSubscript("turnFinish")
            guard let function, function.isObject, !function.isNull, !function.isUndefined else { continue }
            guard let event = JSValue(object: payload, in: ctx) else { continue }
            function.call(withArguments: [event])
            flushLogs(ctx, file: id)
        }
    }

    /// 把钩子运行期间 console.log 的内容落统一日志（debug 档）。
    private func flushLogs(_ ctx: JSContext, file: String) {
        guard let logs = ctx.objectForKeyedSubscript("__logs"),
              let lines = logs.toArray() as? [String], !lines.isEmpty else { return }
        for line in lines {
            Log.agent.debug("hook \(file, privacy: .public) console: \(line, privacy: .public)")
        }
        ctx.evaluateScript("__logs.length = 0")
    }
}
