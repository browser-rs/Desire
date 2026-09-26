import SwiftUI
import VisionKit

struct QRLoginScanSheet: View {
    @EnvironmentObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @State private var pendingConfirm: (ticket: String, server: String, username: String)?
    @State private var working = false
    @State private var resultMessage: String?
    @State private var showResult = false

    var body: some View {
        NavigationStack {
            ScannerSheet { raw in
                handle(raw)
            }
            .ignoresSafeArea(edges: .bottom)
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
                Button("确认登录") {
                    guard let login = pendingConfirm else { return }
                    working = true
                    Task { @MainActor in
                        defer { working = false }
                        do {
                            let name = try await client.qrLoginScanAndConfirm(ticket: login.ticket)
                            pendingConfirm = nil
                            resultMessage = "已在 \(name) 上登录 ✓"
                            showResult = true
                        } catch {
                            pendingConfirm = nil
                            resultMessage = "失败：\(error.localizedDescription)"
                            showResult = true
                        }
                    }
                }
                Button("取消", role: .cancel) { pendingConfirm = nil }
            } message: {
                Text(pendingConfirm.map { "服务器：\($0.server)\n将用当前账号（\(client.savedUsername)）登录。" } ?? "")
            }
            .alert("扫码登录", isPresented: $showResult) {
                Button("好", role: .cancel) { dismiss() }
            } message: {
                Text(resultMessage ?? "")
            }
        }
        .preferredColorScheme(client.preferredColorScheme)
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
        guard server.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            == client.normalizedServerURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            resultMessage = "该二维码属于其他服务器（\(server)），与当前登录服务器不一致"
            showResult = true
            return
        }
        pendingConfirm = (ticket, server, client.savedUsername)
    }
}

// MARK: - 设置

