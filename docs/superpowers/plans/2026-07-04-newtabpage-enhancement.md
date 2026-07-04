# NewTabPage Enhancement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Beautify NewTabPage with macOS-native card UI and support custom QuickDial management (add/delete/edit/reorder).

**Architecture:** QuickDial model extracted to its own file with Codable; QuickDialStore manages `@Published dials` with UserDefaults persistence; NewTabPage receives store via `@ObservedObject` and uses card grid with popover-based add/edit forms.

**Tech Stack:** SwiftUI, Combine, UserDefaults

---

### Task 1: Create QuickDial Model

**Files:**
- Create: `Desire/Features/Browsing/QuickDial.swift`
- Remove QuickDial + defaultDials from: `Desire/Features/Browsing/NewTabPage.swift`

- [ ] **Create QuickDial.swift**

```swift
import Foundation

struct QuickDial: Identifiable, Codable {
    let id: UUID
    var title: String
    var url: String
    var icon: String

    init(id: UUID = UUID(), title: String, url: String, icon: String = "globe") {
        self.id = id
        self.title = title
        self.url = url
        self.icon = icon
    }
}

let defaultDials: [QuickDial] = [
    QuickDial(title: "Google", url: "https://www.google.com", icon: "magnifyingglass"),
    QuickDial(title: "YouTube", url: "https://www.youtube.com", icon: "play.rectangle"),
    QuickDial(title: "GitHub", url: "https://github.com", icon: "chevron.left.forwardslash.chevron.right"),
    QuickDial(title: "Wikipedia", url: "https://www.wikipedia.org", icon: "book"),
    QuickDial(title: "Reddit", url: "https://www.reddit.com", icon: "bubble.left.and.bubble.right"),
    QuickDial(title: "Apple", url: "https://www.apple.com", icon: "apple.logo"),
    QuickDial(title: "Twitter/X", url: "https://x.com", icon: "bird"),
    QuickDial(title: "Baidu", url: "https://www.baidu.com", icon: "spider"),
]
```

- [ ] **Remove old QuickDial struct and defaultDials from NewTabPage.swift**

Edit `NewTabPage.swift` to delete the `struct QuickDial` and `let defaultDials` declarations (lines 3-19).

### Task 2: Create QuickDialStore

**Files:**
- Create: `Desire/Features/Browsing/QuickDialStore.swift`

- [ ] **Create QuickDialStore.swift**

```swift
import Combine
import Foundation

@MainActor
class QuickDialStore: ObservableObject {
    @Published var dials: [QuickDial] = []
    private let storageKey = "desire.quickdials"

    init() {
        load()
    }

    func add(title: String, url: String) {
        let dial = QuickDial(title: title, url: url)
        dials.append(dial)
        save()
    }

    func delete(id: UUID) {
        dials.removeAll { $0.id == id }
        save()
    }

    func update(id: UUID, title: String, url: String) {
        guard let index = dials.firstIndex(where: { $0.id == id }) else { return }
        dials[index].title = title
        dials[index].url = url
        save()
    }

    func move(from source: Int, to destination: Int) {
        guard dials.indices.contains(source), dials.indices.contains(destination) else { return }
        let moved = dials.remove(at: source)
        let insert = source < destination ? destination - 1 : destination
        dials.insert(moved, at: min(insert, dials.count))
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([QuickDial].self, from: data),
              !decoded.isEmpty else {
            dials = defaultDials
            return
        }
        dials = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(dials) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
```

### Task 3: Rewrite NewTabPage.swift

**Files:**
- Rewrite: `Desire/Features/Browsing/NewTabPage.swift`

- [ ] **Rewrite NewTabPage.swift**

