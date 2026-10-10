import SwiftUI

/// 技能库页（Agent 窗口侧栏"技能"目的地，2026-10-10）。数据全部来自
/// `SkillStore`（与 Agent 提示词里的技能清单同源）：列表、导入（zip/目录/
/// 单 md）、重新扫描、正文预览；每条技能经 `SkillScanner` 做危险模式扫描并
/// 给出风险徽标（只提示不拦截，拦截交给既有审批链）。
struct AgentSkillsView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject private var store = SkillStore.shared
    var onBack: () -> Void
    /// "在对话中使用"：切回聊天列并把使用指令发给 Agent（nil = 不显示该入口）。
    var onUseSkill: ((String) -> Void)? = nil

    @State private var searchText = ""
    /// skill name → 危险模式摘要（nil = 未扫出）。onAppear 扫一次，
    /// 导入/重扫后重算。
    @State private var riskSummaries: [String: String] = [:]
    @State private var previewSkill: SkillStore.Skill?
    @State private var importFailure: String?
    /// nil = 新建；非 nil = 编辑该技能（写入它的 url，同名即覆盖）。
    @State private var editingSkill: SkillStore.Skill?
    @State private var isCreating = false

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(filtered) { skill in
                            AgentSkillCard(
                                skill: skill,
                                riskSummary: riskSummaries[skill.name],
                                onPreview: { previewSkill = skill },
                                onEdit: { editingSkill = skill },
                                onUse: onUseSkill
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
    let onPreview: () -> Void
    let onEdit: () -> Void
    let onUse: ((String) -> Void)?

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
private struct AgentSkillEditorSheet: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @Environment(\.dismiss) private var dismiss
    let editing: SkillStore.Skill?
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
