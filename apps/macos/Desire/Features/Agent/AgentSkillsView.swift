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

    @State private var searchText = ""
    /// skill name → 危险模式摘要（nil = 未扫出）。onAppear 扫一次，
    /// 导入/重扫后重算。
    @State private var riskSummaries: [String: String] = [:]
    @State private var previewSkill: SkillStore.Skill?
    @State private var importFailure: String?

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
                                onPreview: { previewSkill = skill }
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

/// 单条技能卡：名称 + 目录/单文件标 + 描述两行 + 风险徽标；点卡预览正文。
private struct AgentSkillCard: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let skill: SkillStore.Skill
    let riskSummary: String?
    let onPreview: () -> Void

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
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([skill.url])
            }
        }
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
