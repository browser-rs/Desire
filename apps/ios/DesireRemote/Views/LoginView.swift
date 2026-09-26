import SwiftUI

/// 登录页（未登录相位）。服务器地址不在此露出（设置页可选覆盖）。
struct LoginView: View {
    @EnvironmentObject var client: RemoteClient

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(RootView.brand)
                            Text("欲")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 46, height: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Desire Remote").font(.headline)
                            Text("远程对话 Mac 上的 Agent").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Section("Desire 账号") {
                    TextField("用户名", text: $client.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $client.password)
                }
                if let error = client.loginError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
                Section {
                    Button {
                        client.login()
                    } label: {
                        HStack {
                            Spacer()
                            if client.isWorking {
                                ProgressView()
                            } else {
                                Text("登录").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(client.isWorking || client.username.isEmpty || client.password.isEmpty)
                }
                Section {
                    Text("工作全部在 Mac 本地执行：手机只负责派活、看进度、解锁敏感步骤。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Desire Remote")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
