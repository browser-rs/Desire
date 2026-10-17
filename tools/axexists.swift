import ApplicationServices
import Foundation
// axexists — 目标进程的 AX 树里是否存在含该子串的按钮/静态文本。
//
// 用法：axexists <pid> <label>   （存在 → exit 0 且打印 yes；否则 exit 1）
//
// 为什么存在：AX 驱动的测试要**幂等判断 UI 状态**（面板开没开、行在不在）
// 再决定按哪个键——盲按切换类按钮（如 DevTools 瓢虫）会把已开的面板关掉，
// 制造"时红时绿"的假象（v0.7.19 DPP 检查器验收时反复踩）。
let args = CommandLine.arguments
guard args.count == 3, let pid = Int32(args[1]) else { exit(2) }
let want = args[2]
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
var found = false
func walk(_ el: AXUIElement, _ d: Int) {
    guard d < 24, !found else { return }
    let r = role(el)
    if (r.contains("Button") || r == "AXStaticText"), title(el).contains(want) { found = true; return }
    for k in kids(el) { walk(k, d + 1) }
}
var w: CFTypeRef?
AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &w)
if let wins = w as? [AXUIElement] { for win in wins { walk(win, 0) } }
print(found ? "yes" : "no")
exit(found ? 0 : 1)
