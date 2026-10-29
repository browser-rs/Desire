import SwiftUI

/// 设置 ▸ 搜索与索引（v0.8.22）：端上语义索引的总开关、逐源控制、状态与
/// 重建/清空。数据源与状态全部来自 `SemanticIndexStore`（同一份真相，
/// 桥端点 `GET /index/status` 读的也是它）。
struct SemanticIndexSettingsSection: View {
    @ObservedObject var store: SemanticIndexStore
    /// 历史正文索引的开关在隐私页——这里只读它来决定提示文案，所以要观察。
    @ObservedObject private var historyContent = HistoryContentStore.shared
    @State private var showClearConfirm = false

    var body: some View {
        SettingsContainer {
            SettingsSection(
                title: "Semantic Search",
                subtitle: "Find saved pages, excerpts and notes by meaning, not only by matching words. Runs entirely on this Mac.",
                icon: "text.magnifyingglass"
            ) {
                SettingsToggleRow(
                    "Enable Semantic Search",
                    subtitle: "Literal matches stay first; semantic results fill the gaps when words do not line up.",
                    systemImage: "sparkles",
                    isOn: Binding(
                        get: { store.isEnabled },
                        set: { store.setEnabled($0) }
                    )
                )
                ForEach(SemanticSource.allCases, id: \.self) { source in
                    SettingsRowDivider()
                    SettingsToggleRow(
                        title(for: source),
                        subtitle: subtitle(for: source),
                        systemImage: icon(for: source),
                        isOn: Binding(
                            get: { store.isSourceEnabled(source) },
                            set: { store.setSourceEnabled(source, enabled: $0) }
                        )
                    )
                    .disabled(!store.isEnabled)
                }
            }

            SettingsSection(
                title: "Index Status",
                subtitle: statusLine,
                icon: "externaldrive"
            ) {
                SettingsRow("On-device Index", subtitle: storageLine, systemImage: "internaldrive") {
                    HStack(spacing: 8) {
                        if store.isBuilding {
                            ProgressView()
                                .controlSize(.small)
                        }
                        SettingsCapsuleButton(
                            "Rebuild",
                            systemImage: "arrow.clockwise",
                            style: .secondary,
                            isDisabled: store.isBuilding || !store.isEnabled
                        ) {
                            store.rebuild()
                        }
                        SettingsCapsuleButton(
                            "Clear",
                            systemImage: "trash",
                            style: .destructive,
                            isDisabled: store.isBuilding
                        ) {
                            showClearConfirm = true
                        }
                    }
                }
            }

            Text("Index data stays on this Mac — it is never synced or included in backups. Conversations are only indexed when you turn them on, and history pages follow the Page Text setting under Privacy.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(
            "Clear the semantic index?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Index", role: .destructive) { store.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Literal search keeps working. The index rebuilds when sources change or when you press Rebuild.")
        }
    }

    // MARK: - 文案

    private func title(for source: SemanticSource) -> String {
        switch source {
        case .history: return String(localized: "History Pages")
        case .bookmark: return String(localized: "Bookmarks")
        case .excerpt: return String(localized: "Excerpts")
        case .highlight: return String(localized: "Reading Highlights")
        case .conversation: return String(localized: "Agent Conversations")
        }
    }

    private func icon(for source: SemanticSource) -> String {
        switch source {
        case .history: return "clock"
        case .bookmark: return "bookmark"
        case .excerpt: return "text.quote"
        case .highlight: return "highlighter"
        case .conversation: return "bubble.left.and.bubble.right"
        }
    }

    private func subtitle(for source: SemanticSource) -> String {
        var parts: [String] = []
        if let entry = store.status.first(where: { $0.source == source }) {
            parts.append(String(localized: "\(entry.itemCount) items indexed"))
        } else {
            parts.append(String(localized: "Not indexed yet"))
        }
        switch source {
        case .conversation:
            parts.append(String(localized: "Off by default — messages can contain private details"))
        case .history:
            if !historyContent.isEnabled {
                parts.append(String(localized: "Turn on Page Text under Privacy first"))
            }
        default:
            break
        }
        return parts.joined(separator: " · ")
    }

    private var statusLine: String {
        guard store.isEnabled else {
            return String(localized: "Semantic search is off.")
        }
        if store.isBuilding {
            return String(localized: "Building index…")
        }
        let total = store.status.reduce(0) { $0 + $1.itemCount }
        guard total > 0 else {
            return String(localized: "Nothing indexed yet.")
        }
        var parts = [String(localized: "\(total) items indexed")]
        if let built = store.lastBuildAt ?? store.status.compactMap(\.builtAt).max() {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            parts.append(formatter.localizedString(for: built, relativeTo: Date()))
        }
        if let error = store.lastError, !error.isEmpty {
            parts.append(error)
        }
        return parts.joined(separator: " · ")
    }

    private var storageLine: String {
        let bytes = store.status.reduce(0) { $0 + $1.bytes }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let perSource = SemanticSource.allCases.compactMap { source -> String? in
            guard let entry = store.status.first(where: { $0.source == source }),
                  entry.itemCount > 0 else { return nil }
            return "\(title(for: source)) \(entry.itemCount)"
        }
        let sourcePart = perSource.isEmpty
            ? String(localized: "No items yet")
            : perSource.joined(separator: " · ")
        return sourcePart + " · " + size
    }
}
