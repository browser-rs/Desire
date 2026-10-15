import AppKit
import Combine
import SwiftUI

/// 菜单栏快速入口的宿主（NSStatusItem + NSPopover）。
///
/// 为什么不用 SwiftUI 的 `MenuBarExtra`：实测（2026-10-15，本机 macOS 26/27）
/// 只要 `isInserted:` 是**动态绑定**（@AppStorage 或 @Published 都一样），本
/// 应用启动即进入无限图更新循环——主线程 100% CPU、`AppDelegate.makeMainMenu`
/// 被反复重建、自动化桥无响应；二分验证：同一场景去掉该绑定、或把场景整体
/// 移出 `body`，立刻恢复正常。NSStatusItem 不参与 SwiftUI 场景图，没有这个
/// 问题；而且弹窗能由代码收起（MenuBarExtra 做不到）——打开 Agent 面板前先
/// 收弹窗，key window 归还给浏览器窗口。
@MainActor
final class MenuBarQuickEntryController: ObservableObject {
    static let shared = MenuBarQuickEntryController()

    static let defaultsKey = "general.showMenuBarExtra"

    /// 图标是否在菜单栏（设置 › 通用 的开关；默认开）。
    @Published private(set) var isVisible: Bool

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var defaultsObserver: NSObjectProtocol?

    private init() {
        isVisible = (UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool) ?? true
    }

    /// 应用装配完成后调用（AppDelegate.applicationDidFinishLaunching）。
    func install() {
        // 外部写入也要跟上（桥/defaults 命令、其他窗口里的开关）。观察闭包
        // 是 @Sendable：不捕获 self（非 Sendable），经单例在主 actor 上取值。
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in MenuBarQuickEntryController.shared.syncFromDefaults() }
        }
        updateStatusItem()
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        UserDefaults.standard.set(visible, forKey: Self.defaultsKey)
        updateStatusItem()
    }

    private func syncFromDefaults() {
        let stored = (UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool) ?? true
        guard stored != isVisible else { return }
        isVisible = stored
        updateStatusItem()
    }

    private func updateStatusItem() {
        if isVisible {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = NSImage(
                    systemSymbolName: "sparkles", accessibilityDescription: "Desire")
                item.button?.target = self
                item.button?.action = #selector(togglePopover(_:))
                item.button?.sendAction(on: [.leftMouseUp])
                statusItem = item
            }
            statusItem?.isVisible = true
        } else {
            statusItem?.isVisible = false
            closePopover()
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover?.isShown == true { closePopover() } else { showPopover() }
    }

    func showPopover() {
        guard let button = statusItem?.button else { return }
        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(
                rootView: MenuBarQuickEntryView().appAccent(AppAccent.current)
            )
            self.popover = popover
        }
        NSApp.activate(ignoringOtherApps: true)
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // 让弹窗成为 key window，输入框才能直接接键盘（视图内 120ms 后置焦点）。
        popover?.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        popover?.performClose(nil)
    }
}
