import Combine
import Foundation

/// 划词就地卡的**流式旁路调用**（v0.7.25 旗舰）：不产生会话消息、不占 Agent
/// 回合——旁路档案（bypassPreferences）优先，流式 delta 直接进卡片。
/// 与标题/记忆整理同类（旁路调用，暂不计入对话成本——已知缺口沿用）。
@MainActor
enum SelectionAssistService {
    /// 流式跑一次；`onDelta` 逐段回调（主 actor）；返回最终全文。
    /// 错误如实抛出（卡片显示失败态 + 一键转面板）。
    static func stream(text: String, mode: SelectionAssistMode,
                       onDelta: @MainActor (String) -> Void) async throws -> String {
        guard let prefs = AppState.live?.aiPreference else {
            throw NSError(domain: "SelectionAssist", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Agent 配置未就绪"])
        }
        let sidePrefs = prefs.bypassPreferences() ?? prefs
        let messages = [
            AgentMessage(role: .system, content: SelectionAssistMode.systemPrompt(for: mode)),
            AgentMessage(role: .user, content: SelectionAssistMode.userPrompt(for: text, mode: mode)),
        ]
        var output = ""
        for try await event in sidePrefs.provider.stream(messages: messages, tools: [], prefs: sidePrefs) {
            switch event {
            case .text(let delta):
                output += delta
                onDelta(output)
            default:
                break
            }
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "SelectionAssist", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "模型没有返回内容"])
        }
        return trimmed
    }
}

/// 卡片状态机（View 层只渲染它）。取消语义：新一次 run 自动取消上一次。
@MainActor
final class SelectionAssistCardModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case streaming
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var text = ""
    @Published private(set) var mode: SelectionAssistMode = .explain
    @Published private(set) var sourceText = ""

    private var task: Task<Void, Never>?

    var isActive: Bool { phase == .streaming }

    /// `mode == nil` = 自动判定（解释入口）。空文本忽略。
    func run(_ source: String, mode requested: SelectionAssistMode? = nil) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let resolved = requested ?? SelectionAssistMode.detect(trimmed)
        task?.cancel()
        sourceText = trimmed
        mode = resolved
        text = ""
        phase = .streaming
        task = Task { @MainActor [weak self] in
            do {
                let final = try await SelectionAssistService.stream(text: trimmed, mode: resolved) { partial in
                    self?.text = partial
                }
                guard let self, !Task.isCancelled else { return }
                self.text = final
                self.phase = .done
            } catch {
                guard let self, !Task.isCancelled else { return }
                if (error as? URLError)?.code == .cancelled { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .streaming { phase = .idle }
    }

    func reset() {
        cancel()
        phase = .idle
        text = ""
        sourceText = ""
    }
}
