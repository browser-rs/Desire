# Desire

A native macOS web browser built with SwiftUI and WKWebView.

## Features

- **Web Browsing** — Full-featured tabbed browsing with WKWebView, back/forward navigation, find-in-page, reader mode
- **Bookmarks** — Recursive folders, drag-drop reordering, import/export (Netscape HTML format)
- **History** — Searchable history with date grouping, session restore on crash
- **Downloads** — Progress tracking via WKDownload KVO, configurable download location
- **Passwords** — Keychain-backed password management with autofill
- **Form Autofill** — Profile-based form filling with JS injection
- **Content Blocking** — 50+ ad/tracker domains blocked via WKContentRuleList
- **Tab Management** — Tab groups with colors, pinned tabs, tab suspension, tab search
- **Reading List** — Save articles for later reading
- **User Scripts** — Custom JS injection per URL pattern
- **Sidebar** — Unified panel for bookmarks, history, and reading list
- **Responsive Design Mode** — Preview pages at device-specific viewport sizes
- **Picture-in-Picture** — Detached video playback
- **Reading Mode** — Distraction-free article view
- **Per-Site Zoom** — Persistent zoom levels per domain
- **Keyboard Shortcuts** — Full keyboard navigation with customizable shortcuts

## AI / Automation

Desire is AI-native: it ships a localhost automation bridge, an MCP server, and an event stream so agents (or you) can drive it programmatically.

```bash
open Desire.app --args --automation --mcp-server
```

- **Bridge** `http://127.0.0.1:8799` — 68 endpoints (JSON), self-describing via `GET /`
- **MCP server** `http://127.0.0.1:8798/mcp` — 30 tools (Streamable HTTP JSON-RPC)
- **Events** `GET /events` (SSE) — pageReady, download lifecycle, approvals, tab churn
- **Docs**: [docs/BRIDGE.md](docs/BRIDGE.md) · driver examples in [examples/](examples/)

Optional tokens: `--automation-token <t>` / `--mcp-token <t>` (all
requests then require `Authorization: Bearer <t>`; unauthenticated
requests get 401).

**Window binding**: MCP clients can declare a target window at
initialize time via `params._meta.desireWindow = "<session UUID>"` —
subsequent tool calls act on that window (per-call `window` argument
overrides). Window UUIDs are available via `GET /agent/windows`.

## Requirements

- macOS 26.5+
- Xcode 26.6+

## Build

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire build
```

Or open `Desire.xcodeproj` in Xcode and press ⌘B.

## Architecture

The project follows a feature-modular architecture with strict three-layer separation:

```
Desire/
├── App/              # Entry point + entitlements
├── Features/         # One directory per feature
│   ├── Browsing/     # Core browsing (WebView, tabs, toolbar)
│   ├── Bookmarks/    # Bookmark management
│   ├── History/      # Browsing history
│   ├── Downloads/    # Download manager
│   ├── Password/     # Keychain-backed passwords
│   ├── Settings/     # App configuration
│   └── ...           # 14 feature modules total
├── Views/            # Shared UI components
│   ├── ContentView.swift   # Composition root
│   └── Components/         # Reusable primitives
└── Assets.xcassets
```

Each feature module follows **Model → Store → View** separation:

| Layer | File | Responsibility |
|-------|------|---------------|
| Model | `Xxx.swift` | Pure data structures (Codable, Identifiable) |
| Store | `XxxStore.swift` | `@MainActor ObservableObject`, business logic, persistence |
| View | `XxxView.swift` / `XxxPanel.swift` | SwiftUI rendering, no business logic |

See `AGENTS.md` for detailed conventions.

## License

MIT
