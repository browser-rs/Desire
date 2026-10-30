import AVKit
import SwiftUI

/// 媒体剪辑工具的共享视图（v0.8.27 媒体批）：播放器预览 + 任务列表。
/// 视频剪辑 / 音频剪辑两个工具共用。

/// 本地媒体预览（AVPlayerView）：把 player 对象递回给宿主（入/出点取
/// 播放头用）。player 的回写跳一帧——makeNSView 处于视图更新事务内，
/// 同步写 @State 会报 "Publishing changes from within view updates"。
struct MediaPlayerPreview: NSViewRepresentable {
    let url: URL
    @Binding var player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: url)
        DispatchQueue.main.async {
            if view.player != nil { player = view.player }
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, with coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

/// 剪辑任务列表（MediaEditStore.shared.jobs 的展示）：进度 / 产物定位 /
/// 取消。任务在后台跑，切走工具页再回来仍能看到状态。
struct MediaJobsList: View {
    @Environment(\.appAccent) private var appAccent: Color
    let jobs: [MediaEditStore.Job]

    var body: some View {
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Jobs")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(jobs) { job in
                    row(job)
                }
            }
        }
    }

    private func row(_ job: MediaEditStore.Job) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: job.kind.symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.label)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch job.state {
                case .running:
                    HStack(spacing: 6) {
                        ProgressView(value: job.progress)
                            .progressViewStyle(.linear)
                            .tint(appAccent)
                        Text("\(Int((job.progress * 100).rounded()))%")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 30, alignment: .trailing)
                    }
                case .done:
                    if let url = job.outputURL {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Label(url.lastPathComponent, systemImage: "folder")
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(appAccent)
                        .help(String(localized: "Reveal in Finder"))
                    }
                case .failed:
                    if let message = job.message {
                        Text(message)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                case .cancelled:
                    Text("Cancelled")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            stateBadge(job)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func stateBadge(_ job: MediaEditStore.Job) -> some View {
        switch job.state {
        case .running:
            Button {
                MediaEditStore.shared.cancel(job.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "Cancel"))
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}

/// 时间输入行（入点/出点；"m:ss.d" / 纯秒都接受，校验在执行前统一做）。
struct MediaTimeField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            TextField("0:00", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(width: 78)
        }
    }
}
