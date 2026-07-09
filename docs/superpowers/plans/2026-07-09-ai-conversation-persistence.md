# AI Conversation Persistence & Floating Panel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add conversation persistence (JSON per file), inline history management UI, and enable the unused AIFloatingPanel.

**Architecture:** `Conversation` model + `ConversationStore` (file I/O) + `AISessionStore` hooks (save/load) + `AIPanel` changes (history list) + wire `AIFloatingPanel` into toolbar.

**Tech Stack:** Swift, Foundation (Codable JSON), AppKit (NSFileManager, Application Support directory)

---

### Task 1: Create Conversation Model

**Files:**
- Create: `Desire/Features/AI/Conversation.swift`

- [ ] **Step 1: Write Conversation.swift**

```swift
import Foundation

struct Conversation: Identifiable, Codable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [AIMessage]
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -3
```

---

### Task 2: Create ConversationStore

**Files:**
- Create: `Desire/Features/AI/ConversationStore.swift`

- [ ] **Step 1: Write ConversationStore.swift**

```swift
import Foundation

@MainActor
class ConversationStore: ObservableObject {
    @Published var conversations: [Conversation] = []

    private var storageURL: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = paths[0].appendingPathComponent("me.siwi.Desire/conversations")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        loadAll()
    }

    func loadAll() {
        let fm = FileManager.default
        let dir = storageURL
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            conversations = []
            return
        }
        var result: [Conversation] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let conv = try? JSONDecoder().decode(Conversation.self, from: data) else { continue }
            result.append(conv)
        }
        result.sort { $0.updatedAt > $1.updatedAt }
        conversations = result
    }

    func save(_ conversation: Conversation) {
        let url = storageURL.appendingPathComponent("\(conversation.id.uuidString).json")
        guard let data = try? JSONEncoder().encode(conversation) else { return }
        try? data.write(to: url, options: .atomic)
        loadAll()
    }

    func delete(_ id: UUID) {
        let url = storageURL.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        loadAll()
    }

    func rename(_ id: UUID, to title: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        var conv = conversations[idx]
        conv.title = title
        save(conv)
    }

    func conversation(for id: UUID) -> Conversation? {
        let url = storageURL.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url),
              let conv = try? JSONDecoder().decode(Conversation.self, from: data) else { return nil }
        return conv
    }

    func create(title: String = "New Conversation") -> Conversation {
        Conversation(id: UUID(), title: title, createdAt: Date(), updatedAt: Date(), messages: [])
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -3
```

---

### Task 3: Modify AISessionStore for Persistence Hooks

**Files:**
- Modify: `Desire/Features/AI/AISessionStore.swift`

- [ ] **Step 1: Add properties and save/load methods**

Add to AISessionStore:
```swift
@Published var conversationId: UUID?
@Published var conversationTitle: String?
weak var conversationStore: ConversationStore?
```

Add methods:
```swift
func loadConversation(_ id: UUID) {
    guard let conv = conversationStore?.conversation(for: id) else { return }
    messages = conv.messages
    conversationId = conv.id
    conversationTitle = conv.title
    awaitingQuestion = false
    currentAction = nil
}

private func saveCurrentConversation() {
    guard let store = conversationStore else { return }
    let id = conversationId ?? UUID()
    conversationId = id
    let title = conversationTitle ?? messages.first(where: { $0.role == .user })?.content.prefix(40).trimmingCharacters(in: .whitespaces) + "..."
    ?? "New Conversation"
    let conv = Conversation(id: id, title: title, createdAt: Date(), updatedAt: Date(), messages: messages)
    store.save(conv)
    conversationTitle = title
}
```

Modify `sendMessage` to auto-create conversation on first message:
```swift
func sendMessage(_ text: String) {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    isProcessing = true
    currentAction = nil
    awaitingQuestion = false
    let userMsg = AIMessage(role: .user, content: text)
    messages.append(userMsg)
    if conversationId == nil {
        conversationTitle = String(text.prefix(40)).trimmingCharacters(in: .whitespaces)
    }
    saveCurrentConversation()
    Task { await processLoop() }
}
```

After each tool loop iteration in `processLoop()`, add `saveCurrentConversation()` (after the tool results are appended, before the next loop iteration).

Modify `clear()`:
```swift
func clear() {
    messages.removeAll()
    conversationId = nil
    conversationTitle = nil
    isProcessing = false
    currentAction = nil
    awaitingQuestion = false
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -3
```

---

### Task 4: Wire ConversationStore in AppState

**Files:**
- Modify: `Desire/App/AppState.swift`
- Modify: `Desire/Views/ContentView.swift`

- [ ] **Step 1: Add ConversationStore to AppState**

