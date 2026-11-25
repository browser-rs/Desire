import Combine
import Foundation
import os

/// **技能候选收件箱**（v0.8.72 批 2）：成功回合自动蒸馏出的技能草稿，
/// 等**用户采纳**才写入正式技能库（SkillCandidateCore 定判定/节流/过期，
/// 这里只做持久化与 UI 状态）。独立窗口技能页（AgentSkillsView）展示。
///
/// v0.8.76 批 4 起收两种卡：新技能草稿，与**对已有技能的定点补丁**（用户纠正
/// 后由旁路生成，SkillCorrectionCore 定识别/定位/节流）。补丁同样只走确认——
/// 采纳 = 原文件覆盖 + 旧版备份到技能目录之外。
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

    /// 补丁生成的节流账（持久化）：按（技能, 会话）冷却 + 全局日上限。
    /// **调用旁路前**记账——烧的是那次调用，不是落卡的那次。
    private var patchAttempts: [SkillCorrectionCore.Attempt] = []
    private static let patchLedgerKey = "skillPatchLedger"
    /// 待确认的补丁卡上限（收件箱不是补丁堆）。
    private static let maxPendingPatches = 5

    private static let candidatesKey = "skillCandidates"

    private init() {
        candidates = SkillCandidateCore.expiring(
            DiskStore.load([SkillCandidateCore.Candidate].self, key: Self.candidatesKey) ?? [],
            now: Date())
        DiskStore.save(candidates, key: Self.candidatesKey)
        if let data = AppPrefs.defaults.data(forKey: Self.ledgerKey),
           let decoded = try? JSONDecoder().decode(Ledger.self, from: data) {
            offeredAt = decoded.offeredAt
            conversationIDs = decoded.conversationIDs
        }
        if let data = AppPrefs.defaults.data(forKey: Self.patchLedgerKey),
           let decoded = try? JSONDecoder().decode([SkillCorrectionCore.Attempt].self, from: data) {
            patchAttempts = decoded
        }
    }

    private func saveLedger() {
        if let data = try? JSONEncoder().encode(
            Ledger(offeredAt: offeredAt, conversationIDs: conversationIDs)) {
            AppPrefs.defaults.set(data, forKey: Self.ledgerKey)
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

    /// 采纳结果（桥要回错误原因与备份路径；面板只用 `ok`）。
    struct AdoptOutcome {
        var ok: Bool
        var error: String?
        /// 补丁采纳：旧版备份的路径。
        var backupPath: String?
    }

    /// 采纳：草稿 → 写入正式技能库（与 saveSkill 工具同一写盘路径）；补丁 → 原文件
    /// 定点覆盖 + 旧版备份。两种都移除候选。
    @discardableResult
    func adopt(_ candidate: SkillCandidateCore.Candidate) -> Bool {
        adoptDetailed(candidate).ok
    }

    func adoptDetailed(_ candidate: SkillCandidateCore.Candidate) -> AdoptOutcome {
        if let patch = candidate.patch { return applyPatch(candidate, patch: patch) }
        let fileName = FilePathing.sanitizeFileName(candidate.name) + ".md"
        let url = SkillStore.directory.appendingPathComponent(fileName)
        let markdown = SkillAuthoring.markdown(name: candidate.name,
                                               description: candidate.description,
                                               instructions: candidate.instructions)
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.agent.error("skill candidate adopt failed: \(error.localizedDescription, privacy: .public)")
            return AdoptOutcome(ok: false, error: error.localizedDescription, backupPath: nil)
        }
        SkillStore.shared.reload()
        remove(candidate)
        return AdoptOutcome(ok: true, error: nil, backupPath: nil)
    }

    // MARK: - 补丁类候选（v0.8.76 批 4）

    /// 采纳补丁前的旧版备份目录。**放在技能目录之外**：技能目录被加载器重扫，桥的
    /// 文件列表、导入与同步都要遍历它，备份待在里面会被当成技能或被同步上去。
    static var backupDirectory: URL {
        let dir = StorageRoot.directory.appendingPathComponent("skill-backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 现在能不能为这个技能再烧一次补丁生成（只查不记）。
    func patchBudgetPasses(skill: String, conversationId: UUID?) -> Bool {
        SkillCorrectionCore.patchBudgetPasses(
            patchAttempts, skill: skill, conversationId: conversationId, now: Date())
    }

    func recordPatchAttempt(skill: String, conversationId: UUID?) {
        patchAttempts.append(.init(skill: skill, conversationId: conversationId, at: Date()))
        if let data = try? JSONEncoder().encode(patchAttempts) {
            AppPrefs.defaults.set(data, forKey: Self.patchLedgerKey)
        }
    }

    /// 旁路生成了补丁 → 落卡。落卡前先在**当前技能文件**上校验：模型抄错了原文、
    /// 或技能在此期间被改过，定位不到的补丁没有存在意义。
    @discardableResult
    func offerPatch(skill: String, patch: SkillCorrectionCore.Patch, conversationId: UUID?) -> Bool {
        let pendingPatches = candidates.filter { $0.patch != nil }.count
        let matches: (SkillStore.Skill) -> Bool = { $0.name.caseInsensitiveCompare(skill) == .orderedSame }
        guard let target = SkillStore.shared.skills.first(where: matches) else { return false }
        guard pendingPatches < Self.maxPendingPatches else { return false }
        guard !SkillCorrectionCore.isRedundantPatch(skill: target.name, find: patch.find,
                                                    pending: candidates) else { return false }
        guard let text = try? String(contentsOf: target.url, encoding: .utf8) else { return false }
        let verdict = SkillCorrectionCore.validate(patch, against: text)
        guard case .ok = verdict else {
            Log.agent.info("skill correction patch rejected (\(String(describing: verdict), privacy: .public)): \(target.name, privacy: .public)")
            return false
        }
        candidates.insert(.init(name: target.name, description: patch.reason, instructions: "",
                                conversationId: conversationId, patch: patch), at: 0)
        saveCandidates()
        return true
    }

    /// 定点覆盖技能文件。**采纳时重新校验**（候选生成之后技能可能被用户改过）；
    /// 已失效的补丁从收件箱移除——留一张永远点不动的卡没有意义。
    private func applyPatch(_ candidate: SkillCandidateCore.Candidate,
                            patch: SkillCorrectionCore.Patch) -> AdoptOutcome {
        guard let skill = SkillStore.shared.skills.first(where: { $0.name == candidate.name }) else {
            remove(candidate)
            return AdoptOutcome(ok: false, error: "skill no longer exists", backupPath: nil)
        }
        guard let text = try? String(contentsOf: skill.url, encoding: .utf8) else {
            return AdoptOutcome(ok: false, error: "skill file unreadable", backupPath: nil)
        }
        guard case .ok = SkillCorrectionCore.validate(patch, against: text),
              let patched = SkillCorrectionCore.apply(patch, to: text) else {
            remove(candidate)
            Log.agent.info("skill patch dropped — no longer applies: \(skill.name, privacy: .public)")
            return AdoptOutcome(ok: false, error: "patch no longer applies (skill changed since it was proposed)",
                                backupPath: nil)
        }
        let backup = Self.backupDirectory.appendingPathComponent(
            "\(FilePathing.sanitizeFileName(skill.name))-\(Self.backupStamp()).md")
        do {
            try FileManager.default.createDirectory(
                at: Self.backupDirectory, withIntermediateDirectories: true)
            try text.write(to: backup, atomically: true, encoding: .utf8)
            try patched.write(to: skill.url, atomically: true, encoding: .utf8)
        } catch {
            Log.agent.error("skill patch adopt failed: \(error.localizedDescription, privacy: .public)")
            return AdoptOutcome(ok: false, error: error.localizedDescription, backupPath: nil)
        }
        SkillStore.shared.reload()
        remove(candidate)
        Log.agent.info("skill patch adopted: \(skill.name, privacy: .public), backup=\(backup.lastPathComponent, privacy: .public)")
        return AdoptOutcome(ok: true, error: nil, backupPath: backup.path)
    }

    private static func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
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
