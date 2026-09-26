import SwiftUI
import VisionKit

/// 扫 Mac 的**登录码**：用当前账号为该 Mac 签发登录态。
///
/// 若 Mac 侧「远程控制」开着，登录码里会顺带带配对信息（`c`/`k`）——那时本机
/// 在登录成功后会**顺带完成远程配对**，用户不必再扫一次配对码。
struct QRLoginScanSheet: View {
    @EnvironmentObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss

    /// 一次待确认的登录：登录码字段 + 可能夹带的配对信息。
    private struct PendingLogin {
        var ticket: String
        var server: String
        var username: String
        var pairing: RemoteClient.LoginPairingInfo?
    }

    @State private var pendingConfirm: PendingLogin?
    @State private var working = false
    @State private var resultMessage: String?
    @State private var showResult = false

    var body: some View {
        NavigationStack {
            ScannerSheet(
                onRead: { raw in handle(raw) },
                onFailure: { message in
                    // 权限被拒时 startScanning 会抛错，必须让用户看到原因
                    // （此前静默吞掉，现象就是"扫码没反应"）。
                    resultMessage = "相机无法启动：\(message)\n请在 系统设置 → Desire Remote 中允许相机权限。"
                    showResult = true
                })
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) {
                // 取景时给一句"该扫哪里"——此前只有一个纯相机画面，用户不知道
                // 要去 Mac 的哪个位置找码。
                Text("对准 Mac 上「设置 → Sync → 登录码」")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .padding(.bottom, 34)
            }
            .navigationTitle("扫码登录 Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("在此 Mac 上登录？", isPresented: Binding(
                get: { pendingConfirm != nil },
                set: { if !$0 { pendingConfirm = nil } })) {
                Button("确认登录") { confirmLogin() }
                Button("取消", role: .cancel) { pendingConfirm = nil }
            } message: {
                Text(confirmMessage)
            }
            .alert("扫码登录", isPresented: $showResult) {
                Button("好", role: .cancel) { dismiss() }
            } message: {
                Text(resultMessage ?? "")
            }
        }
        .preferredColorScheme(client.preferredColorScheme)
    }

    private var confirmMessage: String {
        guard let login = pendingConfirm else { return "" }
        var text = "服务器：\(login.server)\n将用当前账号（\(login.username)）登录。"
        if login.pairing != nil {
            text += "\n同时会与这台 Mac 完成远程配对。"
        }
        return text
    }

    /// 登录 +（有配对信息时）顺带配对。两件事的成败**分开表述**：
    /// 配对失败不该被说成"登录失败"，用户已经登录成功了。
    private func confirmLogin() {
        guard let login = pendingConfirm else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                let name = try await client.qrLoginScanAndConfirm(ticket: login.ticket)
                var note = "已在 \(name) 上登录 ✓"
                if let pairing = login.pairing {
                    do {
                        try await client.claimPairing(pairing)
                        note += "\n已完成远程配对，现在可以远程指挥它了。"
                    } catch {
                        note += "\n远程配对未完成：\(error.localizedDescription)"
                            + "\n可在 Mac 上重新生成配对码再扫一次。"
                    }
                } else {
                    note += "\n该 Mac 未开启「远程控制」。要用手机指挥它，"
                        + "请在 Mac 上开启后扫配对码。"
                }
                pendingConfirm = nil
                resultMessage = note
                showResult = true
            } catch {
                pendingConfirm = nil
                resultMessage = "失败：\(error.localizedDescription)"
                showResult = true
            }
        }
    }

    private func handle(_ raw: String) {
        guard !working, pendingConfirm == nil, resultMessage == nil else { return }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ticket = obj["ticket"] as? String else {
            resultMessage = "二维码不是登录码"
            showResult = true
            return
        }
        let server = obj["s"] as? String ?? client.normalizedServerURL
        let normalized = { (value: String) in
            value.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard normalized(server) == normalized(client.normalizedServerURL) else {
            resultMessage = "该二维码属于其他服务器（\(server)），与当前登录服务器不一致"
            showResult = true
            return
        }
        // Mac 远程开着时登录码里会夹带配对信息（c/k）——扫一次两件事都办。
        let pairing: RemoteClient.LoginPairingInfo? = {
            guard let code = obj["c"] as? String, let key = obj["k"] as? String,
                  !code.isEmpty, !key.isEmpty else { return nil }
            return RemoteClient.LoginPairingInfo(code: code, sessionKeyB64: key)
        }()
        pendingConfirm = PendingLogin(
            ticket: ticket, server: server,
            username: client.savedUsername, pairing: pairing)
    }
}