```swift
let conversationStore = ConversationStore()

// In init(), after aiSession init:
aiSession.conversationStore = conversationStore
```

- [ ] **Step 2: Expose in ContentView**

Add convenience accessor:
```swift
private var conversationStore: ConversationStore { appState.conversationStore }
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -3
```

---

### Task 5: Modify AIPanel with History UI

**Files:**
- Modify: `Desire/Features/AI/AIPanel.swift`

- [ ] **Step 1: Read current AIPanel.swift to understand structure**

```bash
cat -n Desire/Features/AI/AIPanel.swift | head -50
```

- [ ] **Step 2: Add state and history list UI**

Add to AIPanel struct:
```swift
@State private var showHistory = false
let conversationStore: ConversationStore
```

Modify the header to show history toggle when in chat mode with messages:
```swift
// In the header area, add after title:
if !store.messages.isEmpty {
    Button {
        showHistory.toggle()
    } label: {
        Image(systemName: "clock.arrow.circlepath")
            .font(.system(size: 12))
    }
    .buttonStyle(.plain)
    .help("Conversation History")
}
```

When `showHistory` is true, show history list instead of messages/input:
```swift
if showHistory {
    historyListView
} else {
    // existing messages + input
}
```

History list view:
```swift
private var historyListView: some View {
    VStack(spacing: 0) {
        HStack {
            Text("History")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button("Done") { showHistory = false }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

        Divider()

        if conversationStore.conversations.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("No conversation history")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(conversationStore.conversations) { conv in
                    Button {
                        store.loadConversation(conv.id)
                        showHistory = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conv.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text(conv.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename") {
                            renameConversation(conv)
                        }
                        Button("Delete", role: .destructive) {
                            conversationStore.delete(conv.id)
                            if store.conversationId == conv.id {
                                store.clear()
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}
```

Add rename alert:
```swift
@State private var renameId: UUID?
@State private var renameText = ""

// Add .alert modifier
.alert("Rename Conversation", isPresented: .init(get: { renameId != nil }, set: { if !$0 { renameId = nil } })) {
    TextField("Title", text: $renameText)
    Button("OK") {
        if let id = renameId {
            conversationStore.rename(id, to: renameText)
        }
        renameId = nil
    }
    Button("Cancel", role: .cancel) { renameId = nil }
}
```

Update the ContentView call site to pass conversationStore:
```swift
AIPanel(store: aiSession, conversationStore: conversationStore)
    .frame(width: 320)
```

And for the unused AIPanel in floating panel section.

- [ ] **Step 2: Build**

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -3
```

---

### Task 6: Enable AIFloatingPanel

**Files:**
- Modify: `Desire/Features/AI/AIFloatingPanel.swift`
- Modify: `Desire/Views/ContentView.swift`
- Modify: `Desire/Features/Toolbar/Toolbar.swift`

- [ ] **Step 1: Modify AIFloatingPanel to receive conversationStore**

```swift
class AIFloatingPanel {
    private weak var store: AISessionStore?
    private weak var conversationStore: ConversationStore?

    func show(store: AISessionStore, conversationStore: ConversationStore) {
        self.store = store
        self.conversationStore = conversationStore
        // ... existing window creation code ...
        let panelView = AIPanel(store: store, conversationStore: conversationStore)
        hostingController = NSHostingController(rootView: panelView)
        // ...
    }
}
```

- [ ] **Step 2: Add toggle to ContentView**

Add `@State private var showAIFloatingPanel = false` or keep a reference to AIFloatingPanel.

Actually, since AIFloatingPanel is a class (not a SwiftUI view), use a `@State` reference:
```swift
@State private var aiFloatingPanel = AIFloatingPanel()
```

Add toggle function:
```swift
private func toggleAIFloatingPanel() {
    if aiFloatingPanel.isVisible {
        aiFloatingPanel.hide()
    } else {
        aiFloatingPanel.show(store: aiSession, conversationStore: conversationStore)
    }
}
```

- [ ] **Step 3: Add toolbar action**

In Toolbar.Actions, add:
```swift
let toggleAIFloatingPanel: () -> Void
```

In Toolbar body, add a button or menu item:
```swift
// In the "more" menu or as a toolbar button:
Button("AI Assistant", systemImage: "wand.and.stars.inverse") {
    actions.toggleAIFloatingPanel()
}
```

In ContentView, wire the action:
```swift
toggleAIFloatingPanel: { toggleAIFloatingPanel() },
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -3
```

---

### Task 7: Final Build & Verify

- [ ] **Clean build**

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire clean build 2>&1 | grep -E "error:|BUILD" | head -5
```
