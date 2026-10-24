import SwiftUI

/// 键盘快捷键速查表（v0.8.6 可发现性）：把 store 里的全部映射 + 少数
/// 硬编码键（⌘1-9 切标签、Esc）排成打印友好视图（⌘P 导出 PDF）。
/// 入口：设置 ▸ 键盘快捷键 ▸ Cheat Sheet。
struct ShortcutCheatSheetView: View {
    @ObservedObject var store: KeyboardShortcutStore
    @Environment(\.dismiss) private var dismiss

    /// 硬编码键（AppCommands 未走 store——如实标注，避免"列表缺项"）。
    private let hardcoded: [(String, String)] = [
        ("Switch to Tab 1-9", "⌘1 … ⌘9"),
        ("Exit fullscreen / stop page load", "Esc"),
        ("Send agent message", "⌘↩"),
        ("Find next / previous (page)", "⌘G / ⇧⌘G"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .foregroundStyle(.tint)
                Text("Keyboard Shortcuts")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    printSheet()
                } label: {
                    Label("Print", systemImage: "printer")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Print or save as PDF (⌘P)")
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ShortcutMapping.Category.allCases, id: \.rawValue) { category in
                        let items = store.shortcuts.filter { $0.category == category }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(category.rawValue, systemImage: category.icon)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(items) { mapping in
                                    row(mapping.commandName, ShortcutCheatSheetView.symbol(mapping))
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Built-in", systemImage: "bolt")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(hardcoded, id: \.0) { name, keys in
                            row(name, keys)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(width: 660, height: 640)
    }

    private func row(_ name: String, _ keys: String) -> some View {
        HStack {
            Text(name)
                .font(.system(size: 12))
            Spacer()
            Text(keys)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(keys.contains("Customized") ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    /// modifiers rawValue → 符号（与菜单栏同一符号体系）。
    static func symbol(_ mapping: ShortcutMapping) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: mapping.modifierFlags)
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        out += mapping.keyEquivalent.uppercased()
        return out
    }

    /// 打印/导出 PDF：把速查表挂进临时视图走系统打印面板。
    private func printSheet() {
        let view = NSHostingView(rootView: ShortcutCheatSheetView(store: store))
        view.frame = NSRect(x: 0, y: 0, width: 640, height: view.fittingSize.height + 32)
        let info = NSPrintInfo.shared
        info.verticalPagination = .automatic
        let op = NSPrintOperation(view: view, printInfo: info)
        _ = op.run()
    }
}
