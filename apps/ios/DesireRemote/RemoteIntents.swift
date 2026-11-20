import AppIntents
import Foundation

// MARK: - App Intents / Siri（v0.8.66 批 1，融合旗舰：照 macOS DesireIntents
// 同款形态——iOS DesireRemote 此前无任何系统意图）。
//
// 能力边界（诚实口径）：AppIntent 的 perform 依赖 app 进程内已配对的
// RemoteClient 与桌面在线状态；iOS 后台网络会被挂起，所以"问 Agent"以
// Siri/快捷指令把 app 拉到前台为前提（openAppWhenRun = true），不承诺
// 后台静默执行。

/// 问桌面 Agent（文本入、最终回答出）。判据与 macOS DesireIntents /
/// 评估脚本同一口径：出现**新** assistant 消息且 `busy == false`。
struct AskAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Desire Agent"
    static var description = IntentDescription(
        "Send a prompt to the desktop agent and get the final answer back. Long turns can take minutes — Shortcuts will wait.")
    static var openAppWhenRun = true

    @Parameter(title: "Prompt") var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$prompt)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let client = RemoteClient.shared, client.sessionKeyB64 != nil else {
            throw IntentError("Not paired with a Mac yet — open Desire Remote and connect first.")
        }
        guard client.desktopOnline else {
            throw IntentError("Your Mac is offline. Wake it and make sure Desire is running, then retry.")
        }
        // 等 WS 就绪（app 刚被 Siri 拉起时快照可能还没到位）。
        try await waitUntil(timeout: 15, interval: 0.5) {
            client.connectionState == "已连接" || client.connectionState == "已排队，Mac 上线后送达"
        }
        let knownIDs = Set(client.messages.map(\.id))
        client.sendPrompt(prompt)
        // 回合收敛：新 assistant 消息 + busy == false（快照帧驱动），5 分钟上限。
        try await waitUntil(timeout: 300, interval: 0.5) {
            client.busy == false
                && client.messages.contains {
                    $0.role == "assistant"
                        && !knownIDs.contains($0.id)
                        && !($0.content ?? "").isEmpty
                }
        }
        let answer = client.messages
            .last { $0.role == "assistant" && !knownIDs.contains($0.id) && !($0.content ?? "").isEmpty }?
            .content ?? ""
        if answer.isEmpty {
            throw IntentError("The agent returned an empty answer.")
        }
        return .result(value: answer)
    }
}

/// 打开 Desire Remote 回到聊天页（编排用：前一步先问、后一步人看）。
struct OpenRemoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Desire Remote"
    static var description = IntentDescription("Open the Desire Remote app.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct DesireRemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskAgentIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "问 \(.applicationName)",
            ],
            shortTitle: "Ask Desire Agent",
            systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(
            intent: OpenRemoteIntent(),
            phrases: [
                "Open \(.applicationName)",
                "打开 \(.applicationName)",
            ],
            shortTitle: "Open Desire Remote",
            systemImageName: "iphone")
    }
}

/// 轮询等待（IntentError 化超时；Task.cancel 联动——Shortcuts 取消即停）。
private func waitUntil(timeout: TimeInterval, interval: TimeInterval,
                       _ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        try Task.checkCancellation()
        if condition() { return }
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    throw IntentError("Timed out after \(Int(timeout))s.")
}

/// 统一错误形态（NSLocalizedDescriptionKey 供 Shortcuts/Siri 展示）。
struct IntentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
