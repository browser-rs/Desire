// axmenu — 用无障碍树驱动**右键菜单与表单 sheet**（axpress 够不着的场景）。
//
// 用法：axmenu <pid> <task> [args…]
//   dump                        打开第一个胶囊的右键菜单并列出条目（探查用）
//   create <组名> [胶囊标题子串]   菜单→添加到分组→新建分组…→ sheet 填名→创建
//   collapse <组名> [胶囊标题子串] 菜单→(分组: 组名)→折叠分组
//   rename <旧组名> <新组名>      对「折叠胶囊/侧栏行」（标题=组名）开菜单→
//                                重命名分组…→ sheet 填名→重命名
//   delete <组名>                同上路径→删除分组
//
// 为什么存在：CGEvent.postToPid 的鼠标事件在 darwin 27 上不再被主窗消费
// （见 AGENTS.md），SwiftUI 层的右键菜单没有坐标注入路径。AX 路线：
// kAXShowMenuAction 打开菜单 → 全树找 AXMenuItem 按标题 AXPress →
// NSAlert 的 sheet 是原生控件（AXTextField 直接 SetAttributeValue 填值、
// AXButton AXPress 提交）。
//
// 三个实测坑（写新 task 前先读）：
// ① **菜单项标题是本地化后的文案**（"新建分组…" 而非 "New Group…"）——
//    别凭源码字符串写匹配；先 `dump` 看真实标题（全角/半角冒号都可能不同：
//    "分组: %@" 是半角冒号）。
// ② **子菜单项在子菜单被展开前不进 AX 树**——两级条目要先把父项 press
//    再找子项（本工具的 create/rename 都是这么走的）。
// ③ **折叠组胶囊是 AXButton（标题 '组名、数量'）**，普通胶囊是
//    AXStaticText——按角色写死会找不到；按标题子串 + AXShowMenu 动作名筛。
import ApplicationServices
import Foundation

let args = CommandLine.arguments
let pid = args.count > 1 ? Int32(args[1]) ?? 0 : 0
guard pid != 0, args.count >= 3 else {
    print("usage: axmenu <pid> <dump|create|collapse|rename|delete> [args…]")
    exit(2)
}
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
func perform(_ el: AXUIElement, _ action: String) -> AXError {
    AXUIElementPerformAction(el, action as CFString)
}
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
/// 打开右键菜单：`titled` = nil 时取标签栏第一个普通胶囊（AXStaticText），
/// 否则按标题子串找任意角色（折叠胶囊是 AXButton '组名、数量'）。
func showMenu(titled: String? = nil) -> Bool {
    var winsRef: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &winsRef)
    guard let wins = winsRef as? [AXUIElement], let win = wins.first else { print("no window"); return false }
    var pool: [AXUIElement] = []
    if titled == nil {
        pool = findAll(win, role: "AXStaticText")
    } else {
        func collect(_ el: AXUIElement, _ depth: Int) {
            guard depth < 12 else { return }
            pool.append(el)
            for k in kids(el) { collect(k, depth + 1) }
        }
        collect(win, 0)
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
/// NSAlert sheet：填文本 + 按按钮（标题子串匹配，等 sheet 出现最多 ~3s）。
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
    print("button not found: \(button)")
    return false
}

switch task {
case "dump":
    _ = showMenu()
    for it in items() { print("item:", title(it)) }
    esc()
case "create":
    esc()
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
    guard showMenu(titled: args[3]) else { exit(1) }
    guard pressItem("重命名分组") || pressItem("Rename Group") else { exit(1) }
    guard typeSheet(args[4], button: "重命名") || typeSheet(args[4], button: "Rename") else { exit(1) }
case "delete":
    esc()
    guard showMenu(titled: args[3]) else { exit(1) }
    guard pressItem("删除分组") || pressItem("Delete Group") else { exit(1) }
default:
    print("unknown task"); exit(2)
}
