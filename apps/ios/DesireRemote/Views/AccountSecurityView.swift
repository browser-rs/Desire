import SwiftUI
import UIKit

/// 账号安全（v0.8.81 批 6）：恢复码、最近审计、设备吊销。
///
/// **不提供改密**：改密必须同时用新口令重包同步 DEK（`new_kdf_salt` /
/// `new_wrapped_dek`），而 iOS 端没有同步主密钥——在手机上改会让其它设备的
/// 同步数据永久解不开。改密入口留在 Mac。
struct AccountSecurityView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var events: [RemoteAuditEvent] = []
    @State private var devices: [RemoteAuthDevice] = []
    @State private var recoveryCode: String?
    @State private var errorText: String?
    @State private var loading = false
    @State private var generating = false
    @State private var confirmRevoke: RemoteAuthDevice?
    @State private var revokeError: String?

    var body: some View {
        List {
            Section {
                Text("改密请在 Mac 上完成：手机没有同步主密钥，无法用新口令重新包裹跨设备同步密钥。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                DesireSectionHeader(title: "账号安全",
                                    subtitle: "恢复码 / 审计 / 设备吊销")
            }

            Section {
                if let recoveryCode {
                    Text(recoveryCode)
                        .font(.system(size: 14, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = recoveryCode
                    } label: {
                        Label("复制恢复码", systemImage: "doc.on.doc")
                    }
                    Text("只显示这一次；重新生成会让旧码立即作废。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        Task { await generate() }
                    } label: {
                        HStack {
                            Label("生成恢复码", systemImage: "key.horizontal")
                            if generating { Spacer(); ProgressView().controlSize(.mini) }
                        }
                    }
                    .disabled(generating)
                }
            } header: {
                DesireSectionHeader(title: "恢复码",
                                    subtitle: "忘记密码时用它重置；服务端只存哈希")
            }

            Section {
                if loading && events.isEmpty && devices.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let errorText, events.isEmpty && devices.isEmpty {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                ForEach(events.prefix(50)) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(eventLabel(event.event))
                                .font(.caption.weight(.medium))
                            Spacer()
                            Text(String(event.createdAt.prefix(16)).replacingOccurrences(of: "T", with: " "))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        if !event.detail.isEmpty {
                            Text(event.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if !event.ip.isEmpty {
                            Text(verbatim: event.ip)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                DesireSectionHeader(title: "最近审计",
                                    subtitle: "登录 / 改密 / 吊销 / 恢复（最多 50 条）")
            }

            Section {
                if let revokeError {
                    Text(revokeError).font(.caption).foregroundStyle(.red)
                }
                ForEach(devices) { device in
                    HStack(spacing: 8) {
                        Image(systemName: device.platform.lowercased().contains("ios")
                              ? "iphone" : "desktopcomputer")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.subheadline)
                            Text("\(device.platform) · \(String(device.lastSeenAt.prefix(16)).replacingOccurrences(of: "T", with: " "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if device.revoked {
                            Text("已吊销")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.red)
                        } else {
                            Button("吊销", role: .destructive) {
                                confirmRevoke = device
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
            } header: {
                DesireSectionHeader(title: "设备",
                                    subtitle: "吊销后该设备的刷新令牌全部失效，重新登录即恢复")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("账号安全")
        .refreshable { await reload() }
        .task { await reload() }
        .confirmationDialog("吊销这台设备？", isPresented: Binding(
            get: { confirmRevoke != nil },
            set: { if !$0 { confirmRevoke = nil } }
        ), titleVisibility: .visible) {
            if let device = confirmRevoke {
                Button("吊销 \(device.name)", role: .destructive) {
                    Task { await revoke(device) }
                }
                Button("取消", role: .cancel) { confirmRevoke = nil }
            }
        } message: {
            Text("该设备的 access/refresh token 会立即失效；重新登录后恢复。")
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            async let audit = client.fetchAuthAudit()
            async let list = client.fetchAuthDevices()
            events = try await audit
            devices = try await list
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func generate() async {
        generating = true
        defer { generating = false }
        do {
            recoveryCode = try await client.generateRecoveryCode()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func revoke(_ device: RemoteAuthDevice) async {
        revokeError = nil
        do {
            try await client.revokeAuthDevice(device.deviceID)
            confirmRevoke = nil
            await reload()
        } catch {
            revokeError = error.localizedDescription
            confirmRevoke = nil
        }
    }

    private func eventLabel(_ raw: String) -> String {
        switch raw {
        case "register": "注册"
        case "login": "登录"
        case "logout": "退出登录"
        case "password_changed": "修改密码"
        case "device_revoked": "设备吊销"
        case "devices_revoked": "全部设备吊销"
        case "recover": "恢复码重置"
        case "recovered": "已用恢复码重置"
        default: raw
        }
    }
}
