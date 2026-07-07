import AppKit
import Combine
import Foundation

struct ShortcutMapping: Codable, Identifiable, Equatable {
    let id: String
    var commandName: String
    var keyEquivalent: String
    var modifierFlags: UInt
    var isCustomized: Bool

    static let defaults: [ShortcutMapping] = {
        let cmd = NSEvent.ModifierFlags.command.rawValue
        let shift = NSEvent.ModifierFlags.shift.rawValue
        return [
            ShortcutMapping(id: "newTab", commandName: "New Tab", keyEquivalent: "t", modifierFlags: cmd, isCustomized: false),
            ShortcutMapping(id: "newIncognitoTab", commandName: "New Incognito Tab", keyEquivalent: "n", modifierFlags: cmd | shift, isCustomized: false),
            ShortcutMapping(id: "closeTab", commandName: "Close Tab", keyEquivalent: "w", modifierFlags: cmd, isCustomized: false),
            ShortcutMapping(id: "reopenClosedTab", commandName: "Reopen Closed Tab", keyEquivalent: "t", modifierFlags: cmd | shift, isCustomized: false),
            ShortcutMapping(id: "findInPage", commandName: "Find in Page", keyEquivalent: "f", modifierFlags: cmd, isCustomized: false),
            ShortcutMapping(id: "focusAddressBar", commandName: "Focus Address Bar", keyEquivalent: "l", modifierFlags: cmd, isCustomized: false),
            ShortcutMapping(id: "goBack", commandName: "Go Back", keyEquivalent: "[", modifierFlags: cmd, isCustomized: false),
            ShortcutMapping(id: "goForward", commandName: "Go Forward", keyEquivalent: "]", modifierFlags: cmd, isCustomized: false),
            ShortcutMapping(id: "reload", commandName: "Reload", keyEquivalent: "r", modifierFlags: cmd, isCustomized: false),
            ShortcutMapping(id: "zoomIn", commandName: "Zoom In", keyEquivalent: "=", modifierFlags: cmd, isCustomized: false),
            ShortcutMapping(id: "zoomOut", commandName: "Zoom Out", keyEquivalent: "-", modifierFlags: cmd, isCustomized: false),
            ShortcutMapping(id: "resetZoom", commandName: "Reset Zoom", keyEquivalent: "0", modifierFlags: cmd, isCustomized: false),
            ShortcutMapping(id: "inspectElement", commandName: "Inspect Element", keyEquivalent: "i", modifierFlags: cmd | shift, isCustomized: false),
            ShortcutMapping(id: "print", commandName: "Print", keyEquivalent: "p", modifierFlags: cmd, isCustomized: false),
            ShortcutMapping(id: "showHistory", commandName: "Show History", keyEquivalent: "y", modifierFlags: cmd, isCustomized: false),
            ShortcutMapping(id: "tabSearch", commandName: "Search Tabs", keyEquivalent: "\\", modifierFlags: cmd, isCustomized: false),
            ShortcutMapping(id: "toggleSidebar", commandName: "Toggle Sidebar", keyEquivalent: "b", modifierFlags: cmd | shift, isCustomized: false),
            ShortcutMapping(id: "responsiveMode", commandName: "Responsive Design Mode", keyEquivalent: "m", modifierFlags: cmd | shift, isCustomized: false),
            ShortcutMapping(id: "screenshot", commandName: "Screenshot Region", keyEquivalent: "5", modifierFlags: cmd | shift, isCustomized: false),
            ShortcutMapping(id: "settings", commandName: "Settings", keyEquivalent: ",", modifierFlags: cmd, isCustomized: false),
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

    private let saveKey = "desire.keyboardShortcuts"

    init() {
        load()
    }

    func resetAll() {
        shortcuts = ShortcutMapping.defaults
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
