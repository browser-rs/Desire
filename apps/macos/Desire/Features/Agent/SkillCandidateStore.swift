import Combine
import Foundation
import os

/// **技能候选收件箱**（v0.8.72 批 2）：成功回合自动蒸馏出的技能草稿，
/// 等**用户采纳**才写入正式技能库（SkillCandidateCore 定判定/节流/过期，
/// 这里只做持久化与 UI 状态）。独立窗口技能页（AgentSkillsView）展示。
@MainActor
final class SkillCandidateStore: ObservableObject {
    static let shared = SkillCandidateStore()

    @Published private(set) var candidates: [SkillCandidateCore.Candidate] = []

    /// 节流记账（持久化）：全部候选的提出时间与会话（含已被采纳/忽略的——
    /// 节流看的是"烧过几次旁路"，不是还剩几张卡）。
    private struct Ledger: Codable {
        var offeredAt: [Date]
        var conversationIDs: [UUID]
    }
    private var offeredAt: [Date] = []
    private var conversationIDs: [UUID] = []
    private static let ledgerKey = "skillCandidateLedger"

    private static let candidatesKey = "skillCandidates"

    private init() {
        candidates = SkillCandidateCore.expiring(
            DiskStore.load([SkillCandidateCore.Candidate].self, key: Self.candidatesKey) ?? [],
            now: Date())
        DiskStore.save(candidates, key: Self.candidatesKey)
        if let data = UserDefaults.standard.data(forKey: Self.ledgerKey),
           let decoded = try? JSONDecoder().decode(Ledger.self, from: data) {
            offeredAt = decoded.offeredAt
            conversationIDs = decoded.conversationIDs
        }
    }

    private func saveLedger() {
        if let data = try? JSONEncoder().encode(
            Ledger(offeredAt: offeredAt, conversationIDs: conversationIDs)) {
            UserDefaults.standard.set(data, forKey: Self.ledgerKey)
        }
    }

    private func saveCandidates() {
        DiskStore.save(candidates, key: Self.candidatesKey)
    }

    /// 蒸馏通过节流与查重后**提议**候选。返回是否真的记下了（false = 节流
    /// 拦下 / 重复 / 草稿无效——调用方只写日志，不打扰用户）。
    @discardableResult
    func offer(name: String, description: String, instructions: String,
               conversationId: UUID?) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedDescription.isEmpty,
              trimmedInstructions.count >= 40 else { return false }
        // 查重先于记账：重复/多余的候选直接拒，连 24h 配额都不消耗
        // （旁路蒸馏已经跑完，但"提出候选"的账只记真正落卡的那次）。
        guard !SkillCandidateCore.isRedundant(
            name: trimmedName,
            existingSkillNames: SkillStore.shared.skills.map(\.name),
            pendingCandidates: candidates) else { return false }
        guard SkillCandidateCore.throttlePasses(
            offeredAt: offeredAt, conversationIDs: conversationIDs,
            conversationId: conversationId, now: Date()) else { return false }
        let candidate = SkillCandidateCore.Candidate(
            name: trimmedName, description: trimmedDescription,
            instructions: trimmedInstructions, conversationId: conversationId)
        candidates.insert(candidate, at: 0)
        candidates = SkillCandidateCore.expiring(candidates, now: Date())
        offeredAt.append(Date())
        if let conversationId { conversationIDs.append(conversationId) }
        saveLedger()
        saveCandidates()
        return true
    }

    /// 采纳：写入正式技能库（与 saveSkill 工具同一写盘路径），候选移除。
    func adopt(_ candidate: SkillCandidateCore.Candidate) -> Bool {
        let fileName = FilePathing.sanitizeFileName(candidate.name) + ".md"
        let url = SkillStore.directory.appendingPathComponent(fileName)
        let markdown = SkillAuthoring.markdown(name: candidate.name,
                                               description: candidate.description,
                                               instructions: candidate.instructions)
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.agent.error("skill candidate adopt failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        SkillStore.shared.reload()
        remove(candidate)
        return true
    }

    /// 忽略：直接移除。
    func discard(_ candidate: SkillCandidateCore.Candidate) {
        remove(candidate)
    }

    private func remove(_ candidate: SkillCandidateCore.Candidate) {
        candidates.removeAll { $0.id == candidate.id }
        saveCandidates()
    }
}
