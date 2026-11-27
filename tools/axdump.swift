import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[1]) else {
    print("usage: axdump <pid> <window-title-contains> [maxDepth]")
    exit(2)
}
let want = args[2]
let maxDepth = args.count > 3 ? Int(args[3]) ?? 12 : 12
let app = AXUIElementCreateApplication(pid)

func attr(_ el: AXUIElement, _ key: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success else { return nil }
    return v
}
func str(_ el: AXUIElement, _ key: String) -> String {
    (attr(el, key) as? String) ?? ""
}
func children(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

var matched: AXUIElement?
if let windows = attr(app, kAXWindowsAttribute as String) as? [AXUIElement] {
    if want.hasPrefix("#"), let idx = Int(want.dropFirst()), windows.indices.contains(idx) {
        matched = windows[idx]
    } else {
        for w in windows {
            let title = str(w, kAXTitleAttribute as String)
            if title.localizedCaseInsensitiveContains(want) { matched = w; break }
        }
    }
}
guard let root = matched else {
    print("no window matching \(want)")
    if let windows = attr(app, kAXWindowsAttribute as String) as? [AXUIElement] {
        for w in windows { print("window:", str(w, kAXTitleAttribute as String)) }
    }
    exit(1)
}

var lines: [String] = []
func walk(_ el: AXUIElement, depth: Int) {
    if depth > maxDepth { return }
    let role = str(el, kAXRoleAttribute as String)
    let subrole = str(el, kAXSubroleAttribute as String)
    let title = str(el, kAXTitleAttribute as String)
    let desc = str(el, kAXDescriptionAttribute as String)
    let value = str(el, kAXValueAttribute as String)
    let help = str(el, kAXHelpAttribute as String)
    let ident = str(el, kAXIdentifierAttribute as String)
    var parts = [String](repeating: "  ", count: depth).joined() + role
    if !subrole.isEmpty { parts += "/\(subrole)" }
    if !title.isEmpty { parts += " title=\(title)" }
    if !desc.isEmpty { parts += " desc=\(desc)" }
    if !value.isEmpty { parts += " value=\(value.prefix(80))" }
    if !help.isEmpty { parts += " help=\(help)" }
    if !ident.isEmpty { parts += " id=\(ident)" }
    lines.append(parts)
    for child in children(el) { walk(child, depth: depth + 1) }
}
walk(root, depth: 0)
print(lines.joined(separator: "\n"))
