import SwiftUI
import VisionKit

/// 未配对引导（已登录但未配对时的全部内容）：
/// 扫码配对 / 扫一扫登录 Mac / 粘贴二维码内容导入。
struct ConnectMacView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var showPairingScanner = false
    @State private var showQRLogin = false
    @State private var manualCode = ""
    @State private var showManualImport = false

    private var cameraAvailable: Bool { DataScannerViewController.isAvailable }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                primaryActions
                manualImport
                if let error = client.pairError {
                    errorBanner(error)
                }
            }
            .desirePagePadding()
            .padding(.top, 28)
            .padding(.bottom, 30)
        }
        .background(DesireUI.pageFill.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPairingScanner) {
            ScannerSheet(
                onRead: { raw in
                    showPairingScanner = false
                    client.importPairing(raw)
                },
                onFailure: { message in
                    showPairingScanner = false
                    client.pairError = "相机无法启动：\(message)"
                })
            .preferredColorScheme(client.preferredColorScheme)
        }
        .sheet(isPresented: $showQRLogin) {
            QRLoginScanSheet()
                .preferredColorScheme(client.preferredColorScheme)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(DesireUI.brand.opacity(0.12))
                    .frame(width: 88, height: 88)
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(DesireUI.brand)
            }
            VStack(spacing: 6) {
                Text("连接你的 Mac")
                    .font(.system(size: 22, weight: .semibold))
                Text("配对后即可远程指挥 Mac 上的 Agent：\n手机派活、看进度、解锁敏感步骤。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            // 已登录到这一步说明只差配对——明确说出来，别让用户以为登录没成功
            if !client.savedUsername.isEmpty {
                Label("已登录 \(client.savedUsername)，只差配对", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
            }
        }
        .padding(.bottom, 4)
    }

    private var primaryActions: some View {
        VStack(spacing: 10) {
            actionButton(
                title: "扫码配对",
                subtitle: cameraAvailable
                    ? "Mac：设置 → 远程 → 生成配对二维码"
                    : "相机不可用 · 点这里改用粘贴导入",
                icon: "camera.viewfinder",
                prominent: true
            ) {
                openScanner { showPairingScanner = true }
            }
            actionButton(
                title: "扫一扫登录 Mac",
                subtitle: cameraAvailable
                    ? "Mac：设置 → Sync → 登录码（免密登录）"
                    : "相机不可用 · 点这里改用粘贴导入",
                icon: "qrcode.viewfinder",
                prominent: false
            ) {
                openScanner { showQRLogin = true }
            }
            if !cameraAvailable {
                Text("相机不可用（模拟器或无相机权限），已在下方展开粘贴导入。")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 相机不可用时不要让按钮变成"点了没反应"的死按钮：直接展开粘贴导入。
    private func openScanner(_ open: () -> Void) {
        guard cameraAvailable else {
            withAnimation(.easeInOut(duration: 0.2)) { showManualImport = true }
            return
        }
        open()
    }

    private func actionButton(
        title: String, subtitle: String, icon: String,
        prominent: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                DesireIconBadge(
                    icon: icon,
                    tint: prominent ? DesireUI.brand : .secondary,
                    size: 36,
                    filled: prominent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(prominent ? Color.white : Color.primary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(prominent ? Color.white.opacity(0.85) : Color.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(DesireUI.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesireUI.cardCorner, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(DesireUI.brand) : AnyShapeStyle(DesireUI.cardFill))
            )
        }
        .buttonStyle(.plain)
    }

    private var manualImport: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showManualImport.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 12, weight: .medium))
                    Text("粘贴二维码内容导入")
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: showManualImport ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showManualImport {
                VStack(spacing: 8) {
                    TextField("粘贴配对/登录二维码内容", text: $manualCode, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.system(size: 12, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: DesireUI.chipCorner, style: .continuous)
                                .fill(Color.secondary.opacity(0.08))
                        )
                    Button {
                        client.importPairing(manualCode)
                    } label: {
                        Text("导入")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: DesireUI.chipCorner, style: .continuous)
                                    .fill(manualCode.isEmpty ? Color.secondary.opacity(0.35) : DesireUI.brand)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(DesireUI.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: DesireUI.cardCorner, style: .continuous)
                .fill(DesireUI.cardFill)
        )
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
            Text(message)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.red)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DesireUI.cardCorner, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
    }
}
