import ApplicationServices
import Foundation
// axpress-near — 按「与锚点同名按钮**同一行**且最近」的目标按钮。
//
// 用法：axpress-near <pid> <targetLabel> <anchorLabel>
//
// 为什么存在：axpress 按标签子串取**树序第一个**——工具栏与 DevTools 页签上
// 常有两个同名按钮（实测两个 "DPP"），盲取经常按错（按到工具栏的会弹设置）。
// 这里先用**同行约束**（|Δy| ≤ 14）把候选压到锚点所在行（如页签条以
// "控制台" 为锚），再取最近的一个。
let args = CommandLine.arguments
guard args.count == 4, let pid = Int32(args[1]) else { print("usage: axpress-near <pid> <target> <anchor>"); exit(2) }
let want = args[2], anchorLabel = args[3]
let app = AXUIElementCreateApplication(pid)
func role(_ el: AXUIElement) -> String { var v: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v); return (v as? String) ?? "?" }
func title(_ el: AXUIElement) -> String {
    for a in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, a as CFString, &v) == .success, let s = v as? String, !s.isEmpty { return s }
    }
    return ""
}
func kids(_ el: AXUIElement) -> [AXUIElement] { var v: CFTypeRef?; if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success, let a = v as? [AXUIElement] { return a }; return [] }
func pos(_ el: AXUIElement) -> CGPoint {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &v)
    var p = CGPoint.zero
    if let value = v { AXValueGetValue(value as! AXValue, .cgPoint, &p) }
    return p
}
var anchor: CGPoint?
var targets: [(AXUIElement, CGPoint)] = []
func walk(_ el: AXUIElement, _ d: Int) {
    guard d < 24 else { return }
    if role(el).contains("Button") {
        let t = title(el)
        if t.contains(want) { targets.append((el, pos(el))) }
        if t.contains(anchorLabel), anchor == nil { anchor = pos(el) }
    }
    for k in kids(el) { walk(k, d + 1) }
}
var w: CFTypeRef?
AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &w)
if let wins = w as? [AXUIElement] { for win in wins { walk(win, 0) } }
guard let anchorPoint = anchor else { print("anchor not found: \(anchorLabel)"); exit(1) }
// **同行约束**：先只在与锚点同一行（|Δy| ≤ 14）的目标里选——工具条与面板页签
// 常有同名按钮（两个 DPP），不同行的一律排除。
let sameRow = targets.filter { abs($0.1.y - anchorPoint.y) <= 14 }
let pool = sameRow.isEmpty ? targets : sameRow
guard let pick = pool.min(by: { a, b in
    let da = hypot(a.1.x - anchorPoint.x, a.1.y - anchorPoint.y)
    let db = hypot(b.1.x - anchorPoint.x, b.1.y - anchorPoint.y)
    return da < db
}) else { print("target not found: \(want)"); exit(1) }
let err = AXUIElementPerformAction(pick.0, kAXPressAction as CFString)
print("press: \(err.rawValue) at (\(Int(pick.1.x)),\(Int(pick.1.y))) '\(title(pick.0))'")
