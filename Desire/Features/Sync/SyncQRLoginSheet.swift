import AppKit
import SwiftUI

/// 扫码登录（设置 → Sync，未登录时）：桌面出票渲染二维码，
/// 已登录的 iPhone DesireRemote 扫码并在手机上确认，本机轮询领 token。
/// 流程照 Trove：create → 手机 scan（已扫码待确认）→ 手机 confirm →
/// 桌面轮询 status=2 一次性领走 token 对。
struct SyncQRLoginSheet: View {
    @ObservedObject var store: SyncStore
    @Environment(\.dismiss) private var dismiss

    @State private var qrImage: NSImage?
    @State private var statusText = "等待扫描…"
    @State private var expired = false
    @State private var pollTask: Task<Void, Never>?
    @State private var ticket = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("用 iPhone 扫码登录")
                .font(.headline)
            Group {
                if let qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 180, height: 180)
                        .cornerRadius(6)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: 180, height: 180)
                        .overlay { ProgressView() }
                }
            }
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(expired ? Color.orange : .secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if expired {
                    Button("重新生成") { start() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 320)
        .onAppear { start() }
        .onDisappear { pollTask?.cancel() }
    }

    private func start() {
        expired = false
        statusText = "生成二维码…"
        qrImage = nil
        Task { @MainActor in
            do {
                let session = try await store.qrLoginStart()
                ticket = session.ticket
                qrImage = RemoteControlStore.makeQR(from: session.qrPayload)
                statusText = "等待扫描…"
                pollLoop()
            } catch {
                statusText = error.localizedDescription
                expired = true
            }
        }
    }

    private func pollLoop() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                do {
                    let (status, pair, username) = try await store.qrLoginPoll(ticket: ticket)
                    switch status {
                    case 1:
                        statusText = "已扫码——请在 iPhone 上确认"
                    case 2:
                        if let pair {
                            statusText = "已登录 ✓"
                            pollTask?.cancel()
                            await store.signInWithQR(pair: pair, username: username ?? "")
                            dismiss()
                            return
                        }
                    case 3:
                        expired = true
                        statusText = "二维码已过期"
                        return
                    default:
                        break
                    }
                } catch {
                    // 单次轮询失败不打断（网络抖动），下一轮再试
                }
            }
        }
    }
}
