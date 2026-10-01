import AVKit
import SwiftUI

/// 本地媒体查看器（拖入 mp4/mov/webm/mp3 等时替代 file:// 导航）：
/// AVPlayer 直接播本地文件——不走 WKWebView 的 file:// 媒体管线（其
/// 加载受播放策略/进程状态影响，实测出现过元数据不加载的"假死"，且
/// 报错不可见），错误能明确呈现给用户。UI 对齐 PDFViewerView。
struct MediaViewerView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let fileURL: URL
    let fileName: String
    let onBack: () -> Void

    @State private var player: AVPlayer?
    @State private var loadError: String?
    @State private var statusObserver: NSKeyValueObservation?

    private var isAudioOnly: Bool {
        ["mp3", "m4a", "wav", "aac"].contains(fileURL.pathExtension.lowercased())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    onBack()
                } label: {
                    Label(String(localized: "Back to Page"), systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(appAccent)

                Text(fileName)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Button {
                    NSWorkspace.shared.open(fileURL)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open in QuickTime Player"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }

            if let loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("Couldn't play this file")
                        .font(.system(size: 12, weight: .medium))
                    Text(loadError)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let player {
                if isAudioOnly {
                    VStack(spacing: 14) {
                        Image(systemName: "waveform")
                            .font(.system(size: 40))
                            .foregroundStyle(appAccent.opacity(0.6))
                        // AVPlayerController 提供进度/音量控制。
                        AVPlayerControllerRepresented(player: player)
                            .frame(height: 40)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    AVPlayerControllerRepresented(player: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { start() }
        .onDisappear { teardown() }
    }

    private func start() {
        let item = AVPlayerItem(url: fileURL)
        let player = AVPlayer(playerItem: item)
        self.player = player
        player.play()
        // 加载失败呈现（格式不支持/文件损坏）。
        statusObserver = item.observe(\.status, options: [.new]) { item, _ in
            Task { @MainActor in
                if item.status == .failed {
                    self.loadError = item.error?.localizedDescription ?? "Unknown error"
                }
            }
        }
    }

    private func teardown() {
        statusObserver?.invalidate()
        statusObserver = nil
        player?.pause()
        player = nil
    }
}

/// AVPlayerViewController 包装（自带播放/进度/音量/全屏控制）。
private struct AVPlayerControllerRepresented: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
