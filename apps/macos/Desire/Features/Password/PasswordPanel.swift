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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
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
                            PasswordRow(entry: entry, onDelete: { passwordStore.delete(entry) })
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

            headerAction("wand.and.stars", help: String(localized: "Generate")) {
                showGenerator = true
            }
            headerAction("square.and.arrow.down", help: String(localized: "Import CSV")) {
                doImport()
            }
            headerAction("square.and.arrow.up", help: String(localized: "Export CSV")) {
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
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url,
              let csv = try? String(contentsOf: url, encoding: .utf8) else { return }
        let count = passwordStore.importCSV(csv)
        importResult = count > 0
            ? String(format: String(localized: "Imported %lld passwords"), count)
            : String(localized: "No passwords imported")
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

// MARK: - Row

private struct PasswordRow: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let entry: PasswordEntry
    let onDelete: () -> Void
    @State private var showPassword = false
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
            }

            Spacer(minLength: 8)

            if showPassword {
                Text(entry.password)
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
                HoverIcon(
                    systemName: showPassword ? "eye.slash" : "eye",
                    action: { withAnimation(.hoverFast) { showPassword.toggle() } },
                    help: showPassword ? String(localized: "Hide Password") : String(localized: "Show Password")
                )
                HoverIcon(
                    systemName: copiedField == .username ? "checkmark" : "person.crop.circle",
                    action: { copy(entry.username, field: .username) },
                    help: String(localized: "Copy Username")
                )
                HoverIcon(
                    systemName: copiedField == .password ? "checkmark" : "doc.on.doc",
                    action: { copy(entry.password, field: .password) },
                    help: String(localized: "Copy Password")
                )
                HoverIcon(
                    systemName: "trash",
                    action: onDelete,
                    help: String(localized: "Delete")
                )
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

    private func copy(_ text: String, field: CopiedField) {
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
