import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// 媒体转码 / 视频转 GIF（v0.8.38 A6）：两个工具箱入口共用一个表单。
/// 任务走 MediaEditStore 的长任务通道（立即返回、进度、取消、产物可定位）。
struct MediaConvertToolView: View {
    enum Mode {
        case convert
        case gif
    }

    @ObservedObject private var store = MediaEditStore.shared
    let mode: Mode

    @State private var source: URL?
    @State private var duration: Double?
    @State private var format: MediaConvertFormat = .mp4
    @State private var widthText = "480"
    @State private var fpsText = "12"
    @State private var startText = "0:00"
    @State private var endText = ""
    @State private var player: AVPlayer?
    @State private var error: String?

    private var ffmpegMissing: Bool { !FFmpegExporter.isAvailable }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourceRow
            if let source, !isAudioOnlySource(source) {
                MediaPlayerPreview(url: source, player: $player)
                    .frame(height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .id(source)
            }
            if mode == .convert {
                convertOptions
            } else {
                gifOptions
            }
            runRow
            if let error { ToolErrorText(text: error) }
            MediaJobsList(jobs: store.jobs)
        }
        .onAppear(perform: loadDuration)
        .onChange(of: source) { _, _ in loadDuration() }
    }

    private var sourceRow: some View {
        HStack(spacing: 8) {
            Button(String(localized: "Choose Media…")) { chooseSource() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if let source {
                Text(sourceInfo(source))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var convertOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(String(localized: "Output Format"), selection: $format) {
                ForEach(MediaConvertFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 320, alignment: .leading)
            if format.isAudioOnly {
                Text(String(localized: "Audio-only output drops the video track."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var gifOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                LabeledField(title: String(localized: "Width"), text: $widthText,
                             width: 70)
                LabeledField(title: String(localized: "Frame rate"), text: $fpsText,
                             width: 54)
            }
            HStack(spacing: 10) {
                LabeledField(title: String(localized: "Start time"), text: $startText,
                             width: 80)
                LabeledField(title: String(localized: "End time"), text: $endText,
                             width: 80)
            }
            Text(String(localized: "Leave time empty to convert the whole clip."))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    private var runRow: some View {
        HStack(spacing: 10) {
            Button(runTitle) { run() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(source == nil || ffmpegMissing)
            if ffmpegMissing {
                Text(String(localized: "ffmpeg isn't installed (brew install ffmpeg)."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var runTitle: String {
        mode == .convert
            ? String(localized: "Convert")
            : String(localized: "Create GIF")
    }

    private func sourceInfo(_ url: URL) -> String {
        var parts = [url.lastPathComponent]
        if let duration { parts.append(MediaEditCore.formatTime(duration)) }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let bytes = attrs[.size] as? Int64 {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private func isAudioOnlySource(_ url: URL) -> Bool {
        ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "ogg"]
            .contains(url.pathExtension.lowercased())
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.movie, .audio]
        for ext in ["mkv", "webm", "flv", "m4v", "mov", "mp4", "avi", "ts",
                    "mp3", "m4a", "flac", "ogg", "wav"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil
        source = url
        player = nil
    }

    private func loadDuration() {
        guard let source else {
            duration = nil
            return
        }
        let url = source
        Task {
            let value = await MediaEditProbe.duration(url)
            guard self.source == url else { return }
            duration = value
        }
    }

    private func run() {
        guard let source else { return }
        error = nil
        if mode == .convert {
            store.convertMedia(source: source, format: format)
            return
        }
        guard !isAudioOnlySource(source) else {
            error = String(localized: "GIF needs a video source.")
            return
        }
        let width = Int(widthText.trimmingCharacters(in: .whitespaces)) ?? 480
        let fps = Int(fpsText.trimmingCharacters(in: .whitespaces)) ?? 12
        guard width >= 64, width <= 1920, fps >= 2, fps <= 30 else {
            error = String(localized: "Width must be 64–1920 and frame rate 2–30.")
            return
        }
        let start = MediaEditCore.parseTime(startText)
        var clipDuration: Double?
        if !endText.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let end = MediaEditCore.parseTime(endText), let startValue = start,
                  end > startValue else {
                error = String(localized: "Duration must be longer than the start time.")
                return
            }
            clipDuration = end - startValue
        }
        store.videoToGIF(source: source, start: start, duration: clipDuration,
                         width: width, fps: fps)
    }
}

/// 紧凑的「标签 + 输入框」行（媒体表单用；工具箱没有通用组件）。
private struct LabeledField: View {
    let title: String
    @Binding var text: String
    var width: CGFloat = 80

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: width)
        }
    }
}
