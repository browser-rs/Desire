import SwiftUI

struct PasswordPanel: View {
    @ObservedObject var passwordStore: PasswordStore
    @State private var searchText = ""
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "lock.keyhole.fill")
                    .foregroundStyle(.secondary)
                Text("密码管理")
                    .font(.headline)
                Spacer()
                if !filtered.isEmpty {
                    Button("清除全部") { showClearConfirmation = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .padding()

            if filtered.isEmpty {
                Spacer()
                EmptyState(message: "没有保存的密码")
                Spacer()
            } else {
                List {
                    ForEach(filtered) { entry in
                        PasswordRow(entry: entry, onDelete: { passwordStore.delete(entry) })
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 320, height: 400)
        .searchable(text: $searchText, prompt: "搜索域名")
        .alert("清除所有密码", isPresented: $showClearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { passwordStore.clearAll() }
        } message: {
            Text("此操作将删除所有保存的密码，不可撤销。")
        }
    }

    private var filtered: [PasswordEntry] {
        if searchText.isEmpty { return passwordStore.entries }
        return passwordStore.entries.filter { $0.domain.localizedCaseInsensitiveContains(searchText) }
    }
}

private struct PasswordRow: View {
    let entry: PasswordEntry
    let onDelete: () -> Void
    @State private var showPassword = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.domain)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(entry.username)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if showPassword {
                Text(entry.password)
                    .font(.caption)
                    .monospaced()
                    .lineLimit(1)
                    .frame(maxWidth: 80)
            }

            Button {
                showPassword.toggle()
            } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(showPassword ? "隐藏密码" : "显示密码")

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("删除")
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    PasswordPanel(passwordStore: PasswordStore())
        .frame(width: 420, height: 400)
}
