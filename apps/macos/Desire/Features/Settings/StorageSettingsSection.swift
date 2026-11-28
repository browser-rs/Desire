import SwiftUI

/// 存储健康（v0.8.80 批 6）：按域体量、缓存一键清理、会话/归档保留天数。
/// 数据与桥 `GET /diag/storage`、Doctor 同源（`StorageMaintenance`）。
struct StorageSettingsSection: View {
    @State private var domains: [StorageMaintenance.DomainInfo] = []
    @State private var conversationDays = 0
    @State private var archiveDays = 0
    @State private var pendingClear: StorageMaintenance.DomainInfo?
    @State private var pendingDeleteOld: StorageMaintenance.DomainInfo?
    /// 首次进入存储分区的一句引导（v0.8.83）。
    @AppStorage("hint.storage.seen", store: AppPrefs.defaults) private var storageHintSeen = false

    private var total: Int { domains.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        // 必须走 SettingsContainer（限宽/留白）：裸 SettingsSection 的标题会被
        // 窗口标题栏压住、内容顶满边——v0.8.80 起一直如此（2026-11-28 用户报告）。
        SettingsContainer {
            if !storageHintSeen {
                SettingsHintBanner(
                    icon: "internaldrive",
                    text: "Caches are safe to clear. Conversations and archives are only deleted when you set a retention period; the open conversation is never touched.",
                    onDismiss: { storageHintSeen = true })
            }
            SettingsSection(
                title: String(localized: "Storage"),
                subtitle: String(localized: "Disk use by data type. Caches can be cleared safely; conversations are only deleted when you set a retention period."),
                icon: "internaldrive"
            ) {
                SettingsRow(
                    String(localized: "Total"),
                    subtitle: ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file),
                    systemImage: "chart.pie"
                ) {
                    Button(String(localized: "Refresh")) { reload() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                ForEach(domains, id: \.id) { domain in
                    SettingsRowDivider()
                    SettingsRow(domain.title,
                                subtitle: detail(domain),
                                systemImage: icon(domain.id)) {
                        if domain.clearable {
                            if domain.id == "conversations" {
                                retentionControls(domain, binding: $conversationDays)
                            } else if domain.id == "archives" {
                                retentionControls(domain, binding: $archiveDays)
                            } else {
                                Button(String(localized: "Clear"), role: .destructive) {
                                    pendingClear = domain
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { reload() }
        .confirmationDialog(
            String(localized: "Clear this data?"),
            isPresented: Binding(get: { pendingClear != nil },
                                 set: { if !$0 { pendingClear = nil } }),
            titleVisibility: .visible
        ) {
            if let domain = pendingClear {
                Button(String(localized: "Clear \(domain.title)"), role: .destructive) {
                    StorageMaintenance.clean(domain: domain.id)
                    reload()
                    pendingClear = nil
                }
                Button(String(localized: "Cancel"), role: .cancel) { pendingClear = nil }
            }
        } message: {
            Text(String(localized: "Cleared data cannot be recovered. Conversations and archives are not touched here."))
        }
    }

    private func retentionControls(_ domain: StorageMaintenance.DomainInfo,
                                   binding: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Stepper(value: binding, in: 0...3650, step: 30) {
                Text(binding.wrappedValue == 0
                     ? String(localized: "Keep forever")
                     : String(format: String(localized: "Keep %lld days"), binding.wrappedValue))
                    .font(.system(size: 10.5))
            }
            .onChange(of: binding.wrappedValue) { _, value in
                StorageMaintenance.setRetentionDays(value, for: domain.id)
                reload()
            }
            if binding.wrappedValue > 0 {
                Button(String(localized: "Delete old"), role: .destructive) {
                    pendingDeleteOld = domain
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .confirmationDialog(
            String(localized: "Delete data older than the retention period?"),
            isPresented: Binding(get: { pendingDeleteOld?.id == domain.id },
                                 set: { if !$0 { pendingDeleteOld = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete now"), role: .destructive) {
                StorageMaintenance.clean(domain: domain.id)
                pendingDeleteOld = nil
                reload()
            }
            Button(String(localized: "Cancel"), role: .cancel) { pendingDeleteOld = nil }
        }
    }

    private func detail(_ domain: StorageMaintenance.DomainInfo) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(domain.bytes), countStyle: .file)
        if domain.id == "conversations" {
            return "\(size) · \(domain.count) · \(conversationDays == 0 ? String(localized: "keep forever") : String(format: String(localized: "%lld days"), conversationDays))"
        }
        if domain.id == "archives" {
            return "\(size) · \(domain.count) · \(archiveDays == 0 ? String(localized: "keep forever") : String(format: String(localized: "%lld days"), archiveDays))"
        }
        return domain.count > 0 ? "\(size) · \(domain.count)" : size
    }

    private func icon(_ id: String) -> String {
        switch id {
        case "conversations": "bubble.left.and.bubble.right"
        case "archives": "archivebox"
        case "sessions": "macwindow"
        case "translations": "character.book.closed"
        case "batchLogs": "doc.text.magnifyingglass"
        case "memory": "brain.head.profile"
        case "toolResults": "externaldrive"
        case "downloadResume": "arrow.down.circle"
        case "batchArchive": "archivebox.circle"
        default: "folder"
        }
    }

    private func reload() {
        domains = StorageMaintenance.scan()
        conversationDays = StorageMaintenance.retentionDays(for: "conversations")
        archiveDays = StorageMaintenance.retentionDays(for: "archives")
    }
}
