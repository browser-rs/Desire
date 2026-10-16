import AppKit

/// 标签组的新建/重命名输入入口（v0.7.18 UI 收口）：NSAlert + 附件文本框
/// sheet（R2-15：beginSheetModal 异步，不用 runModal 冻结 app）。顶部标签栏
/// 的胶囊右键、侧栏的两处菜单与「新建组」共用它——输入路径统一为一条，改完
/// 由调用方回写 `TabGroupStore`（store 仍由窗口持有）。
@MainActor
enum TabGroupPrompts {
    /// sheet 的宿主窗口。**后台运行时 `keyWindow`/`mainWindow` 都是 nil**
    /// （AX/自动化桥驱动、菜单栏流程都可能在后台触发）——此前直接 return，
    /// 提示静默不出现（AX 驱动"新建分组"时照出的真 bug）。退到任一可见的
    /// 常规窗口：sheet 挂得住，不抢焦点也不挡流程。
    static func hostWindow() -> NSWindow? {
        if let w = NSApp.keyWindow ?? NSApp.mainWindow { return w }
        return NSApp.windows.first {
            $0.isVisible && $0.contentView != nil && $0.sheetParent == nil && $0.frame.width > 300
        }
    }

    /// 组名输入 sheet。`titleKey` 区分新建（New Tab Group）与重命名
    /// （Rename Tab Group）；`confirmKey` 是对应按钮（Create / Rename）。
    static func presentNameSheet(titleKey: String,
                                 initialName: String,
                                 confirmKey: String,
                                 onConfirm: @escaping (String) -> Void) {
        let alert = NSAlert()
        // 标题与"新建组"对仗（New Tab Group ↔ Rename Tab Group）；菜单项叫
        // "Rename Group…"。两者不能只差一个省略号——Xcode 的符号生成会把
        // "Rename Group…" 归一到 "Rename Group"，同键即报编译错（已踩）。
        alert.messageText = String(localized: String.LocalizationValue(titleKey))
        alert.informativeText = String(localized: "Enter group name")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        field.stringValue = initialName
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: String.LocalizationValue(confirmKey)))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window = hostWindow() else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            onConfirm(name)
        }
    }

    static func presentRename(group: TabGroup, onRename: @escaping (String) -> Void) {
        presentNameSheet(titleKey: "Rename Tab Group",
                         initialName: group.name,
                         confirmKey: "Rename") { newName in
            onRename(newName)
        }
    }
}
