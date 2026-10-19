import Foundation

/// 报告流水线（v0.7.24）：把"周报"三件现成部件连起来——**确定性、零模型
/// 调用**。WeeklyDigestStore.runNow 产摘要（会话备注 + routine 通知 + 到点
/// 记账），本流水线再：空板 → 铺"周报"模板并改名；追加摘要 note 块；
/// 可选写备忘录（NotesBridge，AppleScript 首次用可能弹自动化授权——失败
/// 非致命，如实回报）。
@MainActor
enum WeeklyReportPipeline {
    struct Outcome: Equatable {
        var digestChars: Int
        var boardBlocks: Int
        var seededBoard: Bool
        /// skipped | written | failed: …
        var notes: String
    }

    /// `conversationID` 缺省 = 当前投递目标会话（桥探针可显式指定，避免
    /// 触碰用户正在看的板）。
    static func run(days: Int = 7, writeToNotes: Bool = false,
                    conversationID explicitID: String? = nil) async -> Outcome {
        let digest = await WeeklyDigestStore.shared.runNow(days: days)
        let store = WhiteboardStore.shared
        let conversationID = explicitID
            ?? AgentScheduler.shared.deliveryTarget?.conversationId?.uuidString
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let stamp = formatter.string(from: Date())

        var seeded = false
        if store.board(for: conversationID).blocks.isEmpty {
            // 空板 → 用"周报"模板铺底（结构占位：本周完成/下周计划/风险），
            // 摘要随后作为 note 块附上——绝不覆盖非空板。
            let template = WhiteboardTemplates.builtIn.first { $0.id == "weekly" }?.blocks ?? []
            store.set(WhiteboardSpec(title: "周报 \(stamp)", blocks: template),
                      conversationID: conversationID)
            seeded = true
        }
        let block = WhiteboardBlock(
            type: WhiteboardBlock.Kind.note,
            title: "周报 \(stamp)",
            content: "## 周报 \(stamp)\n\n" + digest)
        store.append([block], title: nil, conversationID: conversationID)

        var notes = "skipped"
        if writeToNotes {
            do {
                _ = try await NotesBridge.addNote(title: "Desire 周报 \(stamp)", body: digest, folder: nil)
                notes = "written"
            } catch {
                notes = "failed: \(error.localizedDescription)"
            }
        }
        return Outcome(
            digestChars: digest.count,
            boardBlocks: store.board(for: conversationID).blocks.count,
            seededBoard: seeded,
            notes: notes)
    }
}
