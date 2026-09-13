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
            // Header
            HStack {
                Text("Downloads").font(.headline)

                if store.hasActive {
                    Text("\(store.activeCount) active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(Capsule())
                }

                if store.pausedCount > 0 {
                    Text("\(store.pausedCount) paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Capsule())
                }

                Spacer()

                // Batch operations menu
                if store.hasActive || store.pausedCount > 0 {
                    Menu {
                        if store.hasActive {
                            Button("Pause All") { store.pauseAll() }
                        }
                        if store.pausedCount > 0 {
                            Button("Resume All") { store.resumeAll() }
                        }
                        if store.hasActive || store.pausedCount > 0 {
                            Divider()
                            Button("Cancel All", role: .destructive) { store.cancelAll() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }

                Button("Clear Finished") { store.clearFinished() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(store.downloads.allSatisfy { $0.state == .inProgress || $0.isPaused })
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Filters and grouping
            if !store.downloads.isEmpty {
                HStack(spacing: 8) {
                    // Search
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search Downloads…", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    // File type filter
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
                        Image(systemName: store.fileTypeFilter?.icon ?? "filter")
                            .foregroundStyle(store.fileTypeFilter != nil ? Color.accentColor : .secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 28)

                    // Grouping mode
                    Picker("Group by", selection: $store.groupingMode) {
                        Image(systemName: "calendar").tag(DownloadStore.GroupingMode.date)
                        Image(systemName: "doc").tag(DownloadStore.GroupingMode.fileType)
                        Image(systemName: "checkmark.circle").tag(DownloadStore.GroupingMode.status)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 90)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Divider()

            // Content
            if sections.isEmpty || sections.allSatisfy({ $0.1.isEmpty }) {
                EmptyState(message: searchText.isEmpty ? String(localized: "No Downloads") : String(localized: "No Matching Downloads"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections, id: \.0) { sectionTitle, items in
                            Section {
                                ForEach(items) { item in
                                    DownloadRow(item: item, store: store)
                                    if item.id != items.last?.id { Divider() }
                                }
                            } header: {
                                if sections.count > 1 {
                                    HStack {
                                        Text(sectionTitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(items.count)")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 480, height: 500)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject var store: DownloadStore

    var body: some View {
        HStack(spacing: 10) {
            // File type icon
            Image(systemName: item.fileType.icon)
                .foregroundStyle(colorForFileType(item.fileType))
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .lineLimit(1)
                    .font(.system(size: 13))

                if item.state == .inProgress && !item.isPaused {
                    // Progress bar
                    ProgressView(value: item.isIndeterminate ? nil : item.progress)
                        .frame(width: 200)

                    // Speed and time remaining
                    HStack(spacing: 6) {
                        if item.isIndeterminate {
                            Text("Downloading…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            if item.speed > 0 {
                                Text(formatSpeed(item.speed))
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                            }

                            Text("\(Int((item.progress * 100).rounded()))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let timeRemaining = item.estimatedTimeRemaining {
                                let formatted = formatTimeRemaining(timeRemaining)
                                if !formatted.isEmpty {
                                    Text("• \(formatted)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else if item.isPaused {
                    Text("Paused")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if item.state == .failed {
                    Text(item.error ?? String(localized: "Download Failed"))
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text(formatBytes(item.totalBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
            trailingButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(item.isPaused ? Color.orange.opacity(0.05) : Color.clear)
    }

    private func colorForFileType(_ type: DownloadItem.FileType) -> Color {
        switch type {
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
    private var trailingButtons: some View {
        if item.state == .inProgress {
            HStack(spacing: 8) {
                // Pause/Resume
                Button {
                    if item.isPaused {
                        store.resume(id: item.id)
                    } else {
                        store.pause(id: item.id)
                    }
                } label: {
                    Image(systemName: item.isPaused ? "play.fill" : "pause.fill")
                        .foregroundStyle(item.isPaused ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(item.isPaused ? "Resume" : "Pause")

                // Priority menu
                Menu {
                    Button("High Priority") {
                        store.setPriority(id: item.id, priority: .high)
                    }
                    Button("Normal Priority") {
                        store.setPriority(id: item.id, priority: .normal)
                    }
                    Button("Low Priority") {
                        store.setPriority(id: item.id, priority: .low)
                    }
                } label: {
                    Image(systemName: priorityIcon(item.priority))
                        .foregroundStyle(priorityColor(item.priority))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)

                // Cancel
                Button {
                    store.remove(id: item.id)
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }
        } else if item.state == .completed {
            HStack(spacing: 12) {
                Button { store.openFile(item) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }.buttonStyle(.plain).help("Open")
                Button { store.revealInFinder(item) } label: {
                    Image(systemName: "folder")
                }.buttonStyle(.plain).help("Show in Finder")
                Button { store.remove(id: item.id) } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Remove from List")
            }
            .foregroundStyle(.secondary)
        } else if item.state == .failed {
            HStack(spacing: 12) {
                Button { store.retry(item) } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.plain).help("Retry")
                Button { store.remove(id: item.id) } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func priorityIcon(_ priority: DownloadItem.Priority) -> String {
        switch priority {
        case .high: return "arrow.up.circle.fill"
        case .normal: return "arrow.right.circle"
        case .low: return "arrow.down.circle"
        }
    }

    private func priorityColor(_ priority: DownloadItem.Priority) -> Color {
        switch priority {
        case .high: return .red
        case .normal: return .secondary
        case .low: return .blue
        }
    }
}

#Preview {
    DownloadPanel(store: DownloadStore())
        .frame(width: 480, height: 500)
}