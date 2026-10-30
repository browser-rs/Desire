import AppKit
import SwiftUI

/// 侧栏宽度约束与持久化（v0.8.27）。
enum ToolboxSidebarWidth {
    static let key = "toolbox.sidebarWidth"
    static let minimum: CGFloat = 180
    static let maximum: CGFloat = 380
    static let fallback: CGFloat = 232

    static func stored() -> CGFloat {
        let value = CGFloat(UserDefaults.standard.double(forKey: key))
        return value >= minimum && value <= maximum ? value : fallback
    }

    static func clamp(_ width: CGFloat) -> CGFloat {
        min(max(width, minimum), maximum)
    }

    static func save(_ width: CGFloat) {
        UserDefaults.standard.set(Double(width), forKey: key)
    }
}

/// 带环境注入的根视图包装（不用 AnyView，避免类型擦除导致子视图状态重置）。
struct ToolboxAccented<Content: View>: View {
    let color: Color
    let content: Content

    var body: some View {
        content.appAccent(color)
    }
}

/// 原生 NSSplitView 分栏（v0.8.27）：拖动交给 AppKit，SwiftUI 视图值不参与
/// 每一帧的重建（自绘 DragGesture 改 @State 会整页重排，实测残影/右侧闪烁）。
///
/// 两个 NSHostingView 关闭 sizingOptions——否则它们把 SwiftUI 的 fittingSize
/// 报给 NSSplitView，侧栏会被按内容高度裁切（顶部标题/搜索消失）。
struct ToolboxSplitView<Sidebar: View, Content: View>: NSViewRepresentable {
    @Environment(\.appAccent) private var appAccent: Color
    var sidebar: Sidebar
    var content: Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSplitView {
        let split = ToolboxNSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator

        let sidebarHost = NSHostingView(rootView: ToolboxAccented(color: appAccent, content: sidebar))
        let contentHost = NSHostingView(rootView: ToolboxAccented(color: appAccent, content: content))
        sidebarHost.sizingOptions = []
        contentHost.sizingOptions = []
        sidebarHost.translatesAutoresizingMaskIntoConstraints = true
        contentHost.translatesAutoresizingMaskIntoConstraints = true
        sidebarHost.autoresizingMask = [.height]
        contentHost.autoresizingMask = [.height, .width]
        split.addArrangedSubview(sidebarHost)
        split.addArrangedSubview(contentHost)

        context.coordinator.sidebarHost = sidebarHost
        context.coordinator.contentHost = contentHost
        context.coordinator.initialWidth = ToolboxSidebarWidth.stored()
        split.initialWidth = context.coordinator.initialWidth
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        context.coordinator.sidebarHost?.rootView = ToolboxAccented(color: appAccent, content: sidebar)
        context.coordinator.contentHost?.rootView = ToolboxAccented(color: appAccent, content: content)
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        var sidebarHost: NSHostingView<ToolboxAccented<Sidebar>>?
        var contentHost: NSHostingView<ToolboxAccented<Content>>?
        var initialWidth: CGFloat = ToolboxSidebarWidth.fallback
        private var saveTask: Task<Void, Never>?

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            ToolboxSidebarWidth.minimum
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                       ofSubviewAt dividerIndex: Int) -> CGFloat {
            ToolboxSidebarWidth.maximum
        }

        func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
            view === contentHost
        }

        /// 停手 0.35s 后落盘（拖动中不写 UserDefaults）。
        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let sidebarHost else { return }
            let width = sidebarHost.frame.width
            guard width >= ToolboxSidebarWidth.minimum else { return }
            saveTask?.cancel()
            saveTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                ToolboxSidebarWidth.save(ToolboxSidebarWidth.clamp(width))
            }
        }
    }
}

private final class ToolboxNSSplitView: NSSplitView {
    var initialWidth: CGFloat = ToolboxSidebarWidth.fallback
    private var appliedInitial = false

    override func layout() {
        super.layout()
        guard !appliedInitial, bounds.width > 0, subviews.count >= 2 else { return }
        appliedInitial = true
        let width = ToolboxSidebarWidth.clamp(initialWidth)
        // 下一拍再设：当前 layout 收尾时 NSSplitView 还会 adjustSubviews 一次。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.bounds.width > 0 else { return }
            self.setPosition(width, ofDividerAt: 0)
        }
    }
}
