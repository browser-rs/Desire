import AppKit
import Foundation

/// A keyboard-shortcut binding persisted by `KeyboardShortcutStore`.
///
/// `modifierFlags` stores `NSEvent.ModifierFlags.rawValue`, so this Model
/// imports AppKit (the rest of the type is pure data).
struct ShortcutMapping: Codable, Identifiable, Equatable {
    let id: String
    var commandName: String
    var keyEquivalent: String
    var modifierFlags: UInt
    var isCustomized: Bool
    var category: Category

    enum Category: String, Codable, CaseIterable {
        case tabs = "Tabs"
        case navigation = "Navigation"
        case view = "View"
        case tools = "Tools"
        case panels = "Panels"
        case other = "Other"

        var icon: String {
            switch self {
            case .tabs: return "rectangle.stack"
            case .navigation: return "arrow.left.arrow.right"
            case .view: return "eye"
            case .tools: return "wrench.and.screwdriver"
            case .panels: return "sidebar.left"
            case .other: return "gearshape"
            }
        }
    }

    static let defaults: [ShortcutMapping] = {
        let cmd = NSEvent.ModifierFlags.command.rawValue
        let shift = NSEvent.ModifierFlags.shift.rawValue
        let opt = NSEvent.ModifierFlags.option.rawValue
        let ctrl = NSEvent.ModifierFlags.control.rawValue
        return [
            // Tabs
            ShortcutMapping(id: "newWindow", commandName: "New Window", keyEquivalent: "n", modifierFlags: cmd, isCustomized: false, category: .tabs),
            ShortcutMapping(id: "newTab", commandName: "New Tab", keyEquivalent: "t", modifierFlags: cmd, isCustomized: false, category: .tabs),
            ShortcutMapping(id: "newIncognitoTab", commandName: "New Incognito Tab", keyEquivalent: "n", modifierFlags: cmd | shift, isCustomized: false, category: .tabs),
            ShortcutMapping(id: "closeTab", commandName: "Close Tab", keyEquivalent: "w", modifierFlags: cmd, isCustomized: false, category: .tabs),
            ShortcutMapping(id: "reopenClosedTab", commandName: "Reopen Closed Tab", keyEquivalent: "t", modifierFlags: cmd | shift, isCustomized: false, category: .tabs),
            ShortcutMapping(id: "nextTab", commandName: "Next Tab", keyEquivalent: "]", modifierFlags: cmd | shift, isCustomized: false, category: .tabs),
            ShortcutMapping(id: "previousTab", commandName: "Previous Tab", keyEquivalent: "[", modifierFlags: cmd | shift, isCustomized: false, category: .tabs),
            ShortcutMapping(id: "tabSearch", commandName: "Search Tabs", keyEquivalent: "\\", modifierFlags: cmd, isCustomized: false, category: .tabs),

            // Navigation
            ShortcutMapping(id: "goBack", commandName: "Go Back", keyEquivalent: "[", modifierFlags: cmd, isCustomized: false, category: .navigation),
            ShortcutMapping(id: "goForward", commandName: "Go Forward", keyEquivalent: "]", modifierFlags: cmd, isCustomized: false, category: .navigation),
            ShortcutMapping(id: "reload", commandName: "Reload", keyEquivalent: "r", modifierFlags: cmd, isCustomized: false, category: .navigation),
            ShortcutMapping(id: "forceReload", commandName: "Force Reload", keyEquivalent: "r", modifierFlags: cmd | shift, isCustomized: false, category: .navigation),
            ShortcutMapping(id: "focusAddressBar", commandName: "Focus Address Bar", keyEquivalent: "l", modifierFlags: cmd, isCustomized: false, category: .navigation),

            // View
            ShortcutMapping(id: "zoomIn", commandName: "Zoom In", keyEquivalent: "=", modifierFlags: cmd, isCustomized: false, category: .view),
            ShortcutMapping(id: "zoomOut", commandName: "Zoom Out", keyEquivalent: "-", modifierFlags: cmd, isCustomized: false, category: .view),
            ShortcutMapping(id: "resetZoom", commandName: "Reset Zoom", keyEquivalent: "0", modifierFlags: cmd, isCustomized: false, category: .view),
            ShortcutMapping(id: "toggleSidebar", commandName: "Toggle Sidebar", keyEquivalent: "b", modifierFlags: cmd | shift, isCustomized: false, category: .view),
            ShortcutMapping(id: "toggleFullScreen", commandName: "Toggle Full Screen", keyEquivalent: "f", modifierFlags: ctrl | cmd, isCustomized: false, category: .view),
            ShortcutMapping(id: "responsiveMode", commandName: "Responsive Design Mode", keyEquivalent: "m", modifierFlags: cmd | shift, isCustomized: false, category: .view),

            // Tools
            ShortcutMapping(id: "findInPage", commandName: "Find in Page", keyEquivalent: "f", modifierFlags: cmd, isCustomized: false, category: .tools),
            ShortcutMapping(id: "findNext", commandName: "Find Next", keyEquivalent: "g", modifierFlags: cmd, isCustomized: false, category: .tools),
            ShortcutMapping(id: "findPrevious", commandName: "Find Previous", keyEquivalent: "g", modifierFlags: cmd | shift, isCustomized: false, category: .tools),
            ShortcutMapping(id: "inspectElement", commandName: "Inspect Element", keyEquivalent: "i", modifierFlags: cmd | shift, isCustomized: false, category: .tools),
            ShortcutMapping(id: "screenshot", commandName: "Screenshot Region", keyEquivalent: "5", modifierFlags: cmd | shift, isCustomized: false, category: .tools),
            ShortcutMapping(id: "print", commandName: "Print", keyEquivalent: "p", modifierFlags: cmd, isCustomized: false, category: .tools),
            ShortcutMapping(id: "savePage", commandName: "Save Page", keyEquivalent: "s", modifierFlags: cmd, isCustomized: false, category: .tools),

            // Panels
            ShortcutMapping(id: "showHistory", commandName: "Show History", keyEquivalent: "y", modifierFlags: cmd, isCustomized: false, category: .panels),
            ShortcutMapping(id: "showDownloads", commandName: "Show Downloads", keyEquivalent: "j", modifierFlags: cmd, isCustomized: false, category: .panels),
            ShortcutMapping(id: "showBookmarks", commandName: "Show Bookmarks", keyEquivalent: "b", modifierFlags: cmd, isCustomized: false, category: .panels),
            ShortcutMapping(id: "toggleAgentPanel", commandName: "Toggle AI Panel", keyEquivalent: "'", modifierFlags: cmd, isCustomized: false, category: .panels),
            ShortcutMapping(id: "bookmarkPage", commandName: "Add Bookmark", keyEquivalent: "d", modifierFlags: cmd, isCustomized: false, category: .panels),
            ShortcutMapping(id: "settings", commandName: "Settings", keyEquivalent: ",", modifierFlags: cmd, isCustomized: false, category: .panels),
        ]
    }()

    var modifierDescription: String {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        if flags.contains(.command) { parts.append("⌘") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.control) { parts.append("⌃") }
        return parts.joined()
    }

    var displayText: String {
        "\(modifierDescription)\(keyEquivalent.uppercased())"
    }
}
