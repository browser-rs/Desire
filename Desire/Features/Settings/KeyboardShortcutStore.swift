import AppKit
import Combine
import Foundation

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
        return [
            // Tabs
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
            ShortcutMapping(id: "toggleFullScreen", commandName: "Toggle Full Screen", keyEquivalent: "f", modifierFlags: cmd | shift, isCustomized: false, category: .view),
            ShortcutMapping(id: "responsiveMode", commandName: "Responsive Design Mode", keyEquivalent: "m", modifierFlags: cmd | shift, isCustomized: false, category: .view),

            // Tools
            ShortcutMapping(id: "findInPage", commandName: "Find in Page", keyEquivalent: "f", modifierFlags: cmd, isCustomized: false, category: .tools),
            ShortcutMapping(id: "inspectElement", commandName: "Inspect Element", keyEquivalent: "i", modifierFlags: cmd | shift, isCustomized: false, category: .tools),
            ShortcutMapping(id: "screenshot", commandName: "Screenshot Region", keyEquivalent: "5", modifierFlags: cmd | shift, isCustomized: false, category: .tools),
            ShortcutMapping(id: "print", commandName: "Print", keyEquivalent: "p", modifierFlags: cmd, isCustomized: false, category: .tools),
            ShortcutMapping(id: "savePage", commandName: "Save Page", keyEquivalent: "s", modifierFlags: cmd, isCustomized: false, category: .tools),

            // Panels
            ShortcutMapping(id: "showHistory", commandName: "Show History", keyEquivalent: "y", modifierFlags: cmd, isCustomized: false, category: .panels),
            ShortcutMapping(id: "showDownloads", commandName: "Show Downloads", keyEquivalent: "j", modifierFlags: cmd, isCustomized: false, category: .panels),
            ShortcutMapping(id: "showBookmarks", commandName: "Show Bookmarks", keyEquivalent: "b", modifierFlags: cmd, isCustomized: false, category: .panels),
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

@MainActor
class KeyboardShortcutStore: ObservableObject {
    @Published var shortcuts: [ShortcutMapping] = []
    @Published var searchText: String = ""
    @Published var selectedCategory: ShortcutMapping.Category? = nil

    private let saveKey = "desire.keyboardShortcuts"

    init() {
        load()
    }

    var filteredShortcuts: [ShortcutMapping] {
        let filtered = selectedCategory != nil
            ? shortcuts.filter { $0.category == selectedCategory }
            : shortcuts

        guard !searchText.isEmpty else { return filtered }
        return filtered.filter {
            $0.commandName.localizedCaseInsensitiveContains(searchText) ||
            $0.displayText.localizedCaseInsensitiveContains(searchText)
        }
    }

    var groupedShortcuts: [(ShortcutMapping.Category, [ShortcutMapping])] {
        var groups: [ShortcutMapping.Category: [ShortcutMapping]] = [:]
        for shortcut in filteredShortcuts {
            groups[shortcut.category, default: []].append(shortcut)
        }
        return ShortcutMapping.Category.allCases.compactMap { category in
            let items = groups[category] ?? []
            return items.isEmpty ? nil : (category, items)
        }
    }

    func hasConflict(mapping: ShortcutMapping) -> Bool {
        shortcuts.contains { other in
            other.id != mapping.id &&
            other.keyEquivalent.lowercased() == mapping.keyEquivalent.lowercased() &&
            other.modifierFlags == mapping.modifierFlags
        }
    }

    func findConflicts(mapping: ShortcutMapping) -> [ShortcutMapping] {
        shortcuts.filter { other in
            other.id != mapping.id &&
            other.keyEquivalent.lowercased() == mapping.keyEquivalent.lowercased() &&
            other.modifierFlags == mapping.modifierFlags
        }
    }

    func resetAll() {
        shortcuts = ShortcutMapping.defaults
        save()
    }

    func resetOne(id: String) {
        guard let i = shortcuts.firstIndex(where: { $0.id == id }),
              let defaultMapping = ShortcutMapping.defaults.first(where: { $0.id == id }) else { return }
        shortcuts[i] = defaultMapping
        save()
    }

    func update(_ mapping: ShortcutMapping) {
        guard let i = shortcuts.firstIndex(where: { $0.id == mapping.id }) else { return }
        shortcuts[i] = mapping
        shortcuts[i].isCustomized = true
        save()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let custom = try? JSONDecoder().decode([ShortcutMapping].self, from: data) {
            var merged = ShortcutMapping.defaults
            for c in custom where c.isCustomized {
                if let i = merged.firstIndex(where: { $0.id == c.id }) {
                    merged[i] = c
                }
            }
            shortcuts = merged
        } else {
            shortcuts = ShortcutMapping.defaults
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(shortcuts) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }

    func registerLocalMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

            for shortcut in self.shortcuts where shortcut.isCustomized {
                let shortcutFlags = NSEvent.ModifierFlags(rawValue: shortcut.modifierFlags)
                    .intersection([.command, .shift, .option, .control])
                if key == shortcut.keyEquivalent.lowercased() && flags == shortcutFlags {
                    NotificationCenter.default.post(name: .shortcutCommand, object: shortcut.id)
                    return nil
                }
            }
            return event
        }
    }
}

extension Notification.Name {
    static let shortcutCommand = Notification.Name("shortcutCommand")
}