```swift
import AppKit
import SwiftUI

struct NewTabPage: View {
    @ObservedObject var store: QuickDialStore
    @Binding var urlString: String
    var onNavigate: (String) -> Void

    @State private var searchText = ""
    @State private var editingDial: QuickDial?
    @State private var editTitle = ""
    @State private var editURL = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索或输入网址", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .frame(maxWidth: 480)
                .padding(.horizontal)
                .padding(.top, 60)
                .onSubmit {
                    onNavigate(searchText)
                }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(store.dials.enumerated()), id: \.element.id) { index, dial in
                        dialCard(dial, at: index)
                    }

                    addButton()
                }
                .padding(.horizontal, 40)
                .padding(.top, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .popover(item: $editingDial) { dial in
            editForm(dial: dial)
        }
    }

    private func dialCard(_ dial: QuickDial, at index: Int) -> some View {
        VStack(spacing: 8) {
            if dial.icon == "globe" {
                FaviconView(urlString: dial.url, size: 36)
                    .frame(width: 48, height: 48)
            } else {
                Image(systemName: dial.icon)
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
            }

            Text(dial.title)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 80)
        }
        .frame(width: 100, height: 110)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(count: 2) {
            editingDial = dial
            editTitle = dial.title
            editURL = dial.url
        }
        .onTapGesture {
            onNavigate(dial.url)
        }
        .contextMenu {
            Button("编辑") {
                editingDial = dial
                editTitle = dial.title
                editURL = dial.url
            }
            Button("删除") {
                store.delete(id: dial.id)
            }
        }
        .onDrag {
            NSItemProvider(object: NSString(string: "\(index)"))
        }
        .onDrop(of: [.text], delegate: DialDropDelegate(targetIndex: index, store: store))
    }

    private func addButton() -> some View {
        VStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("添加")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 100, height: 110)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            editingDial = QuickDial(title: "", url: "")
            editTitle = ""
            editURL = ""
        }
    }

    private func editForm(dial: QuickDial) -> some View {
        VStack(spacing: 12) {
            TextField("标题", text: $editTitle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)

            TextField("网址", text: $editURL)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)

            HStack(spacing: 12) {
                Button("取消") {
                    editingDial = nil
                }
                .keyboardShortcut(.escape)

                Button("保存") {
                    let trimmedTitle = editTitle.trimmingCharacters(in: .whitespaces)
                    let trimmedURL = editURL.trimmingCharacters(in: .whitespaces)
                    guard !trimmedTitle.isEmpty, !trimmedURL.isEmpty else { return }

                    if store.dials.contains(where: { $0.id == dial.id }) {
                        store.update(id: dial.id, title: trimmedTitle, url: trimmedURL)
                    } else {
                        store.add(title: trimmedTitle, url: trimmedURL)
                    }
                    editingDial = nil
                }
                .keyboardShortcut(.return)
                .disabled(editTitle.trimmingCharacters(in: .whitespaces).isEmpty
                          || editURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 280)
    }
}

private struct DialDropDelegate: DropDelegate {
    let targetIndex: Int
    let store: QuickDialStore

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let str = reading as? String, let source = Int(str) else { return }
            Task { @MainActor in
                store.move(from: source, to: targetIndex)
            }
        }
        return true
    }
}
```

### Task 4: Update ContentView.swift

**Files:**
- Modify: `Desire/Views/ContentView.swift`

- [ ] **Add quickDialStore to ContentView**

Add `@StateObject private var quickDialStore = QuickDialStore()` alongside the other state objects.

- [ ] **Update NewTabPage usage**

Find the NewTabPage instantiation in ContentView.swift and update it:

Before:
```swift
NewTabPage(urlString: Binding(
    get: { tab.urlString },
    set: { tab.urlString = $0 }
), onNavigate: { input in
    navigateToURL(input, for: tab)
})
```

After:
```swift
NewTabPage(store: quickDialStore, urlString: Binding(
    get: { tab.urlString },
    set: { tab.urlString = $0 }
), onNavigate: { input in
    navigateToURL(input, for: tab)
})
```

### Task 5: Build & Verify

- [ ] **Build the project**

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire build
```

Expected: ** BUILD SUCCEEDED **

- [ ] **Commit**

```bash
git add -A && git commit -m "feat: enhance NewTabPage with macOS-native card UI and QuickDial management

- QuickDial model extracted to own file with Codable persistence
- QuickDialStore manages CRUD + reorder with UserDefaults
- Card grid UI with SF Symbol icons, shadows, hover
- Right-click context menu for edit/delete
- Popover-based add/edit form
- Drag reorder via DialDropDelegate
- \"+\" card with dashed border for adding new dials"
```
