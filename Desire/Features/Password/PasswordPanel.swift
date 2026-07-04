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
                Text("Passwords")
                    .font(.headline)
                Spacer()
                if !filtered.isEmpty {
                    Button("Clear All") { showClearConfirmation = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .padding()

            if filtered.isEmpty {
                Spacer()
                EmptyState(message: String(localized: "No Saved Passwords"))
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
        .frame(width: 420, height: 400)
        .searchable(text: $searchText, prompt: "Search Domains")
        .alert("Clear All Passwords", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { passwordStore.clearAll() }
        } message: {
            Text("This will permanently delete all saved passwords.")
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
            .help(showPassword ? "Hide Password" : "Show Password")

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete")
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    PasswordPanel(passwordStore: PasswordStore())
        .frame(width: 420, height: 400)
}
