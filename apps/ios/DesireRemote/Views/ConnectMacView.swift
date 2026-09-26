import SwiftUI
import VisionKit

/// 未配对引导（已登录、未配对时主页面内容）：
/// 扫码配对 / 扫一扫登录 Mac / 粘贴导入。≡ 抽屉与设置入口恒可达。
struct ConnectMacView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var showPairingScanner = false
    @State private var showQRLogin = false
    @State private var manualCode = ""
    @State private var pairError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(RootView.brand)
                    .padding(.top, 26)
                Text("连接你的 Mac")
                    .font(.title3.bold())
                Text("在 Mac「设置 → 远程」生成配对二维码；\n或扫 Mac「设置 → Sync」的登录码免密登录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    showPairingScanner = true
                } label: {
                    Label("扫码配对", systemImage: "camera.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!DataScannerViewController.isAvailable)
                .padding(.horizontal, 26)

                Button {
                    showQRLogin = true
                } label: {
                    Label("扫一扫登录 Mac", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!DataScannerViewController.isAvailable)
                .padding(.horizontal, 26)

                if !DataScannerViewController.isAvailable {
                    Text("相机不可用（模拟器/无权限）——可粘贴二维码内容").font(.caption2).foregroundStyle(.secondary)
                }

                VStack(spacing: 8) {
                    TextField("粘贴配对/登录二维码内容", text: $manualCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("导入") { client.importPairing(manualCode) }
                        .disabled(manualCode.isEmpty)
                }
                .padding(.horizontal, 26)

                if let pairError {
                    Label(pairError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            .padding(.bottom, 30)
        }
        .sheet(isPresented: $showPairingScanner) {
            ScannerSheet { raw in
                showPairingScanner = false
                client.importPairing(raw)
            }
            .preferredColorScheme(client.preferredColorScheme)
        }
        .sheet(isPresented: $showQRLogin) {
            QRLoginScanSheet()
                .preferredColorScheme(client.preferredColorScheme)
        }
    }
}
