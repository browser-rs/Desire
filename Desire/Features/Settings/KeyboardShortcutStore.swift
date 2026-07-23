import AppKit
import Combine
import Foundation

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
        // Primary: DiskStore.
        if let stored = DiskStore.load([ShortcutMapping].self, key: saveKey) {
            shortcuts = Self.mergeOverDefaults(stored)
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let custom = try? JSONDecoder().decode([ShortcutMapping].self, from: data) {
            shortcuts = Self.mergeOverDefaults(custom)
            save()
            UserDefaults.standard.removeObject(forKey: saveKey)
            return
        }
        shortcuts = ShortcutMapping.defaults
    }

    /// Merges stored/custom mappings over the builtin defaults so newly-added
    /// default shortcuts appear even if the persisted list predates them.
    private static func mergeOverDefaults(_ custom: [ShortcutMapping]) -> [ShortcutMapping] {
        var merged = ShortcutMapping.defaults
        for c in custom where c.isCustomized {
            if let i = merged.firstIndex(where: { $0.id == c.id }) {
                merged[i] = c
            }
        }
        return merged
    }

    private func save() {
        DiskStore.save(shortcuts, key: saveKey)
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
