import AVFoundation
import SwiftUI

/// 音频剪辑工具（v0.8.27 媒体批）：剪切 / 拼接 / 从视频提取音轨（m4a）。
/// 输出统一 m4a（AAC）——异编码进同一容器最稳的路线。
struct AudioEditorToolView: View {
    @ObservedObject private var store = MediaEditStore.shared
    @ObservedObject private var handoff = ToolboxHandoff.shared

    @State private var source: URL?
    @State private var duration: Double?
    @State private var mode: Mode = .trim
    @State private var startText = "0:00"
    @State private var endText = ""
    @State private var sources: [URL] = []
    @State private var error: String?
    @State private var player: AVPlayer?

    enum Mode: String, CaseIterable, Identifiable {
        case trim, merge, extract
        var id: String { rawValue }
        var title: String {
            switch self {
            case .trim: return String(localized: "Trim")
            case .merge: return String(localized: "Merge")
            case .extract: return String(localized: "Extract")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourceRow
            if let source, mode != .merge {
                MediaPlayerPreview(url: source, player: $player)
                    .frame(height: 64)
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
            .frame(maxWidth: 260)
            switch mode {
            case .trim:
                trimSection
            case .merge:
                mergeSection
            case .extract:
                extractSection
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
            Button(mode == .extract
                   ? String(localized: "Choose Video…")
                   : String(localized: "Choose Audio…")) { chooseSource() }
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
        if let attrs = try? FileManager.default.attributesOfItem(atPath: source.path),
           let bytes = attrs[.size] as? Int64 {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
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

    private func takeHandoff() {
        guard let url = handoff.takeFile(for: .audioEditor) else { return }
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

    // MARK: - 提取

    private var extractSection: some View {
        Text("Saves the audio track of the chosen file as m4a (AAC).")
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
    }

    // MARK: - 执行

    private var runRow: some View {
        HStack(spacing: 8) {
            Button(runTitle) { run() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canRun)
            Spacer()
        }
    }

    private var runTitle: String {
        switch mode {
        case .trim: return String(localized: "Run Trim")
        case .merge: return String(localized: "Run Merge")
        case .extract: return String(localized: "Extract Audio (m4a)")
        }
    }

    private var canRun: Bool {
        switch mode {
        case .trim: return source != nil && duration != nil
        case .merge: return sources.count >= 2
        case .extract: return source != nil
        }
    }

    private func run() {
        error = nil
        switch mode {
        case .trim:
            guard let source, let duration else {
                error = String(localized: "Choose a media file first.")
                return
            }
            guard let plan = MediaEditCore.trimPlan(startRaw: startText, endRaw: endText,
                                                    duration: duration) else {
                error = String(localized: "Enter a valid time range (start must be before end).")
                return
            }
            store.trimAudio(source: source, plan: plan)
        case .merge:
            guard sources.count >= 2 else {
                error = String(localized: "Choose at least two clips to merge.")
                return
            }
            guard sources.allSatisfy({ MediaEditCore.isAudioFile($0) }) else {
                error = String(localized: "All clips must be audio files.")
                return
            }
            store.concatAudio(sources: sources)
        case .extract:
            guard let source else {
                error = String(localized: "Choose a media file first.")
                return
            }
            store.extractAudio(source: source)
        }
    }
}
