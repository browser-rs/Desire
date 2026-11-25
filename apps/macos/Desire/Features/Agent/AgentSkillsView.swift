import CoreImage.CIFilterBuiltins
import CryptoKit
import SwiftUI

/// 技能库页（Agent 窗口侧栏"技能"目的地，2026-10-10）。数据全部来自
/// `SkillStore`（与 Agent 提示词里的技能清单同源）：列表、导入（zip/目录/
/// 单 md）、重新扫描、正文预览；每条技能经 `SkillScanner` 做危险模式扫描并
/// 给出风险徽标（只提示不拦截，拦截交给既有审批链）。
struct AgentSkillsView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject private var store = SkillStore.shared
    /// 技能候选收件箱（v0.8.72 批 2）：成功回合蒸馏的草稿等用户采纳。
    @ObservedObject private var candidateStore = SkillCandidateStore.shared
    var onBack: () -> Void
    /// "在对话中使用"：切回聊天列并把使用指令发给 Agent（nil = 不显示该入口）。
    var onUseSkill: ((String) -> Void)? = nil
    /// 参数化技能（v0.8.17）：声明 vars 的技能使用时弹填值表单。
    @State private var varsSkill: SkillStore.Skill?
    /// 技能 Gallery（v0.8.19 旗舰）。
    @State private var showGallery = false
    @State private var varValues: [String: String] = [:]

    @State private var searchText = ""
    /// skill name → 危险模式摘要（nil = 未扫出）。onAppear 扫一次，
    /// 导入/重扫后重算。
    @State private var riskSummaries: [String: String] = [:]
    @State private var previewSkill: SkillStore.Skill?
    @State private var importFailure: String?
    /// 从 URL 安装（v0.8.6）：alert 里的输入。
    @State private var showInstallURL = false
    @State private var installURLText = ""
    @State private var isInstallingFromURL = false
    /// 导出落盘成功提示（skill 名 → 路径）。
    @State private var exportedPath: String?
    /// 分享（v0.8.10）：出直链 + QR 的 sheet。
    @State private var shareSkill: SkillStore.Skill?
    /// 检查更新的进行中标记（skill 名）。
    @State private var updateChecking: String?
    /// nil = 新建；非 nil = 编辑该技能（写入它的 url，同名即覆盖）。
    @State private var editingSkill: SkillStore.Skill?
    @State private var isCreating = false
    /// 重新蒸馏进行中（技能名）。
    @State private var isRedistilling: String?

    /// **重新蒸馏**（v0.8.73 批 3）：连败技能定位它最近一次使用的会话，
    /// 从那份运行记录起草新技能 → 走候选收件箱（用户确认后覆盖）。会话已
    /// 清理时如实提示。
    private func handleRedistill(_ skill: SkillStore.Skill) {
        guard let convId = store.usage[skill.name]?.lastUsedConversationId else { return }
        let conversation = ConversationStore().conversation(for: convId)
        guard let messages = conversation?.messages, messages.count >= 8 else {
            exportedPath = nil
            importFailure = String(localized: "The source conversation is no longer available")
            return
        }
        guard let preference = AppState.live?.aiPreference else { return }
        isRedistilling = skill.name
        Task {
            let draft = await SkillDistiller.draft(from: messages, preference: preference)
            isRedistilling = nil
            guard let draft else {
                importFailure = String(localized: "Could not distill a draft from that run")
                return
            }
            _ = SkillCandidateStore.shared.offer(
                name: draft.name, description: draft.description,
                instructions: draft.instructions, conversationId: convId)
        }
    }

    private func handleUse(name: String) {
        guard let onUseSkill else { return }
        guard let skill = SkillStore.shared.skills.first(where: { $0.name == name }),
              !skill.vars.isEmpty else {
            onUseSkill(name)
            return
        }
        varValues = Dictionary(uniqueKeysWithValues: skill.vars.compactMap { var_ in
            var_.defaultValue.map { (var_.name, $0) }
        })
        varsSkill = skill
    }

    private func sendWithVars() {
        guard let skill = varsSkill, let onUseSkill else { return }
        let assignments = skill.vars.compactMap { var_ -> String? in
            guard let value = varValues[var_.name]?.trimmingCharacters(in: .whitespaces),
                  !value.isEmpty else { return nil }
            return "\(var_.name)=\(value)"
        }
        varsSkill = nil
        if assignments.isEmpty {
            onUseSkill(skill.name)
        } else {
            onUseSkill("Use the \(skill.name) skill — variables: " + assignments.joined(separator: "; "))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            if filtered.isEmpty && candidateStore.candidates.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        // 候选区（v0.8.72 批 2）置顶：成功回合蒸馏的草稿，浮出来等采纳。
                        if !candidateStore.candidates.isEmpty {
                            SkillCandidatesBand(
                                candidates: candidateStore.candidates,
                                onAdopt: { _ = candidateStore.adopt($0) },
                                onDiscard: { candidateStore.discard($0) })
                        }
                        ForEach(filtered) { skill in
                            AgentSkillCard(
                                skill: skill,
                                riskSummary: riskSummaries[skill.name],
                                usage: store.usage[skill.name],
                                onRedistill: handleRedistill,
                                onPreview: { previewSkill = skill },
                                onEdit: { editingSkill = skill },
                                onUse: { handleUse(name: $0) },
                                onExport: { exportSkill($0) },
                                onShare: { shareSkill = $0 },
                                onUpdateCheck: { checkForUpdate($0) }
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            scanRisks()
        }
        .sheet(item: $previewSkill) { skill in
            AgentSkillPreviewSheet(skill: skill)
        }
        .sheet(isPresented: $isCreating) {
            AgentSkillEditorSheet(editing: nil) {
                store.reload()
                scanRisks()
            }
        }
        .sheet(item: $editingSkill) { skill in
            AgentSkillEditorSheet(editing: skill) {
                store.reload()
                scanRisks()
            }
        }
        .sheet(item: $shareSkill) { skill in
            SkillShareSheet(skill: skill)
        }
        .sheet(isPresented: $showGallery) {
            SkillGallerySheet()
        }
        .onChange(of: showGallery) { _, shown in
            // 安装完回来重扫风险（v0.8.21：此前新装技能的风险徽标要等下次出现）
            if !shown { scanRisks() }
        }
        .sheet(item: $varsSkill) { skill in
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "Use \(skill.name) — fill variables"))
                    .font(.system(size: 12.5, weight: .semibold))
                ForEach(skill.vars, id: \.name) { var_ in
                    HStack(spacing: 8) {
                        Text(var_.description ?? var_.name)
                            .font(.system(size: 11))
                            .frame(width: 130, alignment: .leading)
                        TextField(var_.name, text: Binding(
                            get: { varValues[var_.name] ?? "" },
                            set: { varValues[var_.name] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                }
                HStack {
                    Spacer()
                    Button(String(localized: "Cancel")) { varsSkill = nil }
                        .keyboardShortcut(.cancelAction)
                    Button(String(localized: "Use")) { sendWithVars() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 340)
        }

        .alert(
            String(localized: "Import failed"),
            isPresented: Binding(
                get: { importFailure != nil },
                set: { if !$0 { importFailure = nil } }
            )
        ) {
            Button(String(localized: "OK")) { importFailure = nil }
        } message: {
            Text(importFailure ?? "")
        }
        .alert(String(localized: "Install from URL"), isPresented: $showInstallURL) {
            TextField("https://…/SKILL.md or .zip", text: $installURLText)
            Button(String(localized: "Install")) {
                installFromURL()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Paste a direct link to a .skill zip or a SKILL.md file (e.g. a GitHub raw URL).")
        }
        .alert(
            String(localized: "Skill exported"),
            isPresented: Binding(
                get: { exportedPath != nil },
                set: { if !$0 { exportedPath = nil } }
            )
        ) {
            Button(String(localized: "Show in Finder")) {
                if let path = exportedPath {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            Button(String(localized: "OK")) { exportedPath = nil }
        } message: {
            Text(exportedPath ?? "")
        }
    }

    // MARK: - Header / toolbar

    private var header: some View {
        HStack(spacing: 6) {
            HoverIcon(systemName: "chevron.left", action: onBack, help: "Back")
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Skills")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("\(store.skills.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
            )

            Button {
                pickAndImport()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Import"))

            Button {
                installURLText = ""
                showInstallURL = true
            } label: {
                Image(systemName: "globe.badge.chevron.backward")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Install from URL"))

            Button {
                showGallery = true
            } label: {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Skill Gallery"))

            Button {
                store.reload()
                scanRisks()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help("Rescan")

            Button {
                isCreating = true
            } label: {
                Image(systemName: "plus.square.on.square")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help("New Skill")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var filtered: [SkillStore.Skill] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.skills }
        return store.skills.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - Actions

    private func pickAndImport() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        // 不按类型过滤：zip / 目录 / 单 md 都合法，导入器自己校验并报错。
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                _ = try store.importArchive(at: url)
                scanRisks()
            } catch {
                importFailure = error.localizedDescription
            }
        }
    }

    private func installFromURL() {
        let trimmed = installURLText.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            importFailure = String(localized: "Not a valid URL")
            return
        }
        isInstallingFromURL = true
        Task { @MainActor in
            defer { isInstallingFromURL = false }
            do {
                _ = try await store.installFromURL(url)
                scanRisks()
            } catch {
                importFailure = error.localizedDescription
            }
        }
    }

    /// 检查更新（v0.8.11）：重下远程内容 → hash 比对 → 不同则重装（同名覆盖）。
    private func checkForUpdate(_ skill: SkillStore.Skill) {
        guard let source = skill.sourceURL, let url = URL(string: source) else { return }
        updateChecking = skill.name
        Task { @MainActor in
            defer { updateChecking = nil }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    importFailure = String(localized: "Update check failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                    return
                }
                let digest = SHA256.hash(data: data)
                let remoteHash = digest.map { String(format: "%02x", $0) }.joined()
                if remoteHash == skill.contentHash {
                    importFailure = String(localized: "\"\(skill.name)\" is up to date.")
                    return
                }
                let ext = url.pathExtension.lowercased() == "zip" ? "zip" : "md"
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("skill-update-\(UUID().uuidString).\(ext)")
                try data.write(to: tmp)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let updated = try store.importArchive(at: tmp)
                // 重装后补盖来源与**新内容的 hash**（当前盘上内容）。
                store.stampSource(name: updated.name, sourceURL: source,
                                  contentHash: SkillStore.currentHash(for: updated))
                scanRisks()
                importFailure = String(localized: "\"\(updated.name)\" updated.")
            } catch {
                importFailure = error.localizedDescription
            }
        }
    }

    /// 导出为 .skill 包（Save 面板选落点）。
    private func exportSkill(_ skill: SkillStore.Skill) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Skill")
        panel.nameFieldStringValue = skill.directory != nil ? "\(skill.name).skill" : "\(skill.name).md"
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                _ = try store.exportPackage(named: skill.name, to: dest)
                exportedPath = dest.path
            } catch {
                importFailure = error.localizedDescription
            }
        }
    }

    /// 对每条技能正文跑危险模式扫描（文件都很小，一次性扫完）。
    private func scanRisks() {
        var out: [String: String] = [:]
        for skill in store.skills {
            guard let body = store.body(for: skill.name) else { continue }
            if let summary = SkillScanner.summary(for: body) {
                out[skill.name] = summary
            }
        }
        riskSummaries = out
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .frame(width: 48, height: 48)
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
            Text("No skills yet")
                .font(.system(size: 13, weight: .semibold))
            Text("Skills are markdown files in Application Support/Desire/skills — the agent loads them on demand.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Card

/// 单条技能卡：名称 + 目录/单文件标 + 描述两行 + 风险徽标；点卡预览正文，
/// 右键编辑/在对话中使用/在 Finder 中显示。
private struct AgentSkillCard: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let skill: SkillStore.Skill
    let riskSummary: String?
    /// 使用统计（v0.8.72 批 3，B3 健康展示；nil = 从未使用不显示）。
    var usage: SkillStore.SkillUsage? = nil
    /// 重新蒸馏（v0.8.73 批 3）：连败技能入口——nil = 不显示（宿主未接）。
    var onRedistill: ((SkillStore.Skill) -> Void)? = nil
    let onPreview: () -> Void
    let onEdit: () -> Void
    let onUse: ((String) -> Void)?
    /// 导出 .skill 包（v0.8.6 分发）。
    var onExport: ((SkillStore.Skill) -> Void)? = nil
    /// 分享直链+QR（v0.8.10）。
    var onShare: ((SkillStore.Skill) -> Void)? = nil
    /// 检查更新（v0.8.11）：远程内容 hash 比对。
    var onUpdateCheck: ((SkillStore.Skill) -> Void)? = nil

    /// **健康展示**（B3）：SkillHealth 语义 → 卡片底行。只提示不硬闸。
    /// 键用 \(x) 内插形式（目录键自动成 %lld/%@）；字面 % 不能进键。
    @ViewBuilder
    private var usageFooter: some View {
        switch SkillHealth.assess(count: usage?.count ?? 0, outcomes: usage?.outcomes ?? []) {
        case .unused:
            EmptyView()
        case .insufficientSamples:
            Text(String(localized: "Used \(usage?.count ?? 0) times — insufficient samples"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        case .healthy(let rate):
            let pctText = "\(Int((rate * 100).rounded()))%"
            Text(String(localized: "Used \(usage?.count ?? 0) times — success rate: \(pctText)"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        case .failingStreak(let streak):
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Failed \(streak) recent runs in a row — consider re-distilling or retiring this skill"))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                if let onRedistill {
                    Button(String(localized: "Re-distill from its last run")) {
                        onRedistill(skill)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(usage?.lastUsedConversationId == nil)
                    .help(usage?.lastUsedConversationId == nil
                          ? String(localized: "The source conversation is no longer available")
                          : String(localized: "Distill a fresh draft from the conversation that last used this skill"))
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: skill.directory != nil ? "folder" : "doc.text")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(skill.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let riskSummary {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                        Text(riskSummary)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
                    .help(riskSummary)
                }
                Spacer(minLength: 4)
                if skill.directory != nil {
                    Text("DIR")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            if !skill.description.isEmpty {
                Text(skill.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            usageFooter
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onPreview()
        }
        .contextMenu {
            if let onUse {
                Button(String(localized: "Use the \(skill.name) skill")) {
                    onUse(skill.name)
                }
            }
            Button("Edit") { onEdit() }
            if let onExport {
                Button(String(localized: "Export…")) { onExport(skill) }
            }
            if let onShare {
                Button(String(localized: "Share…")) { onShare(skill) }
            }
            if skill.sourceURL != nil, let onUpdateCheck {
                Button(String(localized: "Check for Updates")) { onUpdateCheck(skill) }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([skill.url])
            }
        }
    }
}

// MARK: - Editor sheet

/// 技能编辑器（新建/编辑共用，2026-10-10）：名称/描述/使用说明三字段 →
/// `SkillAuthoring.markdown` 渲染 SKILL.md。新建写到技能目录 `<名称>.md`；
/// 编辑写回原文件（含目录 skill 的 SKILL.md）。同名 = 覆盖（与导入同语义）。
struct AgentSkillEditorSheet: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @Environment(\.dismiss) private var dismiss
    let editing: SkillStore.Skill?
    /// 新建态的预填草稿（「从会话提炼技能」的产物）；editing 非 nil 时忽略。
    var draftPrelude: SkillDistill.Draft? = nil
    /// 保存成功后回调（宿主 reload + 重扫风险）。
    let onSaved: () -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    @State private var failureText: String?
    @State private var seeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(editing == nil ? String(localized: "New Skill") : String(localized: "Edit"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(String(localized: "Name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(editing != nil)

                Text("Description")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("", text: $description)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                Text("Instructions")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $instructions)
                    .font(.system(size: 12))
                    .frame(minHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )

                if let failureText {
                    Text(failureText)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button(String(localized: "Cancel")) { dismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Save")) { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave)
                }
                .font(.system(size: 12))
            }
            .padding(14)
        }
        .frame(width: 460)
        .onAppear {
            // sheet 内容只播种一次（sheet 复用同一视图值时防重置）。
            guard !seeded else { return }
            seeded = true
            if let editing {
                name = editing.name
                description = editing.description
                instructions = Self.stripFrontmatter(
                    (try? String(contentsOf: editing.url, encoding: .utf8)) ?? "")
            } else if let draftPrelude {
                name = draftPrelude.name
                description = draftPrelude.description
                instructions = draftPrelude.instructions
            }
        }
    }

    private var canSave: Bool {
        !cleanName.isEmpty && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 名称去首尾空白与 .md 后缀；编辑态锁定原名（改名=新建，避免目录
    /// skill 的附属文件失联）。
    private var cleanName: String {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.hasSuffix(".md") { n = String(n.dropLast(3)) }
        return n
    }

    private func save() {
        guard cleanName.contains("/") == false else {
            failureText = String(localized: "Name cannot contain /")
            return
        }
        let markdown = SkillAuthoring.markdown(
            name: cleanName,
            description: description,
            instructions: instructions
        )
        let target: URL
        if let editing {
            target = editing.url
        } else {
            target = SkillStore.directory.appendingPathComponent("\(cleanName).md")
        }
        do {
            try markdown.write(to: target, atomically: true, encoding: .utf8)
            onSaved()
            dismiss()
        } catch {
            failureText = String(localized: "Save failed")
        }
    }

    /// 剥掉正文自带的 frontmatter（权威 frontmatter 由 SkillAuthoring 重新生成）。
    private static func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---"), let end = text.range(of: "\n---") else { return text }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Preview sheet

/// 技能正文预览（原始 markdown，等宽字体）。
private struct AgentSkillPreviewSheet: View {
    let skill: SkillStore.Skill
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: skill.directory != nil ? "folder" : "doc.text")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(skill.name)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                Text(bodyText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .textSelection(.enabled)
            }
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 420)
    }

    private var bodyText: String {
        (try? String(contentsOf: skill.url, encoding: .utf8)) ?? ""
    }
}


// MARK: - 技能分享（v0.8.10）：直链 + QR

/// 分享一张技能：输入直链（GitHub raw / gist），出可扫的 QR 与可拷贝的
/// 链接——对方「从 URL 安装」即得（installFromURL 语义：zip/md 均可）。
private struct SkillShareSheet: View {
    @Environment(\.appAccent) private var appAccent: Color
    let skill: SkillStore.Skill
    @State private var shareURL = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "qrcode")
                    .foregroundStyle(appAccent)
                Text(String(localized: "Share \"\(skill.name)\""))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Direct link to the .skill zip or SKILL.md (GitHub raw works)"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("https://…", text: $shareURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    HStack {
                        Button(String(localized: "Copy Link")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(shareURL, forType: .string)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(shareURL.isEmpty)
                        Spacer()
                    }
                    Text(String(localized: "The recipient installs it via Skills → Install from URL; the risk scan runs on import."))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let qr = Self.makeQR(shareURL) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 140, height: 140)
                        .background(Color.white)
                        .cornerRadius(8)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.08))
                        Text(String(localized: "Paste a link to render the QR"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(8)
                    }
                    .frame(width: 140, height: 140)
                }
            }
        }
        .padding(16)
        .frame(width: 480, height: 240)
    }

    static func makeQR(_ string: String) -> NSImage? {
        guard !string.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// **技能候选收件箱卡组**（v0.8.72 批 2）：成功回合旁路蒸馏的技能草稿，
/// 置顶浮出——采纳写正式技能库（与 saveSkill 同一写盘路径），忽略即弃。
/// 候选永不自动入库（SkillCandidateCore 的原则在这里落地成 UI）。
///
/// v0.8.76 批 4 起另有**补丁卡**：用户纠正后给已有技能的定点修正（改前 → 改后），
/// 采纳 = 原文件覆盖 + 旧版备份；卡片把两段原文都摆出来，让用户看得见再决定。
private struct SkillCandidatesBand: View {
    let candidates: [SkillCandidateCore.Candidate]
    let onAdopt: (SkillCandidateCore.Candidate) -> Void
    let onDiscard: (SkillCandidateCore.Candidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(String(localized: "Skill suggestions — distilled from recent runs"),
                  systemImage: "sparkles")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.tint)
            ForEach(candidates) { candidate in
                Group {
                    if let patch = candidate.patch {
                        patchBody(candidate, patch: patch)
                    } else {
                        draftBody(candidate)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05)))
            }
        }
    }

    /// 新技能草稿卡。
    private func draftBody(_ candidate: SkillCandidateCore.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(candidate.name)
                .font(.system(size: 12.5, weight: .semibold))
            Text(candidate.description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(String(localized: "Save as Skill")) { onAdopt(candidate) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(String(localized: "Ignore")) { onDiscard(candidate) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    /// 补丁卡：技能名 + 理由 + 改前/改后两段原文。
    private func patchBody(_ candidate: SkillCandidateCore.Candidate,
                           patch: SkillCorrectionCore.Patch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(String(localized: "Skill correction"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.tint.opacity(0.14)))
                Text(candidate.name)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            Text(patch.reason)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            diffRow(label: String(localized: "Before"), text: patch.find, removed: true)
            diffRow(label: String(localized: "After"), text: patch.replace, removed: false)
            HStack(spacing: 8) {
                Button(String(localized: "Apply to Skill")) { onAdopt(candidate) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(String(localized: "Ignore")) { onDiscard(candidate) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    /// 改前/改后一行。改后为空串 = 删掉这一段。
    private func diffRow(label: String, text: String, removed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(removed ? Color.secondary : Color.green)
                .frame(width: 34, alignment: .leading)
            Text(text.isEmpty ? String(localized: "(removed)") : text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
