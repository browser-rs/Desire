import AppKit
import SwiftUI

/// ⌘K command palette (0.1.16): one fuzzy entry point over every
/// BrowserCommand, the registered containers, and window controls. The
/// BrowserCommand enum IS the catalog — no parallel registry to drift.
struct CommandPalette: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    /// Runs a selected command through the same bus the menus use.
    let onRun: (BrowserCommand) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectedIndex = 0
    /// ↑/↓/enter arrive as NSEvents (the plain TextField swallows arrows in
    /// some focus states), so the palette owns a scoped key monitor.
    @State private var keyMonitor: Any?

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let command: BrowserCommand?

        static func == (a: Entry, b: Entry) -> Bool { a.id == b.id }
    }

    private var allEntries: [Entry] {
        [
            Entry(id: "cmd.newTab", title: "New Tab", subtitle: "File", icon: "plus.square.on.square", command: .newTab),
            Entry(id: "cmd.newIncognitoTab", title: "New Incognito Tab", subtitle: "File", icon: "mask", command: .newIncognitoTab),
            Entry(id: "cmd.newWindow", title: "New Window", subtitle: "File", icon: "macwindow.on.rectangle", command: .newWindow),
            Entry(id: "cmd.closeTab", title: "Close Tab", subtitle: "File", icon: "xmark.square", command: .closeTab),
            Entry(id: "cmd.reopenClosedTab", title: "Reopen Closed Tab", subtitle: "File", icon: "arrow.uturn.backward.square", command: .reopenClosedTab),
            Entry(id: "cmd.savePage", title: "Save Page", subtitle: "File", icon: "arrow.down.doc", command: .savePage),
            Entry(id: "cmd.printPage", title: "Print…", subtitle: "Tools", icon: "printer", command: .printPage),
            Entry(id: "cmd.reload", title: "Reload Page", subtitle: "View", icon: "arrow.clockwise", command: .reload),
            Entry(id: "cmd.forceReload", title: "Force Reload Page", subtitle: "View", icon: "arrow.clockwise.circle.fill", command: .forceReload),
            Entry(id: "cmd.zoomIn", title: "Zoom In", subtitle: "View", icon: "plus.magnifyingglass", command: .zoomIn),
            Entry(id: "cmd.zoomOut", title: "Zoom Out", subtitle: "View", icon: "minus.magnifyingglass", command: .zoomOut),
            Entry(id: "cmd.actualSize", title: "Actual Size", subtitle: "View", icon: "1.magnifyingglass", command: .actualSize),
            Entry(id: "cmd.toggleReader", title: "Reader View", subtitle: "View", icon: "doc.richtext", command: .toggleReader),
            Entry(id: "cmd.toggleResponsiveMode", title: "Responsive Design Mode", subtitle: "View", icon: "iphone.radiowaves.left.and.right", command: .toggleResponsiveMode),
            Entry(id: "cmd.inspectElement", title: "Inspect Element", subtitle: "Develop", icon: "scope", command: .inspectElement),
            Entry(id: "cmd.toggleFind", title: "Find in Page…", subtitle: "Edit", icon: "magnifyingglass", command: .toggleFind),
            Entry(id: "cmd.showHistory", title: "Show History", subtitle: "History", icon: "clock.arrow.circlepath", command: .showHistory),
            Entry(id: "cmd.clearHistory", title: "Clear History…", subtitle: "History", icon: "trash", command: .clearHistory),
            Entry(id: "cmd.showBookmarks", title: "Bookmarks Panel", subtitle: "Bookmarks", icon: "book", command: .showBookmarks),
            Entry(id: "cmd.bookmarkPage", title: "Add Bookmark", subtitle: "Bookmarks", icon: "bookmark", command: .bookmarkPage),
            Entry(id: "cmd.showDownloads", title: "Show Downloads", subtitle: "View", icon: "arrow.down.circle", command: .showDownloads),
            Entry(id: "cmd.showSettings", title: "Settings", subtitle: "App", icon: "gearshape", command: .showSettings),
            Entry(id: "cmd.showPlugins", title: "Plugins", subtitle: "Tools", icon: "puzzlepiece", command: .showPlugins),
            Entry(id: "cmd.showExtensions", title: "Extensions", subtitle: "Tools", icon: "puzzlepiece.extension", command: .showExtensions),
            Entry(id: "cmd.showElementBlock", title: "Element Blocker", subtitle: "Tools", icon: "eye.slash", command: .showElementBlock),
            Entry(id: "cmd.screenshot", title: "Screenshot Region…", subtitle: "Tools", icon: "camera.viewfinder", command: .screenshot),
            Entry(id: "cmd.toggleSidebar", title: "Toggle Sidebar", subtitle: "Tabs", icon: "sidebar.left", command: .toggleSidebar),
            Entry(id: "cmd.tabSearch", title: "Search Tabs", subtitle: "Tabs", icon: "rectangle.stack", command: .tabSearch),
            Entry(id: "cmd.toggleFullScreen", title: "Toggle Full Screen", subtitle: "View", icon: "arrow.up.left.and.arrow.down.right", command: .toggleFullScreen),
            Entry(id: "cmd.restoreArchivedSession", title: "Restore Archived Session…", subtitle: "Tools", icon: "clock.badge.checkmark", command: .restoreArchivedSession),
        ]
    }

    /// Subsequence fuzzy match: query chars appear in order (case-insensitive).
    private func matches(_ text: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        var textIndex = text.startIndex
        for q in query.lowercased() {
            guard let found = text[textIndex...].lowercased().firstIndex(of: q) else { return false }
            textIndex = text.index(after: found)
        }
        return true
    }

    private var filtered: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = allEntries
        guard !q.isEmpty else { return list }
        let ranked = list.filter {
            matches($0.title, query: q) || matches($0.subtitle, query: q)
        }
        // Simple ranking: prefix matches first, then alphabetical.
        return ranked.sorted {
            let a = $0.title.lowercased().hasPrefix(q.lowercased())
            let b = $1.title.lowercased().hasPrefix(q.lowercased())
            if a != b { return a }
            return $0.title < $1.title
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                Text("esc")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.icon)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(entry.title)
                                .font(.system(size: 13))
                            Spacer()
                            Text(entry.subtitle)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(index == selectedIndex ? appAccent.opacity(0.14) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering { selectedIndex = index }
                        }
                        .onTapGesture { run(entry) }
                    }
                    if filtered.isEmpty {
                        Text("No matching commands")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .frame(width: 520, height: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadowProminent()
        .onAppear {
            selectedIndex = 0
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                switch event.keyCode {
                case 125 where flags.isEmpty:      // down
                    selectedIndex = min(selectedIndex + 1, filtered.count - 1)
                    return nil
                case 126 where flags.isEmpty:      // up
                    selectedIndex = max(selectedIndex - 1, 0)
                    return nil
                case 36 where flags.isEmpty:       // return
                    if filtered.indices.contains(selectedIndex) {
                        run(filtered[selectedIndex])
                    }
                    return nil
                case 53:                            // esc
                    dismiss()
                    return nil
                default:
                    return event
                }
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            self.keyMonitor = nil
        }
    }

    private func run(_ entry: Entry) {
        guard let command = entry.command else { return }
        onRun(command)
        dismiss()
    }
}
