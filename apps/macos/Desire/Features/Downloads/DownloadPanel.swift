import AppKit
import os
import SwiftUI

/// 下载面板（工具栏下载按钮的 popover）。
///
/// 视觉规则（2026-09 美学轮，与全应用设计令牌一致）：
/// - 排版三级：文件名 12.5 medium/primary → 元信息 11/monospacedDigit/secondary
///   → 分组标题 10 semibold/tertiary。数字统一等宽，进度百分比不再左右跳动。
/// - 状态用"小圆点 + 静文字"呈现（旧版两枚饱和胶囊比标题还抢眼）；可操作的
///   状态（失败 → 重试）给可见按钮，不再藏在 hover 里。
/// - 进度条与分组切换自绘：4pt 胶囊与面板的圆角/留白同一套语言，比系统
///   `ProgressView` 更细更克制，且总大小未知时能给"滑动段"而不是假的百分比；
///   分组切换只放三个图标，自绘后能精确控制选中态的抬升与强调色。
/// - 行分隔线内缩对齐文字（Finder 列表观感），hover 底色取代分隔线。
/// - 动效复用全局曲线：hover `.hoverFast`、进度 `.easeOut(0.25)`、进出场
///   `.transitionNormal`；总大小未知时用滑动的胶囊段，不画假百分比。
struct DownloadPanel: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var store: DownloadStore
    /// 批量下载默认参数面板（齿轮）+ 首次进入视频任务栏的引导。
    @State private var showBatchSettings = false
    @AppStorage("batch.onboardingDone") private var batchOnboardingDone = false
    @State private var showBatchOnboarding = false
    /// 预览 sheet 的文件（v0.7.19）。
    @State private var previewURL: URL?

    @State private var searchText = ""
    @State private var showBatchTasks = false
    @ObservedObject private var scheduler = DownloadScheduler.shared
    @State private var showScheduleSheet = false

    private var filteredDownloads: [DownloadItem] {
        guard !searchText.isEmpty else { return store.downloads }
        return store.downloads.filter {
            $0.filename.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var sections: [(String, [DownloadItem])] {
        switch store.groupingMode {
        case .date:
            searchText.isEmpty ? store.groupedByDate() : [(String(localized: "Results"), filteredDownloads)]
        case .fileType:
            searchText.isEmpty ? store.groupedByFileType() : [(String(localized: "Results"), filteredDownloads)]
        case .status:
            searchText.isEmpty ? store.groupedByStatus() : [(String(localized: "Results"), filteredDownloads)]
        }
    }

    /// 失败且带源 URL 的行（最新优先）——批量重试清单（v0.8.10）。
    private var retryableIDs: [UUID] {
        DownloadCenterPlan.retryable(rows: store.downloads.map {
            ($0.id, $0.sourceURL?.absoluteString, $0.state == .failed, $0.startTime)
        })
    }

    /// 近 7 天同源重复提示（dismiss 后到列表变化前不再出现）。
    @State private var repeatHintDismissed = false
    private struct RepeatHint { let recentID: UUID; let text: String; let fileMissing: Bool }
    private var repeatHint: RepeatHint? {
        guard !repeatHintDismissed else { return nil }
        let rows = store.downloads.map {
            (id: $0.id, sourceURL: $0.sourceURL?.absoluteString, filename: $0.filename, startTime: $0.startTime)
        }
        guard let rep = DownloadCenterPlan.repeats(rows: rows).first else { return nil }
        let item = store.downloads.first(where: { $0.id == rep.recentID })
        let missing = !(item?.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        let text = String(
            format: String(localized: "\"%@\" was downloaded %d time(s) in the last 7 days — the newest copy is above"),
            rep.recentFilename, rep.earlierCount + 1)
        return RepeatHint(recentID: rep.recentID, text: text, fileMissing: missing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // 视图切换即头部本身：Tab 组并入标题行（方案 B），不再单独占一行
            Divider()
            if !showBatchTasks && !scheduler.items.isEmpty {
                scheduledSection
                Divider()
            }
            if showBatchTasks {
                // 媒体/批量进度只在进入"视频任务"后由子视图观察——
                // 否则后台批量任务的每次进度发布会重绘下载列表（v0.7.30）。
                BatchMediaPanel(store: .shared, mediaStore: .shared)
            } else {
                if !store.downloads.isEmpty {
                    filterBar
                }
                if let hint = repeatHint {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10.5))
                            .foregroundStyle(appAccent)
                        Text(hint.text)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Button(String(localized: "Reopen")) {
                            if let item = store.downloads.first(where: { $0.id == hint.recentID }),
                               let url = item.fileURL {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(appAccent)
                        .disabled(hint.fileMissing)
                        Button {
                            repeatHintDismissed = true
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(appAccent.opacity(0.06))
                }
                Divider()
                content
            }
        }
        .frame(width: 480, height: 520)
        // 首次进入"视频任务"：弹一次默认参数引导（目录/分卷/并发/预留空间），
        // 完成打卡后不再自动出现——之后随时点右下角齿轮再调。
        .onChange(of: showBatchTasks) { _, shown in
            if shown && !batchOnboardingDone && !showBatchOnboarding {
                showBatchOnboarding = true
            }
        }
        .sheet(isPresented: $showBatchOnboarding) {
            BatchDownloadSettingsContent(isOnboarding: true)
                .padding(22)
                .frame(width: 520)
        }
        .sheet(isPresented: Binding(
            get: { previewURL != nil },
            set: { if !$0 { previewURL = nil } }
        )) {
            if let url = previewURL {
                DownloadPreviewSheet(fileURL: url) { previewURL = nil }
            }
        }
        .sheet(isPresented: $showBatchSettings) {
            BatchDownloadSettingsContent()
                .padding(22)
                .frame(width: 520)
        }
        .sheet(isPresented: $showScheduleSheet) {
            ScheduledDownloadSheet()
        }
        .task { store.scanFilePresence() }
    }

    /// 定时下载队列（v0.8.0）：最多展示 3 条，其余折叠成计数。
    private var scheduledSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                Text("Scheduled")
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer()
                if scheduler.items.count > 1 {
                    Button("Cancel All") { scheduler.cancelAll() }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.secondary)
            ForEach(Array(scheduler.items.prefix(3))) { item in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.filename)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                        Text(URL(string: item.url)?.host ?? item.url)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(item.startAt, style: .relative)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button {
                        scheduler.cancel(id: item.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel scheduled download")
                }
            }
            if scheduler.items.count > 3 {
                Text(verbatim: "+\(scheduler.items.count - 3)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    /// 面板顶部二选一 Tab 的**段**（容器胶囊见 header）：选中 = 强调色实底
    /// 圆胶囊 + 白字半粗，未选 = 次级文字。
    private func segmentTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(selected
                        ? AnyShapeStyle(appAccent)
                        : AnyShapeStyle(Color.clear))
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            // 视图切换 Tab **贴左**（页签名即视图名，"下载"大标题与 Tab 里的
            // "下载"重复，省去）；全头部统一 28pt 高。
            HStack(spacing: 2) {
                segmentTab(String(localized: "Downloads"), selected: !showBatchTasks) {
                    showBatchTasks = false
                }
                segmentTab(String(localized: "Video Tasks"), selected: showBatchTasks) {
                    showBatchTasks = true
                }
            }
            .padding(3)
            .frame(height: 28)
            .background(
                Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            )
            .overlay(
                Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
            )

            statusSummary

            Spacer(minLength: 8)

            // 批量下载设置齿轮：仅"视频任务"视图显示（用户需求：挪到顶部）。
            if showBatchTasks {
                HoverIcon(systemName: "gearshape", action: {
                    showBatchSettings = true
                }, help: "Batch download settings")
            } else {
                HoverIcon(systemName: "clock.badge.plus", action: {
                    showScheduleSheet = true
                }, help: "Schedule Download…")
            }

            HoverIcon(systemName: "folder", action: {
                NSWorkspace.shared.open(store.downloadFolder)
            }, help: "Open Download Folder")

            Menu {
                Button("Pause All") { store.pauseAll() }
                    .disabled(!store.hasActive)
                Button("Resume All") { store.resumeAll() }
                    .disabled(store.pausedCount == 0)
                // 失败项批量重试（v0.8.10 下载中心 v2）。
                Button(String(localized: "Retry All Failed (\(retryableIDs.count))")) {
                    for id in retryableIDs {
                        if let item = store.downloads.first(where: { $0.id == id }) {
                            store.retry(item)
                        }
                    }
                }
                .disabled(retryableIDs.isEmpty)
                Divider()
                Button("Cancel All", role: .destructive) { store.cancelAll() }
                    .disabled(!store.hasActive && store.pausedCount == 0)
                Button("Clear Finished") { store.clearFinished() }
                    .disabled(isNothingFinished)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .offset(y: 1)
            .help("More")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// 状态摘要：小圆点 + 静文字。
    @ViewBuilder
    private var statusSummary: some View {
        if store.hasActive || store.pausedCount > 0 {
            HStack(spacing: 10) {
                if store.hasActive {
                    summaryItem(color: appAccent, text: String(localized: "\(store.activeCount) active"))
                }
                if store.pausedCount > 0 {
                    summaryItem(color: .orange, text: String(localized: "\(store.pausedCount) paused"))
                }
            }
            .offset(y: -0.5)
        }
    }

    private func summaryItem(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var isNothingFinished: Bool {
        store.downloads.isEmpty || store.downloads.allSatisfy { $0.state == .inProgress && !$0.isPaused }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Search Downloads…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: .radiusButton)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            fileTypeFilter
            groupByControl
        }
        .padding(.top, 12)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var fileTypeFilter: some View {
        Menu {
            Button("All Types") { store.fileTypeFilter = nil }
            Divider()
            ForEach(DownloadItem.FileType.allCases, id: \.self) { type in
                Button {
                    store.fileTypeFilter = type
                } label: {
                    Label(type.title, systemImage: type.icon)
                }
            }
        } label: {
            let active = store.fileTypeFilter != nil
            Image(systemName: store.fileTypeFilter?.icon ?? "line.3.horizontal.decrease")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(active ? appAccent : .secondary)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: .radiusButton).fill(
                        active ? appAccent.opacity(0.14) : Color(nsColor: .controlBackgroundColor)
                    )
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by Type")
    }

    /// 自绘的分组切换：这里只需要三个图标，自绘后选中态（抬升 + 强调色图标）
    /// 与面板其余部分同一套令牌；系统 `Picker(.segmented)` 的图标分段偏宽。
    private var groupByControl: some View {
        HStack(spacing: 2) {
            ForEach(DownloadStore.GroupingMode.allCases, id: \.self) { mode in
                let selected = store.groupingMode == mode
                Button {
                    store.groupingMode = mode
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? appAccent : .secondary)
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
                                .shadow(color: .black.opacity(selected ? 0.22 : 0), radius: 1.5, y: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.title)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: .radiusButton)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .animation(.controlSpring, value: store.groupingMode)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let allSections = sections
        if allSections.isEmpty || allSections.allSatisfy({ $0.1.isEmpty }) {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(allSections, id: \.0) { sectionTitle, items in
                        Section {
                            VStack(spacing: 0) {
                                ForEach(items) { item in
                                    DownloadRow(item: item, store: store,
                                                onPreview: { previewURL = $0 })
                                    if item.id != items.last?.id {
                                        RowSeparator()
                                    }
                                }
                            }
                            .padding(.bottom, 4)
                        } header: {
                            SectionHeader(title: sectionTitle, count: items.count, showCount: allSections.count > 1)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .animation(.transitionNormal, value: store.downloads.count)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            EmptyState(
                title: searchText.isEmpty
                    ? String(localized: "No Downloads")
                    : String(localized: "No Matching Downloads"),
                systemImage: searchText.isEmpty ? "arrow.down.circle" : "magnifyingglass",
                description: searchText.isEmpty
                    ? String(localized: "Files you download show up here.")
                    : nil
            )
            if searchText.isEmpty {
                Button {
                    NSWorkspace.shared.open(store.downloadFolder)
                } label: {
                    Text("Open Download Folder")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(.tint.opacity(0.14)))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Enum presentation (view layer)

private extension DownloadStore.GroupingMode {
    var icon: String {
        switch self {
        case .date: "calendar"
        case .fileType: "doc"
        case .status: "checkmark.circle"
        }
    }

    var title: String {
        switch self {
        case .date: String(localized: "Group by Date")
        case .fileType: String(localized: "Group by Type")
        case .status: String(localized: "Group by Status")
        }
    }
}

private extension DownloadItem.FileType {
    var title: String { rawValue.capitalized }
}

// MARK: - Section header

/// 吸顶分组标题：小字 + 材料背景（滚动内容从下面穿过，不用死板色块）。
private struct SectionHeader: View {
    let title: String
    let count: Int
    let showCount: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            if showCount {
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 5)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Separator

/// 内缩到文字起始位置的分隔线（Finder 列表观感）。
private struct RowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.10))
            .frame(height: 0.5)
            .padding(.leading, 45)
            .padding(.trailing, 4)
    }
}

// MARK: - Row

private struct DownloadRow: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let item: DownloadItem
    @ObservedObject var store: DownloadStore
    /// 行内预览（v0.7.19）：完成的本地文件走 QuickLook 内嵌 sheet。
    let onPreview: (URL) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            iconTile
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                titleLine
                statusLine
                if item.state == .inProgress && !item.isQueued {
                    ProgressBar(
                        progress: item.progress,
                        indeterminate: item.isIndeterminate,
                        tint: item.isPaused ? .orange : appAccent
                    )
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 6)

            actions
                .padding(.top, 1)
                .opacity(isHovering || item.state == .failed ? 1 : 0)
                .allowsHitTesting(isHovering || item.state == .failed)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: .radiusButton)
                .fill(isHovering ? Color(nsColor: .controlBackgroundColor).opacity(0.55) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: .radiusButton))
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(.hoverFast, value: isHovering)
        // 完成行：拖到 Finder/任意 App（文件 URL 载体）；双击 = 打开。
        // 仅"已完成且文件真实存在"时挂——进行中/失败行没有可交付的实体。
        .modifier(CompletedFileDraggable(item: item))
        .onTapGesture(count: 2) {
            if item.state == .completed, dragFileURL != nil {
                store.openFile(item)
            }
        }
        .contextMenu { rowMenu }
    }

    /// 另存为（v0.8.11）：NSSavePanel 选落点（默认同名），移动文件；
    /// 移出下载目录后从台账移除（面板行随文件走）。取消静默。
    private func saveAs(_ item: DownloadItem) {
        guard let src = item.fileURL, FileManager.default.fileExists(atPath: src.path) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.filename
        panel.directoryURL = store.downloadFolder
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if dest.standardizedFileURL.path == src.standardizedFileURL.path { return }
            try FileManager.default.moveItem(at: src, to: dest)
            if !dest.path.hasPrefix(store.downloadFolder.path) {
                store.remove(id: item.id)
            }
        } catch {
            Log.downloads.error("save-as move failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 完成行的真实文件 URL（存在才给拖拽/双击用）。
    private var dragFileURL: URL? {
        guard item.state == .completed, let url = item.fileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: Row pieces

    private var titleLine: some View {
        HStack(spacing: 5) {
            Text(item.filename)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: 12.5, weight: .medium))
            if item.isPrivate {
                Image(systemName: "mask")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(Color.purple))
                    .help("Incognito download — not saved to history")
            }
        }
    }

    private var iconTile: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: item.fileType.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.14)))

            if item.isPaused {
                badge("pause.fill", color: .orange)
            } else if item.state == .failed {
                badge("exclamationmark", color: .red)
            }
        }
        .offset(x: -2, y: 2)
    }

    private func badge(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 6, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 12, height: 12)
            .background(Circle().fill(color))
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
    }

    private var tint: Color {
        if item.state == .failed { return .red }
        switch item.fileType {
        case .image: return .blue
        case .video: return .purple
        case .audio: return .pink
        case .document: return .orange
        case .archive: return .teal
        case .application: return .green
        case .other: return .secondary
        }
    }

    /// 元信息行：数字等宽，层级靠颜色而不是字号堆叠。
    @ViewBuilder
    private var statusLine: some View {
        switch item.state {
        case .inProgress where item.isQueued:
            Text("Waiting for a download slot…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .inProgress where item.isPaused:
            HStack(spacing: 4) {
                Text("Paused").foregroundStyle(.orange)
                if item.totalBytes > 0 {
                    Text(percentText).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .font(.system(size: 11))
        case .inProgress where item.isIndeterminate:
            Text("Downloading…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .inProgress:
            HStack(spacing: 4) {
                if item.speed > 0 {
                    Text(formatSpeed(item.speed))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
                Text(percentText).foregroundStyle(.secondary).monospacedDigit()
                if let remaining = item.estimatedTimeRemaining,
                   !formatTimeRemaining(remaining).isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(formatTimeRemaining(remaining)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .font(.system(size: 11))
        case .failed:
            Text(item.error ?? String(localized: "Download Failed"))
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .help(item.error ?? String(localized: "Download Failed"))
        case .completed:
            HStack(spacing: 4) {
                Text(formatBytes(item.totalBytes)).monospacedDigit()
                Text("·").foregroundStyle(.tertiary)
                Text(timeText(item.startTime))
                // 文件被用户从磁盘删除后如实标注（很常见），并给"重新下载"。
                // **读缓存**（store.scanFilePresence 后台批量 stat）——此前每行
                // 渲染在主线程同步 stat，外置卷一卡面板全卡（实测）。
                if store.missingFiles.contains(item.id) {
                    Text("·").foregroundStyle(.tertiary)
                    Text(String(localized: "File deleted"))
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        case .paused:
            Text("Paused")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        }
    }

    private var percentText: String {
        "\(Int((item.progress * 100).rounded()))%"
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2) {
            switch item.state {
            case .inProgress where !item.isPaused:
                rowButton("pause.fill", help: "Pause") { store.pause(id: item.id) }
                rowButton("xmark", help: "Cancel") { store.remove(id: item.id) }
            case .inProgress:
                rowButton("play.fill", help: "Resume", tint: appAccent) { store.resume(id: item.id) }
                rowButton("xmark", help: "Cancel") { store.remove(id: item.id) }
            case .completed:
                // 同上：读后台扫描缓存，渲染路径零 IO。
                if store.missingFiles.contains(item.id) {
                    // 文件已被本地删除：Open/Finder 是空操作——给"重新下载"。
                    rowButton("arrow.clockwise", help: "Download Again", tint: appAccent) {
                        store.redownload(item)
                    }
                } else {
                    rowButton("arrow.up.forward.app", help: "Open", tint: appAccent) { store.openFile(item) }
                    rowButton("folder", help: "Show in Finder") { store.revealInFinder(item) }
                }
                rowButton("trash", help: "Remove from List") { store.remove(id: item.id) }
            case .failed:
                // 可操作的状态给可见按钮，而不是只藏在 hover 里。
                retryButton
                rowButton("trash", help: "Remove from List") { store.remove(id: item.id) }
            case .paused:
                rowButton("play.fill", help: "Resume", tint: appAccent) { store.resume(id: item.id) }
            }
        }
    }

    private var retryButton: some View {
        Button { store.retry(item) } label: {
            Text("Retry")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Retry")
    }

    private func rowButton(_ systemName: String, help: String, tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var rowMenu: some View {
        switch item.state {
        case .inProgress where !item.isPaused:
            Button("Pause") { store.pause(id: item.id) }
        case .inProgress, .paused:
            Button("Resume") { store.resume(id: item.id) }
        case .completed:
            Button("Open") { store.openFile(item) }
            Button("Show in Finder") { store.revealInFinder(item) }
            // 另存为（v0.8.11）：选目录移动产物（downloadFolder 之外时台账
            // 移除——文件已不在下载目录的语义）。挂 NSSavePanel 让用户改名。
            if let url = item.fileURL, FileManager.default.fileExists(atPath: url.path) {
                Button(String(localized: "Save As…")) { saveAs(item) }
            }
            if let url = item.fileURL, FileManager.default.fileExists(atPath: url.path) {
                Button("Preview") { onPreview(url) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            }
        case .failed:
            Button("Retry") { store.retry(item) }
        }
        if let source = item.sourceURL {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.absoluteString, forType: .string)
            }
        }
        Divider()
        Menu("Priority") {
            Button("High Priority") { store.setPriority(id: item.id, priority: .high) }
            Button("Normal Priority") { store.setPriority(id: item.id, priority: .normal) }
            Button("Low Priority") { store.setPriority(id: item.id, priority: .low) }
        }
        Divider()
        Button("Remove from List", role: .destructive) { store.remove(id: item.id) }
    }

    private func timeText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute())
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "Yesterday")
        }
        return date.formatted(.dateTime.month().day())
    }
}

// MARK: - Progress bar

/// 自绘 4pt 胶囊进度条：跟随强调色；总大小未知时滑动一段表示进行中
/// （系统 `ProgressView` 只有不确定态的竖直条纹，与这里的胶囊语言不一致）。
private struct ProgressBar: View {
    let progress: Double
    let indeterminate: Bool
    let tint: Color

    @State private var slide = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))

                if indeterminate {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(24, geo.size.width * 0.28))
                        .offset(x: slide ? geo.size.width * 0.72 : 0)
                        .animation(
                            .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                            value: slide
                        )
                        .onAppear { slide = true }
                } else {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, min(geo.size.width, geo.size.width * progress)))
                        .animation(.easeOut(duration: 0.25), value: progress)
                }
            }
        }
        .frame(height: 4)
    }
}

#Preview {
    DownloadPanel(store: DownloadStore())
        .frame(width: 480, height: 520)
}

/// 完成下载行的拖拽载体：挂 `.onDrag`（NSItemProvider 携带文件 URL——
/// Finder/邮件/任意 App 都能收）。非完成行原样透传。
private struct CompletedFileDraggable: ViewModifier {
    let item: DownloadItem

    func body(content: Content) -> some View {
        if item.state == .completed, let url = item.fileURL,
           FileManager.default.fileExists(atPath: url.path) {
            content.onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        } else {
            content
        }
    }
}
