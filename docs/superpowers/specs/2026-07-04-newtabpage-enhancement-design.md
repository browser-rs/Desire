# NewTabPage Enhancement Design

## Goal
Beautify NewTabPage UI with macOS-native styling, and support custom QuickDial management (add/delete/edit/reorder).

## Architecture

### Data Layer

**QuickDial.swift** (Model — `Features/Browsing/QuickDial.swift`)
- `struct QuickDial: Identifiable, Codable`
- Properties: `id: UUID`, `title: String`, `url: String`, `icon: String` (SF Symbol name)
- Default dials: Google (magnifyingglass), YouTube (play.rectangle), GitHub (chevron.left.forwardslash.chevron.right), Wikipedia (book), Reddit (bubble.left.and.bubble.right), Apple (apple.logo), Twitter/X (bird), Baidu (spider)
- Default dials use explicit SF Symbol names; user-added dials use `globe` as fallback icon

**QuickDialStore.swift** (Store — `Features/Browsing/QuickDialStore.swift`)
- `@MainActor class QuickDialStore: ObservableObject`
- `@Published var dials: [QuickDial]`
- Persisted to UserDefaults via `JSONEncoder`/`JSONDecoder` under key `desire.quickdials`
- On init: if no saved data, seed with 8 default dials
- Methods: `add(title:url:)`, `delete(id:)`, `update(id:title:url:)`, `move(from:to:)`
- Icon selection: if icon is `globe` (fallback for user-added), show FaviconView in UI

### View Layer

**NewTabPage.swift** (Page — `Features/Browsing/NewTabPage.swift`)
- Receives `@ObservedObject var store: QuickDialStore`, `onNavigate: (String) -> Void`, `urlString: Binding<String>`

#### Layout
- Full-width background: `Color(nsColor: .windowBackgroundColor)`
- Top: search TextField (same as current, keep)
- Grid: 4 columns, `spacing: 16`
- Each dial card: `RoundedRectangle(cornerRadius: 12)` background, `100×110` frame
  - Icon area: SF Symbol at 36pt or FaviconView at 36×36
  - Title: `font(.caption)`, `lineLimit(1)`
  - Hover: shadow + slight background tint via `.onHover`
- "+" card: same size, dashed border `StrokeStyle(dash: [5,3])`, plus icon centered
- Drag reorder via `.onDrag`/`.onDrop`

#### Interactions
- **Tap dial**: calls `onNavigate(dial.url)`
- **Double-tap dial**: shows `.popover` with title + URL fields, "保存" button
- **Right-click dial**: context menu with "编辑" and "删除"
- **Tap "+"**: shows `.popover` with title + URL fields, "添加" button
- **Drag dial**: `NSItemProvider` drag source, `DropDelegate` on each card for reorder

### ContentView Changes
- Add `@StateObject private var quickDialStore = QuickDialStore()`
- Pass `quickDialStore` to `NewTabPage`

## File Changes

| File | Action |
|------|--------|
| `Features/Browsing/NewTabPage.swift` | Rewrite — remove `QuickDial`, remove `defaultDials`, add enhanced UI |
| `Features/Browsing/QuickDial.swift` | Create — Model |
| `Features/Browsing/QuickDialStore.swift` | Create — Store |
| `Views/ContentView.swift` | Minor — add `quickDialStore`, pass to NewTabPage |

## Out of Scope
- Background customization (wallpaper/color)
- Cloud sync
