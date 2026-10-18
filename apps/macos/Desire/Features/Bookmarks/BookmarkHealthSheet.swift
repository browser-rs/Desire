import SwiftUI

/// 书签死链清理向导（v0.7.21）：把 `BookmarkLinkChecker` 的巡检结果变成
/// **可勾选、可批量清理**的界面——死链默认全选，用户点头才删（走既有
/// `store.remove` 路径，删除显式推墓碑）；跨站重定向只列信息不动手。
/// 面板/工具/桥都不自动删，这里是唯一的清理出口。
struct BookmarkHealthSheet: View {
    @ObservedObject var store: BookmarkStore
    @ObservedObject var checker: BookmarkLinkChecker
    let onClose: () -> Void

    @State private var selectedURLs: Set<String> = []
    /// 本轮里已删除的 URL（结果快照不会自己缩，渲染时过滤掉）。
    @State private var removedURLs: Set<String> = []
    @State private var limit = 100
    @State private var didSeedSelection = false

    private var deadRows: [BookmarkLinkChecker.DeadLink] {
        checker.dead.filter { !removedURLs.contains($0.url) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Bookmark Health")
                    .font(.headline)
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }

            if checker.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(checker.checked), total: Double(max(checker.total, 1)))
                    Text("Checked \(checker.checked) / \(checker.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if checker.lastReportAt == nil {
                Text("Probe every bookmark (HEAD first, ranged GET fallback; 401/403 count as alive) and list dead links and cross-site redirects. Nothing is deleted until you confirm.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Limit")
                        .font(.callout)
                    Picker("Limit", selection: $limit) {
                        Text("50").tag(50)
                        Text("100").tag(100)
                        Text("200").tag(200)
                    }
                    .labelsHidden()
                    .frame(width: 80)
                    Spacer()
                    Button("Start Check") { startCheck() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                summarySection
                if !deadRows.isEmpty {
                    deadLinksSection
                }
                if !checker.redirected.isEmpty {
                    redirectedSection
                }
                HStack {
                    Button("Check Again") { startCheck() }
                    Spacer()
                    Button("Remove Selected (\(selectedURLs.count))", role: .destructive) {
                        removeSelected()
                    }
                    .disabled(selectedURLs.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .onAppear {
            seedSelectionIfNeeded()
        }
        .onChange(of: checker.lastReportAt) { _, _ in
            // 巡检完成（可能是向导外的工具/桥触发的）→ 默认全选死链一次。
            didSeedSelection = false
            seedSelectionIfNeeded()
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        let checked = checker.checked
        let deadCount = deadRows.count
        let redirectCount = checker.redirected.count
        return Text("Checked \(checked): \(deadCount) dead link(s), \(redirectCount) cross-site redirect(s). Nothing has been deleted.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var deadLinksSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Dead Links")
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                ForEach(deadRows, id: \.url) { row in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { selectedURLs.contains(row.url) },
                            set: { on in
                                if on { selectedURLs.insert(row.url) } else { selectedURLs.remove(row.url) }
                            }))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(row.title)
                                    .font(.system(size: 12.5))
                                    .lineLimit(1)
                                Text(row.reason)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.red.opacity(0.1)))
                            }
                            Text(row.url)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Open") {
                            if let url = URL(string: row.url) { NSWorkspace.shared.open(url) }
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 160)
        }
    }

    private var redirectedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Redirected (update manually — nothing is changed here)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(checker.redirected, id: \.url) { row in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                            Text(row.url + "  →  " + row.destination)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
        }
    }

    // MARK: - Actions

    private func startCheck() {
        removedURLs = []
        didSeedSelection = false
        BookmarkLinkChecker.shared.start(store: store, limit: limit, session: nil)
    }

    /// 结果一到就默认**全选死链**（用户取消勾选即可保留）；只播种一次，
    /// 用户取消过的条目不会被下次重算又勾上。
    private func seedSelectionIfNeeded() {
        guard !didSeedSelection, !checker.isRunning, checker.lastReportAt != nil else { return }
        didSeedSelection = true
        selectedURLs = Set(checker.dead.map(\.url)).subtracting(removedURLs)
    }

    private func removeSelected() {
        for url in selectedURLs {
            if let bookmark = store.find(url: url) {
                store.remove(bookmark)
            }
        }
        removedURLs.formUnion(selectedURLs)
        selectedURLs.removeAll()
    }
}
