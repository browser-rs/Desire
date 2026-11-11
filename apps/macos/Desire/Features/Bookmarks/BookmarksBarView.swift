import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 常驻书签栏（v0.8.53 书签 2.0）：多级文件夹（递归子菜单）、拖拽排序
/// （拖到兄弟上 = 同层重排；拖到文件夹上 = 移入）、文件夹「打开全部」、
/// 中键后台打开、宽度不足收进「更多书签 ⌄」溢出。
/// 数据与书签面板/星标同源（BookmarkStore）；树形/容量逻辑在
/// `BookmarkBarTree`（纯逻辑，进 harness）。空书签时整条隐藏。
struct BookmarksBarView: View {
    @ObservedObject var store: BookmarkStore
    /// 导航回调（当前选中标签页）。
    let onNavigate: (String) -> Void
    /// 后台打开（中键 / 打开全部；v0.8.53）。
    var onNavigateBackground: ((String) -> Void)? = nil
    /// 右键菜单"隐藏书签栏"回调（0.2.19 可发现性补全）。
    var onToggleVisibility: (() -> Void)? = nil

    @Environment(\.appAccent) private var appAccent: Color
    /// 拖拽中的书签 id（onDrag 提供方；落到文件夹/兄弟行时消费）。
    @State private var draggingID: UUID?
    /// 每个可见节点的全局 frame（中键命中用）。
    @State private var rowFrames: [UUID: CGRect] = [:]
    /// 中键事件监视器（与 TabMiddleClickMonitor 同款模式）。
    @State private var middleClickMonitor: Any?

