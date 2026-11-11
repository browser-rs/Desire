// axmenupress — 在目标进程的菜单栏里按标题找到菜单项并 AXPress。
//
// 用法：axmenupress <pid> <标题包含的文本> [--dump]
// 返回 0 = 已派发 AXPress；--dump 只打印菜单树（调试用）。
//
// 为什么不用 System Events：AGENTS 明令禁止（多 Space 会切空间、误注入前台
// 应用）；AX 走无障碍树，不碰坐标与焦点。菜单项即使菜单未展开也存在于 AX
// 树中，AXPress 会直接执行动作（SwiftUI Commands 同样适用）。
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[1]) else {
    print("usage: axmenupress <pid> <title-substring> [--dump]")
    exit(2)
}
let want = args[2]
let dumpOnly = args.contains("--dump")
let app = AXUIElementCreateApplication(pid)

func attr(_ el: AXUIElement, _ key: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success else { return nil }
    return v
}

func text(_ el: AXUIElement) -> String {
    for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
        if let s = attr(el, key) as? String, !s.isEmpty { return s }
    }
    return ""
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

var pressed: AXUIElement?
var dumped: [String] = []

func walk(_ el: AXUIElement, depth: Int) {
    guard depth < 12 else { return }
    let title = text(el)
    let role = (attr(el, kAXRoleAttribute as String) as? String) ?? "?"
    if dumpOnly, !title.isEmpty {
        dumped.append(String(repeating: "  ", count: depth) + "\(role): \(title)")
    }
    if !dumpOnly, role == "AXMenuItem" || role == "AXMenuBarItem" || role == "AXButton" {
        if title.localizedCaseInsensitiveContains(want), pressed == nil {
            pressed = el
        }
    }
    for child in children(el) { walk(child, depth: depth + 1) }
}

if let raw = attr(app, kAXMenuBarAttribute as String) {
    walk(raw as! AXUIElement, depth: 0)
}
if dumpOnly {
    print(dumped.joined(separator: "\n"))
    exit(0)
}
guard let target = pressed else {
    print("not found: \(want)")
    exit(3)
}
let error = AXUIElementPerformAction(target, kAXPressAction as CFString)
print(error == .success ? "pressed: \(text(target))" : "press failed: \(error.rawValue)")
exit(error == .success ? 0 : 4)
