import SwiftUI

/// 设置页（抽屉 ⚙ push）：外观 / 服务器可选覆盖 / 账号 / 关于。
/// 服务器覆盖：留空 = 内置默认地址（内置地址不在界面露出）。
struct SettingsView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var serverURL = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $client.appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section {
                TextField("留空 = 使用内置默认地址", text: $serverURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Text("留空使用内置默认地址。修改后需退出登录并重新登录才生效。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("保存服务器地址") {
                    client.saveServerURL(serverURL)
                    saved = true
                }
            } header: {
                Text("服务器（可选覆盖）")
            }
            Section("账号") {
                LabeledContent("用户名", value: client.savedUsername)
                Button("退出登录", role: .destructive) {
                    client.logout()
                }
            }
            Section {
                Button("解除与 Mac 的配对", role: .destructive) {
                    client.unpair()
                }
            } footer: {
                Text("解除后需在 Mac 上重新扫码配对；Mac 端设备列表中的授权也会一并吊销。")
            }
            Section("关于") {
                LabeledContent("版本", value: "0.1.0")
                LabeledContent("状态", value: client.connectionState)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            serverURL = client.customServer
        }
        .onChange(of: saved) { _, isSaved in
            if isSaved {
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    saved = false
                }
            }
        }
    }
}
