import AVFoundation
import SwiftUI

/// 视频剪辑工具（v0.8.27 媒体批）：预览播放 + 入出点剪切（快速流复制 /
/// 精确重编码）+ 多段拼接。执行走 MediaEditStore（AVFoundation 主 +
/// ffmpeg 回退），本视图只管输入与展示。
struct VideoEditorToolView: View {
    @ObservedObject private var store = MediaEditStore.shared
    @ObservedObject private var handoff = ToolboxHandoff.shared

    @State private var source: URL?
    @State private var duration: Double?
    @State private var mode: Mode = .trim
    @State private var startText = "0:00"
    @State private var endText = ""
    @State private var precise = false
    @State private var sources: [URL] = []
    @State private var error: String?
    @State private var player: AVPlayer?

    enum Mode: String, CaseIterable, Identifiable {
        case trim, merge
        var id: String { rawValue }
        var title: String {
            switch self {
            case .trim: return String(localized: "Trim")
            case .merge: return String(localized: "Merge")
            }
        }
    }

    enum TopMode: String, CaseIterable, Identifiable {
        case multiTrack, quick
        var id: String { rawValue }
        var title: String {
            switch self {
            case .multiTrack: return String(localized: "Multi-Track")
            case .quick: return String(localized: "Quick Cut")
            }
        }
    }

    @State private var topMode: TopMode = .multiTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $topMode) {
                ForEach(TopMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 200)
            if topMode == .multiTrack {
                MultiTrackEditorView()
            } else {
                quickContent
            }
        }
    }

    /// 快速剪切（v0.8.27 媒体批）：单文件入出点剪切与拼接，保留作轻量路径。
    private var quickContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourceRow
            if let source {
                MediaPlayerPreview(url: source, player: $player)
                    .frame(height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .id(source)
            }
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 200)
            if mode == .trim {
                trimSection
            } else {
                mergeSection
            }
            runRow
            if let error { ToolErrorText(text: error) }
            MediaJobsList(jobs: store.jobs)
        }
        .onAppear(perform: takeHandoff)
        .onChange(of: handoff.token) { _, _ in takeHandoff() }
    }

    // MARK: - 来源

    private var sourceRow: some View {
        HStack(spacing: 8) {
            Button(String(localized: "Choose Video…")) { chooseSource() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if let info = sourceInfo {
                Text(info)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var sourceInfo: String? {
        guard let source else { return nil }
        var parts = [source.lastPathComponent]
        if let duration {
            parts.append(MediaEditCore.formatTime(duration))
        }
        if let size = fileSize(source) {
            parts.append(size)
        }
        return parts.joined(separator: " · ")
    }

    private func fileSize(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func load(_ url: URL) {
        error = nil
        source = url
        startText = "0:00"
        endText = ""
        duration = nil
        player = nil
        Task {
            duration = await MediaEditProbe.duration(url)
        }
    }

    /// 播放器/查看器递进来的文件（ToolboxHandoff）。
    private func takeHandoff() {
        guard let url = handoff.takeFile(for: .videoEditor) else { return }
        load(url)
    }

    // MARK: - 剪切

    private var trimSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                MediaTimeField(label: String(localized: "In Point"), text: $startText)
                MediaTimeField(label: String(localized: "Out Point"), text: $endText)
                Spacer()
            }
            HStack(spacing: 8) {
                Button(String(localized: "Mark In")) {
                    startText = MediaEditCore.formatTime(player?.currentTime().seconds ?? 0)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(player == nil)
                Button(String(localized: "Mark Out")) {
                    endText = MediaEditCore.formatTime(player?.currentTime().seconds ?? 0)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(player == nil)
                Spacer()
                Picker("", selection: $precise) {
                    Text(String(localized: "Fast (keyframe)")).tag(false)
                    Text(String(localized: "Exact (re-encode)")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
            }
        }
    }

    // MARK: - 拼接

    private var mergeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(sources.enumerated()), id: \.offset) { index, url in
                HStack(spacing: 6) {
                    Text("\(index + 1).")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(url.lastPathComponent)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        guard index > 0 else { return }
                        sources.swapAt(index, index - 1)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(index == 0)
                    Button {
                        sources.remove(at: index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            }
            Button(String(localized: "Add Clips…")) { addClips() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func addClips() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        error = nil
        sources.append(contentsOf: panel.urls)
    }

    // MARK: - 执行

    private var runRow: some View {
        HStack(spacing: 8) {
            Button(mode == .trim
                   ? String(localized: "Run Trim")
                   : String(localized: "Run Merge")) { run() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(mode == .trim ? source == nil : sources.count < 2)
            if mode == .trim, precise {
                Text("Frame-accurate cut; slower because the segment is re-encoded.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private func run() {
        error = nil
        if mode == .trim {
            guard let source, let duration else {
                error = String(localized: "Choose a media file first.")
                return
            }
            guard let plan = MediaEditCore.trimPlan(startRaw: startText, endRaw: endText,
                                                    duration: duration) else {
                error = String(localized: "Enter a valid time range (start must be before end).")
                return
            }
            store.trimVideo(source: source, plan: plan, precise: precise)
        } else {
            guard sources.count >= 2 else {
                error = String(localized: "Choose at least two clips to merge.")
                return
            }
            guard sources.allSatisfy({ MediaEditCore.isVideoFile($0) }) else {
                error = String(localized: "All clips must be video files.")
                return
            }
            store.concatVideo(sources: sources)
        }
    }
}
