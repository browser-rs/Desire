import SwiftUI

/// 设置 ▸ 翻译（v0.8.64 批 1）：**术语表**编辑器——"原文 → 固定译法"的
/// 结构化对照表（全局 + 可选站点作用域），双语翻译时并入 system 的
/// Glossary 段。数据源 = `TranslationGlossaryStore`（唯一写入口）；与
/// v0.8.8 的记忆通道（`category=translation` 记忆事实）并存，两条入口的
/// 行都会注入（专用表在前）。
struct TranslationSettingsSection: View {
    @ObservedObject private var store = TranslationGlossaryStore.shared
    @State private var draftTerm = ""
    @State private var draftTranslation = ""
    @State private var draftHost = ""

    var body: some View {
        SettingsContainer {
            SettingsSection(
                title: String(localized: "Translation Glossary"),
                subtitle: String(localized: "Pin fixed renderings for names, product and domain terms so machine translation keeps them intact."),
                icon: "character.book.closed"
            ) {
                addRow
                if !store.entries.isEmpty {
                    SettingsRowDivider()
                }
                ForEach(store.entries) { entry in
                    entryRow(entry)
                    if entry.id != store.entries.last?.id {
                        SettingsRowDivider()
                    }
                }
                if store.entries.isEmpty {
                    SettingsRowDivider()
                    SettingsRow(String(localized: "No glossary entries yet"),
                                subtitle: String(localized: "Add a term above; it is applied to every bilingual translation."),
                                systemImage: "text.badge.plus") {
                        EmptyView()
                    }
                }
            }

            SettingsSection(
                title: String(localized: "Scope"),
                subtitle: String(localized: "Leave the site field empty to apply everywhere, or enter a host like example.com to pin it to that site (subdomains included). The older memory-based entries (category = translation) keep working alongside this table."),
                icon: "globe"
            ) {
                SettingsRow(String(localized: "Also via memory"),
                            subtitle: String(localized: "Memory facts categorized as translation still inject as glossary lines — no need to migrate them."),
                            systemImage: "tray.full") {
                    EmptyView()
                }
            }
        }
    }

    // MARK: - 添加表单

    private var canAdd: Bool {
        !draftTerm.trimmingCharacters(in: .whitespaces).isEmpty
            && !draftTranslation.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField(
                String(localized: "Glossary Term"),
                text: $draftTerm,
                prompt: Text(String(localized: "Original term")))
                .textFieldStyle(.roundedBorder)
            Text("→")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(
                String(localized: "Translation"),
                text: $draftTranslation,
                prompt: Text(String(localized: "Fixed rendering")))
                .textFieldStyle(.roundedBorder)
            TextField(
                String(localized: "Site (optional)"),
                text: $draftHost,
                prompt: Text(String(localized: "All sites")))
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
            SettingsCapsuleButton(
                String(localized: "Add"),
                isDisabled: !canAdd
            ) {
                store.add(TranslationGlossary.Entry(
                    term: draftTerm,
                    translation: draftTranslation,
                    host: draftHost.isEmpty ? nil : draftHost))
                draftTerm = ""
                draftTranslation = ""
                draftHost = ""
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - 条目行

    private func entryRow(_ entry: TranslationGlossary.Entry) -> some View {
        SettingsRow(entry.term,
                    subtitle: "→ " + entry.translation,
                    systemImage: entry.host == nil ? "globe" : "globe.asia.australia") {
            HStack(spacing: 8) {
                if let host = entry.host {
                    Text(host)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .foregroundStyle(.secondary)
                }
                Button {
                    if let idx = store.entries.firstIndex(where: { $0.id == entry.id }) {
                        store.remove(at: IndexSet(integer: idx))
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Remove entry"))
            }
        }
    }
}
