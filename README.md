# Desire

**Product page: [desire.mankong.icu](https://desire.mankong.icu/)**

**An AI-native web browser for macOS.** Built with SwiftUI and WebKit — and
the browser itself is the agent's execution environment: a built-in AI agent
drives 100+ real browser tools, while an automation bridge and an MCP server
let external agents do the same.

> Not "a browser with a chatbot sidebar". The agent sees the page like a
> user (text, HTML, DOM tree, screenshots, network log), acts like a user
> (click, type, scroll, fill, upload), and its every side effect passes an
> approval policy you control.

## The built-in agent

A full agent runtime lives in `Features/Agent/` — the largest module in the
app. Open it with ⌘' or the wand button in the toolbar — as a side panel
or a floating window.

**100+ browser tools.** Navigation and page reading (`navigate`,
`getPageText`, `getPageHTML`, `getPageSnapshot`, `extract`, `getTables`);
real interaction (`click`, `type`, `fill`, `fillLogin`, `hover`, `scroll`,
`select`, `setUploadFile`, `pressKey`, with `waitFor` / `waitForElement` /
`waitForText` for races); downloads (`downloadFile`, `downloadMedia` with
background HLS export); captures (`screenshot`, `screenshotElement`,
`saveAsPDF`, `startRecording`); browser state (`listTabs`, `switchTab`,
bookmarks, history, reading list, zoom, dark mode, reader mode, PiP…); and
escape hatches (`executeJS`, `runCommand`, `readFile`/`writeFile`).

**Multi-modal, multi-model.** Model services are first-class: each provider
profile carries its own endpoint, API key (Keychain), model list and extra
headers. Ships presets for OpenAI, DeepSeek and Zhipu GLM; any OpenAI-compatible
endpoint works; `OllamaProvider` runs local models; `FoundationModelsProvider`
uses Apple on-device models. Reasoning models' thinking streams into a
collapsible block — and is never echoed back to the server.

**Long-horizon work.** The agent plans (`updatePlan` renders a live checklist),
asks you questions mid-task (`askUser`), and never ends a turn silently.
Persistent **memory** per profile (auto-extracted, editable, queryable),
**skills** (`useSkill` / `listSkills`) for reusable playbooks, and an
**evidence store** backing its claims.

**Tab Crew — parallel agents.** `crewDispatch` spawns subagents that each
work a tab (or a sub-session) concurrently, with `crewStatus` / `crewCancel`
for coordination. Scheduled tasks (`scheduleTask`) let the agent run jobs
minutes or hours later and report back via system notification.

**Approval policy, not blind trust.** Every risky tool call (shell commands,
file writes, logins, form posts) routes through a policy engine — per-tool
allow / ask / deny. Approvals surface as cards in the chat and as bridge
events, so even an unattended run can be gated from the outside.

**Chat UX that survives streaming.** Markdown with cached block parsing on a
background thread, sticky-bottom follow with hysteresis (content growth never
moves your viewport), per-conversation input history (↑/↓), and an agent
panel that stays responsive while a 40 KB answer streams in.

## Also a very capable browser

- **DevTools, in-app** — Console (REPL, real object handles), Network
  (XHR/fetch/WebSocket/SSE frames, initiators, replay, block-from-panel),
  Element (DOM tree, matched CSS cascade, box model), Application (cookies,
  localStorage/sessionStorage, IndexedDB, Cache Storage, Service Workers —
  all writable). Scoped per tab.
- **Tracking & ad blocking** — EasyList / EasyList China via WKContentRuleList
  (with a compile-failure bisect that keeps lists alive), plus video-site ad
  rules that are hot-swappable (local override > remote pack > built-in) and
  a first-click hijack guard for video players. AI-assisted ad detection can
  propose rules; you confirm; they roll back.
- **Downloads** — pause/resume with checkpoint survival across restarts,
  private-mode isolation, media export (HLS → file) with background tasks.
- **Profiles & containers** — per-persona isolation; incognito windows;
  per-site settings (zoom, UA, permissions).
- **Passwords & autofill** — Keychain-backed, profile-based form filling.
- **Bookmarks / History / Reading list** — folders, import/export, search,
  session restore.
- **WebExtensions** — manifest loading with a `browser.*` polyfill, per-extension
  storage namespaces, popup support.
- **Everyday** — tab groups, pinned tabs, tab suspension, split view
  (native `HSplitView`), responsive design mode, reader mode, find-in-page,
  picture-in-picture, screenshots (full page / element), translation,
  keyboard shortcut customization, trilingual UI (English / 简体中文 /
  繁體中文).

## Automation: bridge + MCP

Everything the agent can do is also a public HTTP API — the same surface the
agent's tools call, used by CI, QA scripts, and external agents.

```bash
open Desire.app --args --automation --mcp-server
```

- **Bridge** `http://127.0.0.1:8799` — 60+ JSON endpoints, self-describing via
  `GET /` (machine-readable index of every endpoint with params & examples).
- **MCP server** `http://127.0.0.1:8798/mcp` — 30 tools over Streamable HTTP
  JSON-RPC, so Claude/other MCP clients can drive Desire directly. Window
  binding via `params._meta.desireWindow` (or per-call `window` argument).
- **MCP client** — Desire's own agent can connect to *external* MCP servers
  and use their tools.
- **Events** `GET /events` (SSE) — pageReady, download lifecycle, approvals,
  tab churn, beforeunload… push instead of poll.
- **Agent endpoints** — `POST /agent/send`, `GET /agent/messages`,
  `POST /agent/cancel`, `GET /approvals`, scheduled-task endpoints: drive or
  supervise a running chat turn from scripts.
- Optional tokens: `--automation-token <t>` / `--mcp-token <t>` (all requests
  then require `Authorization: Bearer <t>`).

Docs: [docs/BRIDGE.md](docs/BRIDGE.md) · driver examples in [examples/](examples/).

```bash
B=http://127.0.0.1:8799
curl -s -X POST $B/agent/send -d '{"text":"总结这个页面"}'   # ask the built-in agent
curl -s -X POST $B/navigate   -d '{"url":"https://example.com"}'
curl -sN $B/events                                          # watch what happens
```

## Download

Grab the latest unsigned build from
[GitHub Releases](https://github.com/browser-rs/Desire/releases) — Apple
Silicon (arm64), macOS 26.5+. A visual intro with the same install steps
(in Chinese) lives at [desire.mankong.icu](https://desire.mankong.icu/).

1. **Unzip** `Desire-vX.Y.Z-macos-arm64.zip` (double-click it, or
   `ditto -x -k Desire-vX.Y.Z-macos-arm64.zip .`).
2. **Install**: drag the unzipped **`Desire.app` into `/Applications`**.
3. **Clear the quarantine flag once** (required for unsigned builds). Point it
   at the path where you put the app:

```bash
xattr -cr /Applications/Desire.app
```

4. **Open** `Desire.app`. Gatekeeper checks it once on the first launch; after
   step 3 it opens normally.

> `xattr: No such file: Desire.app` means there is no unzipped app in the
> current directory — use the full path (`/Applications/Desire.app`) or `cd`
> into the folder that holds it.

## Build

- macOS 26.5+, Xcode 26.6+ (Apple Silicon)

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire build
```

Or open `Desire.xcodeproj` in Xcode and press ⌘B.

## Architecture

Feature-modular, strict three-layer separation:

```
Desire/
├── App/              # Entry point, automation bridge, window chrome
├── Features/         # 34 feature modules
│   ├── Agent/        # The agent runtime — the biggest module
│   ├── Browsing/     # WebView, tabs, toolbar
│   ├── DevTools/     # In-app developer tools
│   ├── MCP/          # MCP server + client
│   └── ...           # Bookmarks, History, Downloads, Privacy, …
├── Views/
│   ├── ContentView.swift   # Composition root
│   └── Components/         # Reusable primitives
└── Assets.xcassets
```

Each module follows **Model → Store → View**:

| Layer | File | Responsibility |
|-------|------|---------------|
| Model | `Xxx.swift` | Pure data structures (Codable, Identifiable) |
| Store | `XxxStore.swift` | `@MainActor ObservableObject`, business logic, persistence |
| View | `XxxView.swift` / `XxxPanel.swift` | SwiftUI rendering, no business logic |

See `AGENTS.md` for detailed conventions. Note that App Sandbox is
deliberately off — the agent executes shell commands; security boundaries are
Hardened Runtime plus in-app approval policy, not the platform sandbox.

## License

MIT