    var body: some View {
        let nodes = BookmarkBarTree.build(store.bookmarks)
        if !nodes.isEmpty {
            GeometryReader { geo in
                let split = BookmarkBarTree.split(nodes: nodes,
                                                  availableWidth: geo.size.width - 20)
                HStack(spacing: 2) {
                    ForEach(split.visible) { node in
                        nodeView(node)
                    }
                    if !split.overflow.isEmpty {
                        overflowMenu(split.overflow)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 26)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .overlay(alignment: .bottom) { Divider() }
            .contextMenu {
                Button("Hide Bookmarks Bar") { onToggleVisibility?() }
            }
            .onAppear { installMiddleClickMonitor() }
            .onDisappear { removeMiddleClickMonitor() }
        }
    }

    // MARK: - 节点视图（叶子 / 文件夹，含拖拽与中键）

    @ViewBuilder
    private func nodeView(_ node: BookmarkBarTree.Node) -> some View {
        Group {
            if node.isFolder {
                folderMenu(node)
            } else {
                leafButton(node)
            }
        }
        .background(rowFrameReporter(node))
        .onDrag {
            draggingID = node.id
            return NSItemProvider(object: NSString(string: node.id.uuidString))
        }
        .onDrop(of: [.text], delegate: BookmarkBarDropDelegate(
            target: node, store: store, draggingID: $draggingID))
    }

    /// 中键命中：把每行的全局 frame 上报进共享字典。
    private func rowFrameReporter(_ node: BookmarkBarTree.Node) -> some View {
        GeometryReader { geo in
            Color.clear.onAppear {
                rowFrames[node.id] = geo.frame(in: .global)
            }
            .onChange(of: geo.frame(in: .global)) { _, frame in
                rowFrames[node.id] = frame
            }
        }
        .frame(width: 0, height: 0)
    }

    private func leafButton(_ node: BookmarkBarTree.Node) -> some View {
        Button {
            if let url = node.url {
                onNavigate(url)
            }
        } label: {
            HStack(spacing: 4) {
                FaviconView(urlString: node.url ?? "", size: 12)
                Text(node.title)
                    .lineLimit(1)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(node.url ?? "")
    }

    /// 文件夹：递归子菜单（多级）+「打开全部」；子项可继续展开下级。
    private func folderMenu(_ node: BookmarkBarTree.Node) -> some View {
        Menu {
            ForEach(node.children) { child in
                childMenuEntry(child)
            }
            if node.leafCount > 1 {
                Divider()
                Button(String(localized: "Open All (\(node.leafCount))")) {
                    openAll(node)
                }
            }
        } label: {
            folderLabel(node)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// 子项递归：叶子 = 导航项；文件夹 = 递归子菜单（AnyView 擦除自引用）。
    @ViewBuilder
    private func childMenuEntry(_ child: BookmarkBarTree.Node) -> some View {
        if child.isFolder {
            if child.children.isEmpty {
                Text(child.title).foregroundStyle(.tertiary)
            } else {
                AnyView(Menu {
                    ForEach(child.children) { grand in
                        childMenuEntry(grand)
                    }
                    if child.leafCount > 1 {
                        Divider()
                        Button(String(localized: "Open All (\(child.leafCount))")) {
                            openAll(child)
                        }
                    }
                } label: {
                    Label(child.title, systemImage: "folder")
                })
            }
        } else if let url = child.url {
            Button(child.title) { onNavigate(url) }
        }
    }

    private func folderLabel(_ node: BookmarkBarTree.Node) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "folder")
                .font(.system(size: 10))
            Text(node.title)
                .lineLimit(1)
                .font(.system(size: 11))
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    /// 溢出菜单（宽度放不下的部分；递归形态与栏上文件夹一致）。
    private func overflowMenu(_ nodes: [BookmarkBarTree.Node]) -> some View {
        Menu {
            ForEach(nodes) { node in
                childMenuEntry(node)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                Text("More bookmarks")
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func openAll(_ node: BookmarkBarTree.Node) {
        let urls = BookmarkBarTree.leafURLs(node)
        guard !urls.isEmpty else { return }
        onNavigateBackground?(urls[0])
        for url in urls.dropFirst() {
            onNavigateBackground?(url)
        }
    }

    // MARK: - 中键后台打开（本地监视器 + 行 frame 命中）

    private func installMiddleClickMonitor() {
        guard middleClickMonitor == nil else { return }
        middleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            guard event.buttonNumber == 2, event.window === NSApp.keyWindow else { return event }
            let location = NSEvent.mouseLocation
            guard let hit = rowFrames.first(where: { $0.value.contains(location) }) else {
                return event
            }
            if let node = BookmarkBarTree.build(store.bookmarks).find(id: hit.key),
               let url = node.url {
                onNavigateBackground?(url)
                return nil // 已消费
            }
            return event
        }
    }

    private func removeMiddleClickMonitor() {
        if let middleClickMonitor { NSEvent.removeMonitor(middleClickMonitor) }
        middleClickMonitor = nil
    }
}

/// 树查找（栏视图专用小助手）。
private extension [BookmarkBarTree.Node] {
    func find(id: UUID) -> BookmarkBarTree.Node? {
        for node in self {
            if node.id == id { return node }
            if let found = node.children.find(id: id) { return found }
        }
        return nil
    }
}

/// 拖放目标：落到兄弟上 = 同层重排；落到文件夹上 = 移入该文件夹。
/// 跨层移动由视图按语义分别调 store.reorder / store.move(ids:toFolder:)。
struct BookmarkBarDropDelegate: DropDelegate {
    let target: BookmarkBarTree.Node
    let store: BookmarkStore
    @Binding var draggingID: UUID?

    func performDrop(info: DropInfo) -> Bool {
        guard draggingID != nil,
              let payload = info.itemProviders(for: [.text]).first else { return false }
        payload.loadObject(ofClass: NSString.self) { reading, _ in
            guard let str = reading as? String, let id = UUID(uuidString: str) else { return }
            Task { @MainActor in
                self.finishDrop(draggedID: id, target: target, store: store)
            }
        }
        draggingID = nil
        return true
    }

    @MainActor
    private func finishDrop(draggedID: UUID, target: BookmarkBarTree.Node, store: BookmarkStore) {
        guard draggedID != target.id, let dragged = store.find(id: draggedID) else { return }
        if target.isFolder {
            // 拖进文件夹：防自套（把文件夹拖进自己的子树）
            guard BookmarkBatchEdit.canMove(dragged, into: store.find(id: target.id)) else { return }
            store.move(ids: [draggedID], toFolder: target.id)
        } else {
            // 同层重排：目标行的兄弟层内，落点 = 目标的原始下标
            let parentID = store.parentID(of: target.id)
            let siblings: [Bookmark] = parentID.flatMap { store.find(id: $0)?.children } ?? store.bookmarks
            guard let targetIndex = siblings.firstIndex(where: { $0.id == target.id }) else { return }
            let sameParent = store.parentID(of: draggedID) == parentID
            // 从前往后挪时，摘除原位后目标下标左移一格
            let currentIndex = siblings.firstIndex(where: { $0.id == draggedID })
            let insertIndex = sameParent && currentIndex != nil && currentIndex! < targetIndex
                ? targetIndex - 1
                : targetIndex
            if sameParent {
                store.reorder(id: draggedID, toIndex: insertIndex)
            } else {
                // 跨层：先移入目标所在层，再重排到目标位
                store.move(ids: [draggedID], toFolder: parentID)
                store.reorder(id: draggedID, toIndex: insertIndex)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
