import AppKit
import SwiftUI

/// 工具集侧栏的宽度约束与持久化（v0.8.27）。
enum ToolboxSidebarWidth {
    static let key = "toolbox.sidebarWidth"
    static let minimum: CGFloat = 180
    static let maximum: CGFloat = 380
    static let fallback: CGFloat = 232

    static func stored() -> CGFloat {
        let value = CGFloat(UserDefaults.standard.double(forKey: key))
        return value >= minimum && value <= maximum ? value : fallback
    }

    static func clamp(_ width: CGFloat, available: CGFloat) -> CGFloat {
        // 内容至少留 360pt；窗口极窄时也不能低于最小宽度。
        let contentLimited = max(minimum, available - 360 - 1)
        return min(max(width, minimum), min(maximum, contentLimited))
    }

    static func save(_ width: CGFloat) {
        UserDefaults.standard.set(Double(width), forKey: key)
    }
}

/// 带环境注入的根视图包装：避免用 AnyView 擦除类型（父视图更新时
/// 子视图状态会被重置，例如收藏切换会清掉输入框内容）。
struct ToolboxAccented<Content: View>: View {
    let color: Color
    let content: Content

    var body: some View {
        content.appAccent(color)
    }
}

/// 原生 NSSplitView 分栏（v0.8.27）：侧栏拖动交给 AppKit。
/// 自绘 SwiftUI 拖拽会每帧改写 @State → 整页（含表格/编辑器）重建，实测
/// 闪屏且不跟手；这里拖动期间 SwiftUI 视图值不重建，只有布局帧变化。
struct ToolboxSplitView<Sidebar: View, Content: View>: NSViewRepresentable {
    @Environment(\.appAccent) private var appAccent: Color
    var sidebar: Sidebar
    var content: Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator

        let sidebarHost = NSHostingView(rootView: ToolboxAccented(color: appAccent, content: sidebar))
        let contentHost = NSHostingView(rootView: ToolboxAccented(color: appAccent, content: content))
        sidebarHost.translatesAutoresizingMaskIntoConstraints = true
        contentHost.translatesAutoresizingMaskIntoConstraints = true
        split.addArrangedSubview(sidebarHost)
        split.addArrangedSubview(contentHost)

        context.coordinator.sidebarHost = sidebarHost
        context.coordinator.contentHost = contentHost
        context.coordinator.initialWidth = ToolboxSidebarWidth.stored()

        // 首帧布局完成后再落初始分栏位置（此时 bounds 有效）。
        DispatchQueue.main.async {
            guard split.subviews.count >= 2, split.bounds.width > 0 else { return }
            let width = ToolboxSidebarWidth.clamp(context.coordinator.initialWidth,
                                                  available: split.bounds.width)
            split.setPosition(width, ofDividerAt: 0)
        }
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        // 强调色等环境值变化时刷新两个宿主视图；普通拖动不经过这里。
        context.coordinator.sidebarHost?.rootView = ToolboxAccented(color: appAccent, content: sidebar)
        context.coordinator.contentHost?.rootView = ToolboxAccented(color: appAccent, content: content)
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        var sidebarHost: NSHostingView<ToolboxAccented<Sidebar>>?
        var contentHost: NSHostingView<ToolboxAccented<Content>>?
        var initialWidth: CGFloat = ToolboxSidebarWidth.fallback
        private var saveTask: Task<Void, Never>?

        /// 窗口缩放：侧栏保持当前宽度，内容吃掉剩余空间（夹在 180–380）。
        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            guard let sidebarHost, let contentHost else { return }
            let available = splitView.bounds.width
            let current = sidebarHost.frame.width > 0 ? sidebarHost.frame.width : initialWidth
            let width = ToolboxSidebarWidth.clamp(current, available: available)
            let divider = splitView.dividerThickness
            sidebarHost.frame = NSRect(x: 0, y: 0, width: width, height: splitView.bounds.height)
            contentHost.frame = NSRect(x: width + divider, y: 0,
                                       width: max(0, available - width - divider),
                                       height: splitView.bounds.height)
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            ToolboxSidebarWidth.minimum
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            ToolboxSidebarWidth.clamp(proposedMaximumPosition, available: splitView.bounds.width)
        }

        func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
            view === contentHost
        }

        /// 拖动结束（或窗口缩放）后 0.35s 落盘——拖动中不写 UserDefaults。
        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let sidebarHost else { return }
            let width = sidebarHost.frame.width
            guard width >= ToolboxSidebarWidth.minimum else { return }
            saveTask?.cancel()
            saveTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                ToolboxSidebarWidth.save(width)
            }
        }
    }
}
