// axextras — 探/按 MenuBarExtra（状态栏）项与窗口内按钮。
//
// 用法：
//   axextras dump <pid>            打印 extras menu bar 子树 + 窗口列表（角色/标签）
//   axextras press <pid> <文本>    在 extras 子树与所有窗口中找标签含文本的元素并 AXPress
//
// 为什么单独一个工具：tools/axpress.swift 只走 kAXWindowsAttribute，而
// MenuBarExtra 的状态项在 kAXExtrasMenuBarAttribute 下（不在窗口树里）。
// 菜单栏弹窗（.window 风格）打开后是一个普通窗口，press 模式同样能命中其
// 内部按钮（如「Open Agent Panel」）。
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[2]) else {
    print("usage: axextras dump|press <pid> [text]")
    exit(2)
}
let mode = args[1]

func label(of el: AXUIElement) -> String {
    var out: [String] = []
    for attr in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute, kAXHelpAttribute] {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, attr as CFString, &v)
        if let s = v as? String, !s.isEmpty { out.append(s) }
    }
    return out.joined(separator: "|")
}

func role(of el: AXUIElement) -> String {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
    return (v as? String) ?? "?"
}

func children(of el: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v)
    return (v as? [AXUIElement]) ?? []
}

func walk(_ el: AXUIElement, depth: Int, maxDepth: Int, visit: (AXUIElement, Int) -> Bool) {
    guard depth <= maxDepth else { return }
    if visit(el, depth) { return }
    for k in children(of: el) { walk(k, depth: depth + 1, maxDepth: maxDepth, visit: visit) }
}

let app = AXUIElementCreateApplication(pid)

/// 目标根：extras menu bar + 所有窗口。
func roots() -> [(String, AXUIElement)] {
    var out: [(String, AXUIElement)] = []
    var extras: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) == .success,
       let raw = extras, CFGetTypeID(raw) == AXUIElementGetTypeID() {
        out.append(("extras", unsafeDowncast(raw, to: AXUIElement.self)))
    }
    var wins: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins) == .success,
       let ws = wins as? [AXUIElement] {
        for (i, w) in ws.enumerated() { out.append(("win\(i)[\(label(of: w))]", w)) }
    }
    return out
}

switch mode {
case "dump":
    for (name, root) in roots() {
        print("== \(name) role=\(role(of: root))")
        walk(root, depth: 0, maxDepth: 6) { el, depth in
            let r = role(of: el)
            let l = label(of: el)
            if !l.isEmpty || r.contains("Button") || r.contains("MenuBarItem") || r.contains("Window") || r.contains("Popover") || r.contains("Dialog") || r.contains("Group") {
                // 帧（屏幕坐标，左上原点）——排查"谁盖住谁"用。
                var frameNote = ""
                var pv: CFTypeRef?
                var sv: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv)
                AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv)
                if let pv, CFGetTypeID(pv) == AXValueGetTypeID(),
                   let sv, CFGetTypeID(sv) == AXValueGetTypeID() {
                    var pt = CGPoint.zero
                    var sz = CGSize.zero
                    AXValueGetValue(unsafeDowncast(pv, to: AXValue.self), .cgPoint, &pt)
                    AXValueGetValue(unsafeDowncast(sv, to: AXValue.self), .cgSize, &sz)
                    if sz.width > 0 { frameNote = String(format: " x=%.0f..%.0f y=%.0f", pt.x, pt.x + sz.width, pt.y) }
                }
                print(String(repeating: "  ", count: depth) + "\(r) [\(l)]\(frameNote)")
            }
            return false
        }
    }
case "press":
    guard args.count >= 4 else { print("press needs text"); exit(2) }
    let want = args[3]
    var target: AXUIElement?
    var hitPath = ""
    for (name, root) in roots() {
        if target != nil { break }
        walk(root, depth: 0, maxDepth: 14) { el, _ in
            if target != nil { return true }
            let r = role(of: el)
            let l = label(of: el)
            let interactive = r.contains("Button") || r.contains("MenuBarItem")
                || r.contains("Cell") || r.contains("CheckBox") || r.contains("Switch")
            if interactive, l.contains(want) {
                target = el
                hitPath = "\(name):\(r)[\(l)]"
                return true
            }
            return false
        }
    }
    guard let el = target else {
        print("not found: \(want)")
        exit(1)
    }
    let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
    print("press \(hitPath) -> \(err.rawValue)")
    exit(err == .success ? 0 : 1)
default:
    print("unknown mode \(mode)")
    exit(2)
}
