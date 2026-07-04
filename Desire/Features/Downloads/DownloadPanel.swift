import SwiftUI

struct DownloadPanel: View {
    @ObservedObject var store: DownloadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear Finished") { store.clearFinished() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(store.downloads.allSatisfy { $0.state == .inProgress })
            }
            .padding(12)

            Divider()

            if store.downloads.isEmpty {
                EmptyState(message: String(localized: "No Downloads"))
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.downloads) { item in
                            DownloadRow(item: item, store: store)
                            if item.id != store.downloads.last?.id { Divider() }
                        }
                    }
                }
            }
        }
        .frame(width: 420, height: 420)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    @ObservedObject var store: DownloadStore

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .lineLimit(1)
                    .font(.system(size: 13))
                if item.state == .inProgress {
                    ProgressView(value: item.isIndeterminate ? nil : item.progress)
                        .frame(width: 240)
                    HStack(spacing: 4) {
                        if item.isIndeterminate {
                            Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("\(formatBytes(item.downloadedBytes)) / \(formatBytes(item.totalBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(verbatim: "· \(Int((item.progress * 100).rounded()))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.state {
        case .inProgress:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(Color.accentColor)
                .font(.title3)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.title3)
        }
    }

    @ViewBuilder
    private var trailingButtons: some View {
        switch item.state {
        case .inProgress:
            Button {
                store.remove(id: item.id)
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        case .completed:
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
        case .failed:
            Button { store.remove(id: item.id) } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    DownloadPanel(store: DownloadStore())
        .frame(width: 420, height: 400)
}
