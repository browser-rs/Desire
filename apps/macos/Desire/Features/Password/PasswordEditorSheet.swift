import SwiftUI

/// 密码条目的新增 / 编辑表单（v0.8.80）。手动录入此前完全缺失——只能在登录页
/// 保存，改站点/账号也只能删了重来。
struct PasswordEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PasswordStore
    /// nil = 新增。
    let entry: PasswordEntry?

    @State private var domain: String
    @State private var username: String
    @State private var password: String
    @State private var showPassword = false
    @State private var errorText: String?

    init(store: PasswordStore, entry: PasswordEntry? = nil) {
        self.store = store
        self.entry = entry
        _domain = State(initialValue: entry?.domain ?? "")
        _username = State(initialValue: entry?.username ?? "")
        _password = State(initialValue: entry?.password ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry == nil ? "Add Password" : "Edit Password")
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                field("Website", text: $domain, prompt: "example.com")
                field("Username", text: $username, prompt: "you@example.com")
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Password")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Group {
                                if showPassword {
                                    TextField("", text: $password)
                                } else {
                                    SecureField("", text: $password)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            Button {
                                showPassword.toggle()
                            } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(showPassword ? "Hide" : "Show")
                            Button("Generate") {
                                password = PasswordStore.generatePassword()
                                showPassword = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(entry == nil ? "Add" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(domain.trimmingCharacters(in: .whitespaces).isEmpty
                              || password.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }

    private func save() {
        let host = PasswordBreach.normalizedDomain(domain)
        guard !host.isEmpty else {
            errorText = String(localized: "Enter a website")
            return
        }
        guard !password.isEmpty else {
            errorText = String(localized: "Enter a password")
            return
        }
        let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if let entry {
            store.update(entry, domain: host, username: account, password: password)
        } else {
            store.save(domain: host, username: account, password: password)
        }
        dismiss()
    }

}
