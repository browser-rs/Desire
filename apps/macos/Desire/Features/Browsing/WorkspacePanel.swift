import SwiftUI
import WebKit

/// 工作区面板（0.7.13）：命名标签组的保存/恢复/删除。
/// 保存 = 当前窗口全部标签序列化为命名快照（WorkspaceStore）；
/// 恢复 = 当前窗口装载该快照的标签集（apply(session:) 既有路径）。
struct WorkspacePanel: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject private var store = WorkspaceStore.shared
    let tabManager: TabManager
    let settings: Settings
    let contentBlocker: ContentBlockerStore
    let videoAdBlocker: VideoAdBlocker
    let profileDataStore: WKWebsiteDataStore?
    let onClose: () -> Void

    @State private var newName = ""
    @State private var restoreTarget: WorkspaceStore.Workspace?
    /// 已归档会话（v27）：窗口关闭时移进 session-archives/ 的会话——
    /// 「关掉的那扇窗还能找回吗」的答案就在这。
    @State private var archives: [SessionArchive.Entry] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            saveRow
            Divider().opacity(0.6)
            if store.workspaces.isEmpty && archives.isEmpty {
                emptyState
            } else {
                workspaceList
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 420, minHeight: 320)
        .onAppear { reloadArchives() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Workspaces")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    private var saveRow: some View {
        HStack(spacing: 8) {
            SettingsTextField(placeholder: String(localized: "Workspace name"), text: $newName)
                .onSubmit { saveCurrent() }
            Button {
                saveCurrent()
            } label: {
                Text(String(localized: "Save Current"))
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || tabManager.tabs.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var workspaceList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(store.workspaces) { ws in
                    workspaceRow(ws)
                }
                archivedSection
            }
            .padding(12)
        }
    }

    // MARK: - 已归档会话（v27）

    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "archivebox")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Archived Sessions")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Closed windows (latest 5 kept)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.top, 10)

            if archives.isEmpty {
                Text("No archived sessions yet — closed windows land here and can be restored any time.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(archives, id: \.fileName) { entry in
                    archivedRow(entry)
                }
            }
        }
    }

    private func archivedRow(_ entry: SessionArchive.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.savedAt, style: .relative)
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 4) {
                    Text("\(entry.tabCount) tabs")
                    if let top = entry.topURLs.first {
                        Text("·")
                        Text(top)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button {
                restoreArchived(entry)
            } label: {
                Text(String(localized: "Restore"))
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                _ = TabSessionCoordinator.shared.removeArchivedSession(named: entry.fileName)
                reloadArchives()
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Delete"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        )
    }

    private func reloadArchives() {
        archives = SessionArchive.list(in: TabSessionCoordinator.archiveDirectory)
    }

    /// 恢复归档会话到当前窗口（替换标签；与「恢复工作区」同语义）——归档
    /// 文件保留（非破坏；容量上限会自然淘汰最旧的）。
    private func restoreArchived(_ entry: SessionArchive.Entry) {
        _ = TabSessionCoordinator.shared.restoreArchivedSession(
            named: entry.fileName, into: tabManager,
            settings: settings, contentBlocker: contentBlocker,
            videoAdBlocker: videoAdBlocker)
        onClose()
    }

    private func workspaceRow(_ ws: WorkspaceStore.Workspace) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(appAccent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(ws.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(ws.session.tabs.count) tabs")
                    Text("·")
                    Text(ws.savedAt, style: .relative)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button {
                restore(ws)
            } label: {
                Text(String(localized: "Restore"))
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                store.remove(ws.id)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Delete"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("No workspaces saved")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Save the current window's tabs as a named set, then restore it any time.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func saveCurrent() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !tabManager.tabs.isEmpty else { return }
        _ = store.save(name: trimmed, tabManager: tabManager)
        newName = ""
    }

    /// 恢复 = 当前窗口装载快照（apply 既有路径：选中标签急切、其余挂起）。
    private func restore(_ ws: WorkspaceStore.Workspace) {
        // 工作区保存的 profileID 优先（与 multi-window 恢复语义一致）——
        // restoreSession(forKey:) 同款行为。
        if let pid = ws.session.profileID {
            tabManager.profileID = pid
            tabManager.profileDataStore = ProfileStore.shared.dataStore(for: pid)
        }
        tabManager.apply(session: ws.session,
                         javaScriptEnabled: settings.isJavaScriptEnabled,
                         contentBlocker: contentBlocker,
                         videoAdBlocker: videoAdBlocker)
        onClose()
    }
}
