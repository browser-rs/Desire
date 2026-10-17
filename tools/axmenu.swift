import ApplicationServices
import Foundation

// AX 驱动标签组菜单：axmenu <pid> <task> [args...]
// tasks: create <name> | collapse <groupName> | rename <oldName> <newName> | delete <groupName> | dump
let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[1]) else { print("usage"); exit(2) }
let task = args[2]
let app = AXUIElementCreateApplication(pid)

func role(_ el: AXUIElement) -> String {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
    return (v as? String) ?? "?"
}
func title(_ el: AXUIElement) -> String {
    for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let s = v as? String, !s.isEmpty { return s }
    }
    return ""
}
func kids(_ el: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
       let arr = v as? [AXUIElement] { return arr }
    return []
}
func findAll(_ root: AXUIElement, role want: String, contains: String? = nil, depth: Int = 0) -> [AXUIElement] {
    guard depth < 22 else { return [] }
    var out: [AXUIElement] = []
    if role(root) == want, contains == nil || title(root).contains(contains!) { out.append(root) }
    for k in kids(root) { out += findAll(k, role: want, contains: contains, depth: depth + 1) }
    return out
}
func perform(_ el: AXUIElement, _ action: String) -> AXError { AXUIElementPerformAction(el, action as CFString) }
func esc() {
    if let e = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true) { e.post(tap: .cghidEventTap) }
    if let e = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) { e.post(tap: .cghidEventTap) }
    Thread.sleep(forTimeInterval: 0.4)
}
func items() -> [AXUIElement] { findAll(app, role: "AXMenuItem") }
func pressItem(_ substr: String) -> Bool {
    for it in items() where title(it).contains(substr) {
        let e = perform(it, "AXPress")
        Thread.sleep(forTimeInterval: 0.7)
        if e == .success { print("pressed: \(title(it))"); return true }
    }
    print("not found: \(substr)")
    return false
}
// 打开胶囊/胶囊组 pill 的右键菜单：找滚动区里标题匹配的静态文本（带 AXShowMenu）
func showMenu(titled: String? = nil) -> Bool {
    var winsRef: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &winsRef)
    guard let wins = winsRef as? [AXUIElement], !wins.isEmpty else { print("no window"); return false }
    var pool: [AXUIElement] = []
    if titled == nil {
        // 普通胶囊 = 标签栏里的 AXStaticText（取第一个窗口的第一个）
        pool = findAll(wins[0], role: "AXStaticText")
    } else {
        // **跨全部窗口**（popover/面板是独立窗口——下载面板的行不在首窗里）。
        func collect(_ el: AXUIElement, _ depth: Int) {
            guard depth < 12 else { return }
            pool.append(el)
            for k in kids(el) { collect(k, depth + 1) }
        }
        for win in wins { collect(win, 0) }
    }
    for t in pool where !title(t).isEmpty {
        if let wanted = titled, !title(t).contains(wanted) { continue }
        var acts: CFArray?
        if AXUIElementCopyActionNames(t, &acts) == .success, let names = acts as? [String], names.contains("AXShowMenu") {
            _ = perform(t, "AXShowMenu")
            Thread.sleep(forTimeInterval: 0.9)
            return true
        }
    }
    print("no menu target (titled: \(titled ?? "*"))")
    return false
}
// alert sheet 填值 + 按按钮
func typeSheet(_ value: String, button: String) -> Bool {
    var sheet: AXUIElement?
    for _ in 0..<10 {
        if let s = findAll(app, role: "AXSheet").first { sheet = s; break }
        Thread.sleep(forTimeInterval: 0.3)
    }
    guard let sheet else { print("no sheet"); return false }
    guard let field = findAll(sheet, role: "AXTextField").first else { print("no field"); return false }
    let e = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFTypeRef)
    print("set field err=\(e.rawValue)")
    Thread.sleep(forTimeInterval: 0.4)
    for b in findAll(sheet, role: "AXButton") where title(b).contains(button) {
        _ = perform(b, "AXPress")
        Thread.sleep(forTimeInterval: 0.8)
        print("pressed button: \(title(b))")
        return true
    }
    print("button not found: \(button)；现有：", findAll(sheet, role: "AXButton").map { title($0) })
    return false
}

switch task {
case "dump":
    _ = showMenu()
    for it in items() { print("item:", title(it)) }
    esc()
case "create":
    esc()
    // 可选：第 4 参 = 目标胶囊标题子串（侧栏开启时第一个 AXStaticText 是侧栏行，
    // 建首个组必须指名顶栏胶囊）。
    let target = args.count > 4 ? args[4] : nil
    guard showMenu(titled: target), pressItem("添加到分组") || pressItem("Add to Group") else { exit(1) }
    guard pressItem("新建分组") || pressItem("New Group") else { exit(1) }
    guard typeSheet(args[3], button: "创建") || typeSheet(args[3], button: "Create") else { exit(1) }
case "collapse":
    esc()
    let target = args.count > 4 ? args[4] : nil
    guard showMenu(titled: target),
          pressItem("分组: \(args[3])") || pressItem("分组：\(args[3])") || pressItem("Group: \(args[3])")
    else { exit(1) }
    guard pressItem("折叠") || pressItem("Collapse") else { exit(1) }
case "rename":
    esc()
    // pill 是折叠组在标签栏的静态文本（标题 = 组名）——直接对它开菜单
    guard showMenu(titled: args[3]) else { exit(1) }
    guard pressItem("重命名分组") || pressItem("Rename Group") else { exit(1) }
    guard typeSheet(args[4], button: "重命名") || typeSheet(args[4], button: "Rename") else { exit(1) }
case "delete":
    esc()
    guard showMenu(titled: args[3]) else { exit(1) }
    guard pressItem("删除分组") || pressItem("Delete Group") else { exit(1) }
case "showmenu-press":
    // 通用：对标题含 args[3] 的元素开右键菜单，按标题含 args[4] 的条目 press。
    esc()
    guard showMenu(titled: args.count > 3 ? args[3] : nil) else { exit(1) }
    guard pressItem(args.count > 4 ? args[4] : "") else { exit(1) }
default:
    print("unknown task"); exit(2)
}
