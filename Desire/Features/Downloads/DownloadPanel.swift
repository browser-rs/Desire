import AppKit
import SwiftUI

struct DownloadPanel: View {
    @ObservedObject var store: DownloadStore

    @State private var searchText = ""

    private var filteredDownloads: [DownloadItem] {
        guard !searchText.isEmpty else { return store.downloads }
        return store.downloads.filter {
            $0.filename.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var sections: [(String, [DownloadItem])] {
        let filtered = searchText.isEmpty ? nil : filteredDownloads
        switch store.groupingMode {
        case .date:
            return filtered != nil ? [(String(localized: "Results"), filtered!)] : store.groupedByDate()
        case .fileType:
            return filtered != nil ? [(String(localized: "Results"), filtered!)] : store.groupedByFileType()
        case .status:
            return filtered != nil ? [(String(localized: "Results"), filtered!)] : store.groupedByStatus()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !store.downloads.isEmpty {
                filterBar
                Divider()
            }
            content
        }
        .frame(width: 480, height: 520)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Downloads")
                .font(.system(size: 15, weight: .semibold))

            if store.hasActive {
                statusChip(String(localized: "\(store.activeCount) active"), tint: .accentColor)
            }
            if store.pausedCount > 0 {
                statusChip(String(localized: "\(store.pausedCount) paused"), tint: .orange)
            }

            Spacer()

            Button {
                NSWorkspace.shared.open(store.downloadFolder)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Download Folder")

            Menu {
                Button("Pause All") { store.pauseAll() }
                    .disabled(!store.hasActive)
                Button("Resume All") { store.resumeAll() }
                    .disabled(store.pausedCount == 0)
                Divider()
                Button("Cancel All", role: .destructive) { store.cancelAll() }
                    .disabled(!store.hasActive && store.pausedCount == 0)
                Button("Clear Finished") { store.clearFinished() }
                    .disabled(isNothingFinished)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Clear Finished")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var isNothingFinished: Bool {
        store.downloads.isEmpty || store.downloads.allSatisfy { $0.state == .inProgress && !$0.isPaused }
    }

    private func statusChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))

            Menu {
                Button("All Types") { store.fileTypeFilter = nil }
                Divider()
                ForEach(DownloadItem.FileType.allCases, id: \.self) { type in
                    Button {
                        store.fileTypeFilter = type
                    } label: {
                        Label(type.rawValue.capitalized, systemImage: type.icon)
                    }
                }
            } label: {
                Image(systemName: store.fileTypeFilter?.icon ?? "line.3.horizontal.decrease.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(store.fileTypeFilter != nil ? Color.accentColor : .secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(
                            store.fileTypeFilter != nil
                                ? Color.accentColor.opacity(0.12)
                                : Color(nsColor: .controlBackgroundColor)
                        )
                    )
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()

            Picker("Group by", selection: $store.groupingMode) {
                Image(systemName: "calendar").tag(DownloadStore.GroupingMode.date)
                Image(systemName: "doc").tag(DownloadStore.GroupingMode.fileType)
                Image(systemName: "checkmark.circle").tag(DownloadStore.GroupingMode.status)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 96)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let allSections = sections
        if allSections.isEmpty || allSections.allSatisfy({ $0.1.isEmpty }) {
            EmptyState(message: searchText.isEmpty
                       ? String(localized: "No Downloads")
                       : String(localized: "No Matching Downloads"))
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(allSections, id: \.0) { sectionTitle, items in
                        Section {
                            VStack(spacing: 2) {
                                ForEach(items) { item in
                                    DownloadRow(item: item, store: store)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                            .padding(.bottom, 8)
                        } header: {
                            if allSections.count > 1 {
                                HStack {
                                    Text(sectionTitle.uppercased())
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(items.count)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 5)
                                .background(Color(nsColor: .windowBackgroundColor))
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Row

private struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject var store: DownloadStore

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 11) {
            iconTile

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.filename)
                        .lineLimit(1)
                        .font(.system(size: 12.5, weight: .medium))
                    if item.isPrivate {
                        // Incognito downloads must be identifiable at a
                        // glance — same badge language as the tile badges.
                        Image(systemName: "mask")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3.5)
                            .background(Circle().fill(Color.purple))
                            .help("Incognito download — not saved to history")
                    }
                }
                statusLine
                if item.state == .inProgress {
                    progressBar
                }
            }

            Spacer(minLength: 6)

            actions
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color(nsColor: .controlBackgroundColor).opacity(0.85) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(.hoverFast, value: isHovering)
        .contextMenu { rowMenu }
    }

    // MARK: Row pieces

    private var iconTile: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: item.fileType.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.13)))

            if item.isPaused {
                badge("pause.fill", color: .orange)
            } else if item.state == .failed {
                badge("exclamationmark.fill", color: .red)
            }
        }
        .offset(x: -2, y: 2)
    }

    private func badge(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 5.5, weight: .bold))
            .foregroundStyle(.white)
            .padding(3)
            .background(Circle().fill(color))
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
    }

    private var tint: Color {
        if item.state == .failed { return .red }
        switch item.fileType {
        case .image: return .blue
        case .video: return .purple
        case .audio: return .pink
        case .document: return .orange
        case .archive: return .brown
        case .application: return .green
        case .other: return .secondary
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch item.state {
        case .inProgress where item.isPaused:
            HStack(spacing: 4) {
                Text("Paused")
                    .foregroundStyle(.orange)
                if item.totalBytes > 0 {
                    Text("\(Int((item.progress * 100).rounded()))%")
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(Color.accentColor)
                }
                Text("\(Int((item.progress * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                if let remaining = item.estimatedTimeRemaining,
                   !formatTimeRemaining(remaining).isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(formatTimeRemaining(remaining))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
        case .failed:
            Text(item.error ?? String(localized: "Download Failed"))
                .lineLimit(2)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        case .completed:
            HStack(spacing: 4) {
                Text(formatBytes(item.totalBytes))
                Text("·").foregroundStyle(.tertiary)
                Text(timeText(item.startTime))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        case .paused:
            // Legacy persisted state from a previous release.
            Text("Paused")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        }
    }

    private var progressBar: some View {
        ProgressView(value: item.isIndeterminate ? nil : item.progress)
            .progressViewStyle(.linear)
            .tint(item.isPaused ? Color.orange : Color.accentColor)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2) {
            switch item.state {
            case .inProgress where !item.isPaused:
                rowButton("pause.fill", help: "Pause") { store.pause(id: item.id) }
                rowButton("xmark.circle", help: "Cancel") { store.remove(id: item.id) }
            case .inProgress:
                rowButton("play.fill", help: "Resume", tint: .accentColor) { store.resume(id: item.id) }
                rowButton("xmark.circle", help: "Cancel") { store.remove(id: item.id) }
            case .completed:
                rowButton("arrow.up.forward.app", help: "Open", tint: .accentColor) { store.openFile(item) }
                rowButton("folder", help: "Show in Finder") { store.revealInFinder(item) }
                rowButton("trash", help: "Remove from List") { store.remove(id: item.id) }
            case .failed:
                rowButton("arrow.clockwise", help: "Retry", tint: .accentColor) { store.retry(item) }
                rowButton("trash", help: "Remove from List") { store.remove(id: item.id) }
            case .paused:
                rowButton("play.fill", help: "Resume", tint: .accentColor) { store.resume(id: item.id) }
            }
        }
    }

    private func rowButton(_ systemName: String, help: String, tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
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

#Preview {
    DownloadPanel(store: DownloadStore())
        .frame(width: 480, height: 520)
}
