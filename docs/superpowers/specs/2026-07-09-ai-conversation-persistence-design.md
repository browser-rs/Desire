# AI Conversation Persistence & Floating Panel — Design Spec

## Overview

Add conversation persistence (save/load), conversation history management UI, and enable the unused AIFloatingPanel for the Desire browser's AI assistant.

## Architecture

### File Layout

```
Features/AI/
├── AIMessage.swift              # (existing) Model types
├── AIPreferenceStore.swift      # (existing) Settings
├── AIService.swift              # (existing) LLM API client
├── AISessionStore.swift         # (MODIFIED) Add conversation persistence hooks
├── BrowserToolProvider.swift    # (existing) 50 tool definitions
├── AIPanel.swift                # (MODIFIED) Add history list UI
├── AIFloatingPanel.swift        # (ENABLED) Wire into toolbar
├── AIElementPicker.swift        # (existing)
├── AISettingsSection.swift      # (existing)
├── Conversation.swift           # (NEW) Conversation model
└── ConversationStore.swift      # (NEW) Persistence manager
```

### Model Layer

**Conversation.swift:**

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

- Title auto-generated: first 40 chars of first user message (or "New Conversation")
- `Codable` for JSON file serialization

### Store Layer

**ConversationStore.swift:**

```swift
@MainActor
class ConversationStore: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var selectedId: UUID?

    private var storageURL: URL {
        // ~/Library/Application Support/me.siwi.Desire/conversations/
    }

    func loadAll()                          // enumerate directory, load metadata
    func save(_ conversation: Conversation) // write JSON to file
    func delete(_ id: UUID)                 // remove file
    func rename(_ id: UUID, to title: String)
    func conversation(for id: UUID) -> Conversation?  // full load with messages
    func create(title: String) -> Conversation
}
```

- File format: `{uuid}.json` per conversation
- `loadAll` only loads metadata (title, dates) — messages loaded on demand
- `save` overwrites the file with full state (messages included)
- Directory created on first access

**AISessionStore changes:**

```swift
// New properties
@Published var conversationId: UUID?
weak var conversationStore: ConversationStore?

// New methods
func loadConversation(_ id: UUID)       // restore messages from store
func saveCurrentConversation()           // persist current messages

// Modified: sendMessage
// - If no conversationId, create one via conversationStore
// - Auto-generate title from first user message

// Modified: clear()
// - Clear messages and conversationId, but don't delete saved file
```

Save triggers:
- After each tool loop iteration (not every stream tick — too frequent)
- On `sendMessage` (before starting stream)
- On app backgrounding (via scene phase)

### View Layer

**AIPanel changes:**

Header area:
- Title: "AI Assistant" or conversation title if one is loaded
- New clock icon button `🕐` → toggles between chat mode and history mode

History mode (inline, not sheet):
- List of conversations, each row: title, date, message count
- Tap to load → switches back to chat mode with that conversation
- Right-click context menu: Rename, Delete (with confirmation)
- Empty state: "No conversation history"
- Close button to return to current chat

Chat mode (existing behavior):
- Minor change: title shows conversation title instead of just "AI Assistant"

**AIFloatingPanel:**

The existing `AIFloatingPanel` class is already implemented but never wired. Changes:
- `DesireApp.swift`: Add keyboard shortcut `⌘⇧I` → `toggleAI` (`BrowserCommand`)
- `ContentView.swift` / `Toolbar.swift`: Add toolbar button for floating panel
- Floating panel uses the same shared `AISessionStore` as the sidebar
- Opening the floating panel does NOT close the sidebar panel
- Both panels share state in real-time (no sync needed — same ObservableObject)

### Integration Points

**AppState.swift:**
- Add `@Published var conversationStore = ConversationStore()`
- Wire `aiSession.conversationStore = conversationStore`

**ContentView.swift:**
- Wire AIFloatingPanel toggle button in toolbar
- AIFloatingPanel.show() shares the same aiSession instance

**Toolbar.swift:**
- Add `toggleAIFloatingPanel: () -> Void` action
- New menu item or button

## Storage Details

- Directory: `~/Library/Application Support/me.siwi.Desire/conversations/`
- File naming: `{UUID}.json`
- Schema per file: `Conversation` (Codable struct)
- Error handling: save failures silently logged, never block UI
- Migration: no prior schema — clean start

## UI Flow

```
┌──────────────────────────────┐
│  AI Assistant  [🕐] [🗑]     │  ← Header with history toggle
├──────────────────────────────┤
│  (chat mode)                 │
│  - message list              │
│  - input field               │
│                              │
│  OR (history mode)           │
│  - conversation list         │
│  - tap to load               │
│  - right-click menu          │
├──────────────────────────────┤
│  [Input field]          [→]  │
└──────────────────────────────┘
```

## Implementation Order

1. `Conversation.swift` model
2. `ConversationStore.swift` persistence
3. Modify `AISessionStore.swift` for save/load hooks
4. Modify `AIPanel.swift` for history UI
5. Wire `AIFloatingPanel` into toolbar + keyboard shortcut
6. Build verification

## Error Handling

- File I/O errors: silently log, show no error UI (data loss is non-critical)
- Directory creation failure: show once warning, fall back to no persistence
- Corrupted conversation file: skip, log warning, don't crash
- Concurrent save: unlikely (all @MainActor), but file coordination not needed
