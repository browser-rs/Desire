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

    var body: some View {
        VStack(spacing: 0) {
            header
            saveRow
            Divider().opacity(0.6)
            if store.workspaces.isEmpty {
                emptyState
            } else {
                workspaceList
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 420, minHeight: 320)
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
            }
            .padding(12)
        }
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
