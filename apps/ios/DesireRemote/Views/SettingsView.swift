import SwiftUI

/// 设置（Tab「设置」）：外观 / 服务器 / 账号 / 配对 / 关于。
/// 服务器留空 = 使用内置默认地址（内置地址不在界面露出）。
struct SettingsView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var serverURL = ""
    @State private var saved = false
    @State private var confirmUnpair = false
    @State private var confirmLogout = false

    var body: some View {
        List {
            Section {
                Picker("主题", selection: $client.appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            } header: {
                DesireSectionHeader(title: "外观")
            }

            Section {
                HStack(spacing: 12) {
                    DesireIconBadge(icon: "bolt.horizontal.circle", tint: .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(client.desktopName ?? "未连接 Mac")
                            .font(.system(size: 15, weight: .medium))
                        Text(client.connectionState)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            } header: {
                DesireSectionHeader(title: "连接")
            }

            Section {
                TextField("留空 = 使用内置默认地址", text: $serverURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(size: 14))
                Button {
                    client.saveServerURL(serverURL)
                    saved = true
                } label: {
                    HStack {
                        Text("保存服务器地址")
                        Spacer()
                        if saved {
                            Label("已保存", systemImage: "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 12))
                                .foregroundStyle(.green)
                        }
                    }
                }
                .disabled(serverURL == client.customServer)
            } header: {
                DesireSectionHeader(
                    title: "服务器（可选覆盖）",
                    subtitle: "修改后需退出登录再重新登录才生效")
            }

            Section {
                DesireValueRow(title: "用户名", value: client.savedUsername.isEmpty ? "—" : client.savedUsername)
                Button("退出登录", role: .destructive) {
                    confirmLogout = true
                }
            } header: {
                DesireSectionHeader(title: "账号")
            }

            Section {
                if client.hasSavedPairing {
                    Button("解除与 Mac 的配对", role: .destructive) {
                        confirmUnpair = true
                    }
                } else {
                    Text("尚未与任何 Mac 配对")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            } header: {
                DesireSectionHeader(
                    title: "配对",
                    subtitle: "解除后需在 Mac 上重新扫码；Mac 侧授权会一并吊销")
            }

            Section {
                DesireValueRow(title: "版本", value: Self.version)
                DesireValueRow(title: "状态", value: client.connectionState)
            } header: {
                DesireSectionHeader(title: "关于")
            } footer: {
                Text("工作全部在 Mac 本地执行：手机只负责派活、看进度、解锁敏感步骤。")
                    .font(.system(size: 12))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { serverURL = client.customServer }
        .onChange(of: saved) { _, isSaved in
            guard isSaved else { return }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                saved = false
            }
        }
        .alert("解除配对？", isPresented: $confirmUnpair) {
            Button("解除配对", role: .destructive) { client.unpair() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将吊销 Mac 上对本机的授权，并清除本地配对密钥。需要重新扫码才能恢复。")
        }
        .alert("退出登录？", isPresented: $confirmLogout) {
            Button("退出登录", role: .destructive) { client.logout() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后需要重新输入账号密码。配对关系会保留。")
        }
    }

    private static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
