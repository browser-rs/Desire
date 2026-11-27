import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PasswordPanel: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var passwordStore: PasswordStore
    @State private var searchText = ""
    @State private var showClearConfirmation = false
    @State private var showGenerator = false
    @State private var generatedPassword = ""
    @State private var generatorLength = 16
    @State private var generatorSymbols = true
    @State private var importResult: String?
    /// 新增 / 编辑表单（v0.8.80）。
    @State private var showEditor = false
    @State private var editingEntry: PasswordEntry?
    /// 健康与泄露（v0.8.80）：只在用户点击时计算（读 Keychain + 联网）。
    @State private var healthReport: PasswordHealth.Report?
    @State private var breaches: [UUID: Int] = [:]
    @State private var healthNote: String?
    @State private var isCheckingHealth = false
    /// 加密密码包导出/导入（v0.8.82）。
    @State private var archivePrompt: PasswordArchivePrompt?
    @State private var archiveResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let visibleHealthReport, !visibleHealthReport.isClean || healthNote != nil {
                healthStrip(visibleHealthReport)
                Divider().opacity(0.5)
            }
            // 内嵌搜索行（替代 .searchable）：sheet 场景下 searchable 会把搜索框
            // 挂到窗体右上角，孤零零一个带粗焦点环的输入框，和内容脱节（用户实测
            // "布局不合理"）。自绘搜索行与书签面板同一套语言。
            if !passwordStore.entries.isEmpty {
                searchField
                Divider().opacity(0.5)
            }

            if filtered.isEmpty {
                EmptyState(
                    title: String(localized: searchText.isEmpty ? "No Saved Passwords" : "No Matching Passwords"),
                    systemImage: "lock.keyhole",
                    description: searchText.isEmpty
                        ? String(localized: "Passwords saved while signing in to websites appear here.")
                        : nil
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, entry in
                            PasswordRow(
                                entry: entry,
                                issues: visibleHealthReport?.findings.first { $0.entryID == entry.id }?.issues ?? [],
                                breachCount: breaches[entry.id],
                                onDelete: { passwordStore.delete(entry) },
                                onEdit: {
                                    editingEntry = entry
                                    showEditor = true
                                },
                                loadPassword: { passwordStore.password(for: entry) },
                                onOpenSite: {
                                    // 健康卡发现问题后的下一步：打开站点去改密。
                                    if let url = URL(string: "https://\(entry.domain)") {
                                        TabSessionCoordinator.shared.activeTabManager?
                                            .addTab(url: url.absoluteString)
                                    }
                                },
                                onMuteHealth: { days in
                                    passwordStore.muteHealth(entryID: entry.id, days: days)
                                },
                                isHealthMuted: passwordStore.mutedHealthIDs().contains(entry.id)
                            )
                            if idx < filtered.count - 1 {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 420, height: 500)
        .sheet(isPresented: $showEditor) {
            PasswordEditorSheet(store: passwordStore, entry: editingEntry)
        }
        .sheet(item: $archivePrompt) { prompt in
            PasswordArchiveSheet(prompt: prompt, store: passwordStore) { message in
                archiveResult = message
            }
        }
        .alert("Password Archive", isPresented: Binding(
            get: { archiveResult != nil },
            set: { if !$0 { archiveResult = nil } }
        )) {
            Button("OK") { archiveResult = nil }
        } message: {
            Text(archiveResult ?? "")
        }
        .sheet(isPresented: $showGenerator) {
            PasswordGeneratorSheet(
                generatedPassword: $generatedPassword,
                generatorLength: $generatorLength,
                generatorSymbols: $generatorSymbols
            )
        }
        .alert("Import Result", isPresented: Binding(
            get: { importResult != nil },
            set: { if !$0 { importResult = nil } }
        )) {
            Button("OK") { importResult = nil }
        } message: {
            Text(importResult ?? "")
        }
        .alert("Clear All Passwords", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { passwordStore.clearAll() }
        } message: {
            Text("This will permanently delete all saved passwords.")
        }
    }

    // MARK: - Header

    /// 头部 = 强调色锁形徽标 + 标题/条目数 + 右侧图标操作组（生成/导入/导出 |
    /// 清空）。此前是三行裸文字按钮 + 红字"清除全部"，层级混乱（用户实测"粗糙"）。
    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(appAccent.opacity(0.15))
                Image(systemName: "lock.keyhole.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(appAccent)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("Passwords")
                    .font(.system(size: 14, weight: .semibold))
                if !passwordStore.entries.isEmpty {
                    Text(verbatim: "\(passwordStore.entries.count)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            headerAction("plus", help: String(localized: "Add Password")) {
                editingEntry = nil
                showEditor = true
            }
            headerAction(isCheckingHealth ? "hourglass" : "shield.lefthalf.filled",
                         help: String(localized: "Check Health and Breaches")) {
                guard !isCheckingHealth else { return }
                checkHealth()
            }
            headerAction("wand.and.stars", help: String(localized: "Generate")) {
                showGenerator = true
            }
            headerAction("square.and.arrow.down", help: String(localized: "Import Passwords")) {
                doImport()
            }
            headerAction("square.and.arrow.up", help: String(localized: "Export Encrypted Archive")) {
                doExportEncrypted()
            }
            headerAction("doc.plaintext", help: String(localized: "Export Plain CSV (not recommended)")) {
                doExport()
            }
            Divider().frame(height: 16)
            if !passwordStore.entries.isEmpty {
                headerAction("trash", help: String(localized: "Clear All"), tint: .red) {
                    showClearConfirmation = true
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// 头部图标钮：28pt 圆角方块 + hover 底色（同 CapsuleButton 规格），
    /// 支持着色（清空 = 红）。放本文件是因为 CapsuleButton 不带 tint。
    private func headerAction(
        _ systemName: String,
        help: String,
        tint: Color = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .help(help)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search Domains", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Health & breaches

    /// 健康发现过滤掉“已处理/稍后提醒”的条目（v0.8.82）。
    private var visibleHealthReport: PasswordHealth.Report? {
        healthReport.map {
            PasswordHealth.filter($0, muted: passwordStore.mutedHealthIDs())
        }
    }

    private var handledHealthCount: Int {
        guard let healthReport, let visibleHealthReport else { return 0 }
        return max(0, healthReport.findings.count - visibleHealthReport.findings.count)
    }

    private func healthStrip(_ report: PasswordHealth.Report) -> some View {
        HStack(spacing: 6) {
            Image(systemName: report.isClean ? "checkmark.shield" : "exclamationmark.shield")
                .font(.system(size: 11))
                .foregroundStyle(report.isClean ? .green : .orange)
            Text(report.isClean
                 ? String(localized: "No weak, reused or stale passwords.")
                 : String(format: String(localized: "%lld need attention: %lld weak · %lld reused · %lld old"),
                          report.findings.count, report.weakCount,
                          report.duplicateCount, report.oldCount))
                .font(.system(size: 11))
                .lineLimit(2)
            if handledHealthCount > 0 {
                Text(String(format: String(localized: "%lld handled"), handledHealthCount))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if let healthNote {
                Text(healthNote)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// 显式动作（v0.8.80）：读全部密码 → 本地健康判定 → HIBP k-匿名泄露检查。
    /// **只在用户点按钮时发生**；整条密码不出本机（只发 SHA-1 前 5 位）。
    private func checkHealth() {
        isCheckingHealth = true
        healthNote = nil
        passwordStore.loadAllSecrets()
        let report = PasswordHealth.assess(entries: passwordStore.entries)
        healthReport = report
        let items = passwordStore.entries.compactMap { entry -> PasswordBreachService.Item? in
            guard !entry.password.isEmpty else { return nil }
            return .init(id: entry.id, password: entry.password)
        }
        Task {
            let outcome = await PasswordBreachService.check(items)
            breaches = outcome.counts
            isCheckingHealth = false
            healthNote = outcome.failedGroups > 0
                ? String(format: String(localized: "%lld prefix group(s) could not be checked — those passwords are unverified."), outcome.failedGroups)
                : String(localized: "Breach check: only 5-character hash prefixes left this Mac.")
        }
    }

    // MARK: - Data

    /// 展示序 = 最新在前（纯视图排序，不改存储顺序）。
    private var filtered: [PasswordEntry] {
        let base = searchText.isEmpty
            ? passwordStore.entries
            : passwordStore.entries.filter { $0.domain.localizedCaseInsensitiveContains(searchText) }
        return base.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Import / Export

    private func doImport() {
        let panel = NSOpenPanel()
        let archiveType = UTType(filenameExtension: "dpass") ?? .data
        panel.allowedContentTypes = [archiveType, .commaSeparatedText]
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension.lowercased() == "dpass" {
            archivePrompt = .importFile(url)
            return
        }
        guard let csv = try? String(contentsOf: url, encoding: .utf8) else { return }
        let count = passwordStore.importCSV(csv)
        importResult = count > 0
            ? String(format: String(localized: "Imported %lld passwords"), count)
            : String(localized: "No passwords imported")
    }

    private func doExportEncrypted() {
        let panel = NSSavePanel()
        let archiveType = UTType(filenameExtension: "dpass") ?? .data
        panel.allowedContentTypes = [archiveType]
        panel.nameFieldStringValue = "desire-passwords.dpass"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        archivePrompt = .export(url)
    }

    private func doExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "desire-passwords.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try passwordStore.exportCSV().write(to: url, atomically: true, encoding: .utf8)
            importResult = String(format: String(localized: "Exported to %@"), url.lastPathComponent)
        } catch {
            // 失败仍报成功会误导用户以为密码已导出（BUG-5）。
            importResult = String(format: String(localized: "Export failed: %@"), error.localizedDescription)
        }
    }
}


// MARK: - Encrypted archive (v0.8.82)

private enum PasswordArchivePrompt: Identifiable {
    case export(URL)
    case importFile(URL)

    var id: String {
        switch self {
        case .export(let url): "export-\(url.path)"
        case .importFile(let url): "import-\(url.path)"
        }
    }

    var isExport: Bool {
        if case .export = self { return true }
        return false
    }
}

/// 口令输入 → 加密导出/导入。导出必须先读齐 Keychain（显式动作），导入只补新条目。
private struct PasswordArchiveSheet: View {
    let prompt: PasswordArchivePrompt
    @ObservedObject var store: PasswordStore
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var errorText: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.isExport
                 ? String(localized: "Encrypt password export")
                 : String(localized: "Import encrypted passwords"))
                .font(.system(size: 14, weight: .semibold))
            Text(prompt.isExport
                 ? String(localized: "The archive is protected by this password. There is no recovery if you forget it.")
                 : String(localized: "Existing entries with the same site and username are kept; only new entries are added."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(String(localized: "Archive password"), text: $password)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(String(localized: "Archive password"))
            if prompt.isExport {
                SecureField(String(localized: "Confirm password"), text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(String(localized: "Confirm password"))
            }
            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                Button(prompt.isExport ? String(localized: "Export") : String(localized: "Import")) {
                    run()
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || password.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private func run() {
        if prompt.isExport {
            guard password == confirmation else {
                errorText = String(localized: "Passwords do not match.")
                return
            }
            guard case .export(let url) = prompt else { return }
            busy = true
            errorText = nil
            do {
                let data = try store.exportArchive(password: password)
                try data.write(to: url, options: .atomic)
                onDone(String(format: String(localized: "Encrypted export saved to %@"), url.lastPathComponent))
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        } else {
            guard case .importFile(let url) = prompt else { return }
            busy = true
            errorText = nil
            do {
                let data = try Data(contentsOf: url)
                let result = try store.importArchive(data, password: password)
                onDone(String(format: String(localized: "Imported %lld, skipped %lld existing"),
                              result.imported, result.skipped))
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Row

private struct PasswordRow: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let entry: PasswordEntry
    /// 健康与泄露标记（v0.8.80；未检查时为空）。
    let issues: [PasswordHealth.Issue]
    let breachCount: Int?
    let onDelete: () -> Void
    let onEdit: () -> Void
    /// 密码懒加载：列表只取元数据（读 data 会弹钥匙串授权），
    /// 显示/复制这一条时才读，一次一条。
    let loadPassword: () -> String?
    /// 打开该站点（健康/泄露提示后的"去改密"动作，v0.8.81 批 2）。
    var onOpenSite: (() -> Void)? = nil
    /// 健康提示处理（v0.8.82）：nil = 永久"已处理"，30/90 = 稍后提醒。
    var onMuteHealth: ((Int?) -> Void)? = nil
    var isHealthMuted: Bool = false
    @State private var showPassword = false
    @State private var revealedPassword: String?
    /// 复制成功的短暂反馈：对应字段图标换成对勾，1.2s 后还原。
    @State private var copiedField: CopiedField?
    @State private var copyResetTask: Task<Void, Never>?

    private enum CopiedField { case username, password }

    var body: some View {
        HStack(spacing: 10) {
            monogram

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.domain)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.username)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !issues.isEmpty || (breachCount ?? 0) > 0 {
                    HStack(spacing: 4) {
                        ForEach(issues, id: \.rawValue) { issue in
                            Text(issue.label)
                                .font(.system(size: 9))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.14)))
                                .foregroundStyle(.orange)
                        }
                        if let breachCount, breachCount > 0 {
                            Text(String(format: String(localized: "Leaked %lld times"), breachCount))
                                .font(.system(size: 9))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.red.opacity(0.14)))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            if showPassword {
                Text(revealedPassword ?? entry.password)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(appAccent.opacity(0.10)))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .transition(.opacity)
            }

            // 操作组**常驻**（不搞 hover 显隐）：密码行的主操作就是"复制"，
            // 藏起来等于没有；HoverIcon 自带 hover 底色提供反馈，也天然避开了
            // "hover 区域不含按钮导致点不到"那一类坑（Agent 气泡实测过）。
            HStack(spacing: 2) {
                if !issues.isEmpty || (breachCount ?? 0) > 0, let onOpenSite {
                    HoverIcon(
                        systemName: "safari",
                        action: onOpenSite,
                        help: String(localized: "Open site to change password")
                    )
                }
                HoverIcon(
                    systemName: showPassword ? "eye.slash" : "eye",
                    action: { toggleReveal() },
                    help: showPassword ? String(localized: "Hide Password") : String(localized: "Show Password")
                )
                HoverIcon(
                    systemName: copiedField == .username ? "checkmark" : "person.crop.circle",
                    action: { copy(entry.username, field: .username) },
                    help: String(localized: "Copy Username")
                )
                HoverIcon(
                    systemName: copiedField == .password ? "checkmark" : "doc.on.doc",
                    action: {
                        let secret = entry.password.isEmpty
                            ? (loadPassword() ?? revealedPassword ?? "")
                            : entry.password
                        guard !secret.isEmpty else { return }
                        copy(secret, field: .password)
                    },
                    help: String(localized: "Copy Password")
                )
                HoverIcon(
                    systemName: "pencil",
                    action: onEdit,
                    help: String(localized: "Edit")
                )
                HoverIcon(
                    systemName: "trash",
                    action: onDelete,
                    help: String(localized: "Delete")
                )
            }
        }
        .contextMenu {
            if !issues.isEmpty || (breachCount ?? 0) > 0 {
                Button(String(localized: "Mark as handled")) { onMuteHealth?(nil) }
                Button(String(localized: "Snooze 30 days")) { onMuteHealth?(30) }
                Button(String(localized: "Snooze 90 days")) { onMuteHealth?(90) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .animation(.hoverFast, value: showPassword)
    }

    /// 域名首字母徽标（强调色底）：比裸地球图标更有辨识度。
    private var monogram: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(appAccent.opacity(0.14))
            Text(String(entry.domain.prefix(1)).uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(appAccent)
        }
        .frame(width: 28, height: 28)
    }

    /// 显示密码是显式用户动作——此时才读 Keychain（一条）；隐藏不读。
    private func toggleReveal() {
        if !showPassword, revealedPassword == nil, entry.password.isEmpty {
            revealedPassword = loadPassword()
        }
        withAnimation(.hoverFast) { showPassword.toggle() }
    }

    private func copy(_ text: String, field: CopiedField) {
        if field == .password {
            ClipboardHistoryStore.shared.suppressNextCapture()
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedField = field
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            if copiedField == field { copiedField = nil }
        }
    }
}

#Preview {
    PasswordPanel(passwordStore: PasswordStore())
        .frame(width: 420, height: 500)
}
