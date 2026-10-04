import AppKit
import SwiftUI

/// 设置 → 远程：手机经中继远程对话本机 Agent。工作全部本地执行，
/// 手机只发指令、看进度。开关 → 二维码配对 → 已配对设备管理。
struct RemoteSettingsSection: View {
    @ObservedObject var store: RemoteControlStore
    @ObservedObject var syncStore: SyncStore

    var body: some View {
        SettingsContainer {
            statusSection
            pairingSection
            devicesSection
        }
        .onAppear {
            store.refreshDevices()
        }
    }

    private var signedIn: Bool {
        if case .signedIn = syncStore.authState { return true }
        return false
    }

    // MARK: - 状态与开关

    private var statusSection: some View {
        SettingsSection(
            title: "Remote",
            subtitle: "Control the Agent on this Mac from your iPhone. Tasks run locally here — the phone sends instructions, watches progress, and unlocks sensitive steps.",
            icon: "iphone.radiowaves.left.and.right"
        ) {
            VStack(spacing: 0) {
                SettingsRow("Remote Control", subtitle: enabledSubtitle) {
                    Toggle("", isOn: Binding(
                        get: { store.isEnabled },
                        set: { store.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!signedIn)
                }
                if store.connection != .off {
                    SettingsRowDivider()
                    SettingsRow("Status", subtitle: statusText) {
                        statusPill
                    }
                }
            }
        }
    }

    private var enabledSubtitle: String? {
        guard signedIn else {
            return localizedSettingText("Sign in to Sync first — Remote uses the same account.")
        }
        return nil
    }

    private var statusText: String? {
        switch store.connection {
        case .error(let message): return message
        default: return nil
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch store.connection {
        case .online:
            StatusPill(text: localizedSettingText("Connected"), kind: .success)
        case .connecting:
            StatusPill(text: localizedSettingText("Connecting…"), kind: .info)
        case .error:
            StatusPill(text: localizedSettingText("Error"), kind: .error)
        case .off:
            StatusPill(text: localizedSettingText("Off"), kind: .neutral)
        }
    }

    // MARK: - 配对

    @ViewBuilder
    private var pairingSection: some View {
        if store.isEnabled && signedIn {
            SettingsSection(
                title: "Pair a Phone",
                subtitle: "Scan with the Desire Remote app. The code works once and expires in 10 minutes.",
                icon: "qrcode"
            ) {
                VStack(spacing: 0) {
                    if let pairing = store.activePairing, pairing.qrImage != nil {
                        qrRow(pairing)
                    } else {
                        SettingsRow("Get Started", subtitle: localizedSettingText("No pairing code yet.")) {
                            SettingsCapsuleButton("Pair a Phone", style: .prominent) {
                                store.startPairing()
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func qrRow(_ pairing: RemoteControlStore.ActivePairing) -> some View {
        SettingsRow("Scan Me", subtitle: codeSubtitle(pairing)) {
            VStack(spacing: 6) {
                if let image = pairing.qrImage {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 132, height: 132)
                        .cornerRadius(6)
                }
                SettingsCapsuleButton("Refresh", style: .secondary) {
                    store.startPairing()
                }
            }
        }
    }

    private func codeSubtitle(_ pairing: RemoteControlStore.ActivePairing) -> String? {
        let seconds = max(0, Int(pairing.expiresAt.timeIntervalSinceNow))
        return localizedSettingText("Code") + ": " + pairing.code
            + "  ·  " + String(format: localizedSettingText("Expires in %d s"), seconds)
    }

    // MARK: - 已配对设备

    private var devicesSection: some View {
        SettingsSection(
            title: "Paired Devices",
            subtitle: "Paired phones may send prompts to this Mac's Agent. Revoke any time.",
            icon: "checkmark.seal"
        ) {
            VStack(spacing: 0) {
                if store.pairedDevices.isEmpty {
                    SettingsRow("Paired Devices", subtitle: localizedSettingText("No paired devices yet.")) {
                        EmptyView()
                    }
                } else {
                    ForEach(Array(store.pairedDevices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { SettingsRowDivider() }
                        SettingsActionRow(
                            device.controllerName,
                            subtitle: deviceSubtitle(device),
                            buttonTitle: "Revoke",
                            isDestructive: true
                        ) {
                            store.revoke(deviceID: device.desktopDeviceId, controllerName: device.controllerName)
                        }
                    }
                }
            }
        }
    }

    private func deviceSubtitle(_ device: SyncAPIClient.RemotePairedDevice) -> String {
        var parts = [device.desktopName]
        parts.append(device.online
            ? localizedSettingText("Connected")
            : localizedSettingText("Offline"))
        return parts.joined(separator: " · ")
    }
}
