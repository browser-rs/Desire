import AppIntents
import AppKit
import WebKit

// MARK: - App Intents（0.6.10 生态：Shortcuts.app / Siri 编排 Desire）

/// 四个系统意图（roadmap 0.6.10 P1）：打开 URL / 问 Agent（文本入、结果出）/
/// 截当前页到白板 / 启动定时任务。全部落在本 app 既有链路上（桥验证过的
/// 同一批函数），无新的数据面。每个 perform 都 @MainActor（需要触达主线程
/// 的 UI 状态：webview / AgentScheduler / WhiteboardStore）。

// MARK: ① 在 Desire 打开链接

struct OpenInDesireIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Link in Desire"
    static var description = IntentDescription("Open a URL in the Desire browser's active tab.")
    static var openAppWhenRun = true

    @Parameter(title: "URL") var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$url) in Desire")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let manager = TabSessionCoordinator.shared.activeTabManager,
              let tab = manager.selectedTab else {
            throw NSError(domain: "Desire.Intent", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No browser window open."])
        }
        let final = URL(string: url.absoluteString) ?? URL(string: "https://\(url.absoluteString)")!
        tab.browser.webView.load(URLRequest(url: final))
        return .result(value: "Opened \(final.absoluteString) in Desire.")
    }
}

// MARK: ② 问 Desire Agent（文本入、结果出）

struct AskDesireAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Desire Agent"
    static var description = IntentDescription("Send a prompt to the Desire agent and get the final answer back. The turn can take minutes — Shortcuts will wait.")
    static var openAppWhenRun = true

    @Parameter(title: "Prompt") var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Desire \(\.$prompt)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let session = AgentScheduler.shared.deliveryTarget else {
            throw NSError(domain: "Desire.Intent", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No live agent session — open a Desire window with the agent panel once, then retry."])
        }
        let knownIDs = Set(session.messages.map(\.id))
        session.sendMessage(prompt)
        // 等回合收敛：出现**新** assistant 消息且不再处理中（与评估脚本同一判据）。
        // 上限 5 分钟（长工具链回合）。
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try Task.checkCancellation()
            if !session.isProcessing,
               let answer = session.messages.last(where: {
                   $0.role == .assistant && !knownIDs.contains($0.id) && !($0.content ?? "").isEmpty
               })?.content {
                return .result(value: answer)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw NSError(domain: "Desire.Intent", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the agent to finish (5 min)."])
    }
}

// MARK: ③ 截当前页到白板

struct CapturePageToWhiteboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Page to Desire Whiteboard"
    static var description = IntentDescription("Take a snapshot of the current page and append it to the active conversation's whiteboard as an image block.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let manager = TabSessionCoordinator.shared.activeTabManager,
              let tab = manager.selectedTab else {
            throw NSError(domain: "Desire.Intent", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No browser window open."])
        }
        let webView = tab.browser.webView
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        let cgImage: CGImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: config) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    continuation.resume(returning: cg)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "Desire.Intent", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Snapshot produced no image."]))
                }
            }
        }
        let retina = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
        guard let tiff = retina.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg,
                                            properties: [NSBitmapImageRep.PropertyKey.compressionFactor: 0.72]),
              !jpeg.isEmpty else {
            throw NSError(domain: "Desire.Intent", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Snapshot encoding failed."])
        }
        let pageTitle = tab.browser.pageTitle
        let title = webView.title?.isEmpty == false
            ? webView.title!
            : (pageTitle.isEmpty ? (webView.url?.host ?? "Page") : pageTitle)
        let dataURI = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        let block = WhiteboardBlock(type: WhiteboardBlock.Kind.image, title: title, content: dataURI)
        WhiteboardStore.shared.append(
            [block], title: title,
            conversationID: AgentScheduler.shared.deliveryTarget?.conversationId?.uuidString)
        return .result(value: "Captured “\(title)” to the whiteboard (\(jpeg.count / 1024) KB).")
    }
}

// MARK: ④ 启动定时任务

struct ScheduleDesireTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Schedule Desire Task"
    static var description = IntentDescription("Create a recurring agent task. It re-runs the prompt automatically while Desire is open (min every 5 minutes, or daily at HH:MM).")
    static var openAppWhenRun = true

    @Parameter(title: "Name") var name: String
    @Parameter(title: "Prompt") var prompt: String
    /// Shortcuts 参数不适配合体——两个可选参数由运行期裁决。
    @Parameter(title: "Every N Minutes", default: 30) var everyMinutes: Int
    @Parameter(title: "Daily At (HH:MM)", default: "09:00") var dailyAt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Schedule \(\.$name) — \(\.$prompt) every \(\.$everyMinutes) min or daily at \(\.$dailyAt)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let trimmedDaily = dailyAt.trimmingCharacters(in: .whitespaces)
        let recurrence: AgentScheduler.ScheduledTask.Recurrence
        // 裁决：dailyAt 填了合法 HH:MM 用每日；否则用 everyMinutes（钳 ≥5）。
        let dailyParts = trimmedDaily.split(separator: ":")
        if dailyParts.count == 2, let hour = Int(dailyParts[0]), let minute = Int(dailyParts[1]),
           (0...23).contains(hour), (0...59).contains(minute) {
            recurrence = .daily(hour: hour, minute: minute)
        } else {
            recurrence = .everyMinutes(max(5, everyMinutes))
        }
        guard let task = AgentScheduler.shared.add(
            name: name.trimmingCharacters(in: .whitespaces),
            prompt: prompt,
            recurrence: recurrence) else {
            throw NSError(domain: "Desire.Intent", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to schedule (empty fields?)."])
        }
        return .result(value: "Scheduled '\(task.name)' (\(task.recurrenceText)) — runs while Desire is open.")
    }
}

// MARK: - Siri / Shortcuts 短语

struct DesireShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenInDesireIntent(),
            phrases: ["Open \(.applicationName)"],
            shortTitle: "Open Link in Desire",
            systemImageName: "safari")
        AppShortcut(
            intent: AskDesireAgentIntent(),
            phrases: ["Ask \(.applicationName)"],
            shortTitle: "Ask Desire Agent",
            systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(
            intent: CapturePageToWhiteboardIntent(),
            phrases: ["Capture \(.applicationName)"],
            shortTitle: "Capture to Whiteboard",
            systemImageName: "camera.viewfinder")
        AppShortcut(
            intent: ScheduleDesireTaskIntent(),
            phrases: ["Schedule \(.applicationName)"],
            shortTitle: "Schedule Task",
            systemImageName: "clock.badge.plus")
    }
}
