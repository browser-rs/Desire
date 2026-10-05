// axpress — 按名称按下目标进程里的 AX 按钮（SwiftUI/Button 均可）。
//
// 用法：axpress <pid> <按钮名包含的文本>
// 返回 0 = AXPress 已派发（AXError.success）。
//
// 为什么存在：CGEvent.postToPid 的鼠标事件在 darwin 27 上不再被主窗消费
// （2026-10-06 实测，warp + 三种坐标/源变体均无效，见 AGENTS.md 自动化一节），
// SwiftUI 层的点击驱动改走无障碍树：不碰坐标、不碰光标、不需要屏幕录制权限。
// 前提：调用方所在终端已授予「辅助功能」权限。
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count == 3, let pid = Int32(args[1]) else {
    print("usage: axpress <pid> <button-name-substring>")
    exit(2)
}
let want = args[2]
var found: AXUIElement?
var depth = 0

func label(of el: AXUIElement) -> String {
    var out: [String] = []
    for attr in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, attr as CFString, &v)
        if let s = v as? String { out.append(s) }
    }
    return out.joined(separator: "|")
}

func walk(_ el: AXUIElement) {
    guard found == nil, depth < 14 else { return }
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
    if let r = role as? String, r.contains("Button"), label(of: el).contains(want) {
        found = el
        return
    }
    var kids: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids)
    if let arr = kids as? [AXUIElement] {
        depth += 1
        for k in arr { walk(k) }
        depth -= 1
    }
}

let app = AXUIElementCreateApplication(pid)
var wins: CFTypeRef?
AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins)
guard let ws = wins as? [AXUIElement], !ws.isEmpty else {
    print("no ax windows for pid \(pid)")
    exit(1)
}
for w in ws {
    walk(w)
    if found != nil { break }
}
guard let btn = found else {
    print("button not found: \(want)")
    exit(1)
}
let err = AXUIElementPerformAction(btn, kAXPressAction as CFString)
print("press: \(err.rawValue)")
exit(err == .success ? 0 : 1)
