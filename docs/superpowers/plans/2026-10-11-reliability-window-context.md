# Desire Reliability and Window Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make persistence, Agent cancellation, remote protocols, MCP, and multi-window Profile ownership reliable without changing public browser or Agent semantics.

**Architecture:** First add deterministic ownership and persistence barriers, then introduce a window-scoped `WindowBrowsingContext` and migrate consumers to it. Database operations use transactional/conditional writes, while pure logic stays in the existing Foundation-only harness and protocol behavior is covered by Rust/API smoke tests.

**Tech Stack:** Swift 5 / SwiftUI / AppKit / WebKit / Foundation actors, Rust / axum / sqlx / MySQL / Redis, existing shell/Python automation tests, `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-10-11-reliability-window-context-design.md`

## Global Constraints

- Do not immediately migrate all `DiskStore` data to Core Data; retain file storage until the documented data threshold is reached.
- Do not introduce a speculative `WebEngine` protocol without a second implementation.
- Do not re-enable App Sandbox.
- Do not change public Agent tool semantics, bridge endpoint names, or Remote lane names unless fixing a concrete correctness defect.
- Do not introduce third-party UI or networking dependencies.
- Always use `xcodebuild ... clean build` before reporting completion.
- Do not modify `/Applications/Desire.app` during testing.
- Do not commit changes unless the user explicitly requests a commit.

## Review Focus

- A save/ remove/ flush sequence that completes during termination must leave the file matching the last operation; covered by Tasks 1-2.
- An old Agent task completing after cancel and immediate resend must not mutate the new turn; covered by Task 3.
- Two concurrent Remote consumers or claimers must not execute one frame or pairing twice; covered by Task 4.
- A token that merely starts with the configured token must be rejected; covered by Task 5.
- Two windows using different Profiles must not share cookies, scoped data, Agent targets, or session identity; covered by Tasks 7-9.

---

### Task 1: Add deterministic persistence test seams

**Files:**
- Modify: `apps/macos/Desire/Storage/DiskStore.swift`
- Modify: `tests/run.sh`
- Modify: `tests/main.swift`
- Test: `tests/main.swift` persistence section

**Interfaces:**
- Produces a writer-level barrier interface that later Task 2 can use without sleeping arbitrary durations.
- Keeps the public `DiskStore.save`, `DiskStore.remove`, and `DiskStore.flushSync` call sites source-compatible.

- [ ] **Step 1: Add a deterministic writer test entry point**

  Expose an internal/testable actor operation that can stage data and await a specific flush generation without depending on the 500 ms debounce timer. Keep production `DiskStore.flushSync()` as the bounded termination API.

- [ ] **Step 2: Add Foundation-only persistence tests**

  Add checks for save ordering, remove ordering, same-key coalescing, and a barrier that does not return before the staged operation is written. Use a temporary directory or an injected writer destination; do not touch the user's Application Support directory.

- [ ] **Step 3: Add the storage source to `tests/run.sh` if the test seam is Foundation-only**

  Compile the smallest storage implementation needed by the harness. Do not add AppKit, SwiftUI, or WebKit code to the pure test target.

- [ ] **Step 4: Run the focused harness**

  Run: `bash tests/run.sh`

  Expected: existing checks plus the new persistence checks pass.

### Task 2: Implement the DiskStore flush barrier

**Files:**
- Modify: `apps/macos/Desire/Storage/DiskStore.swift:35-78, 116-180`
- Modify: `apps/macos/Desire/App/DesireApp.swift:323-337` only if termination needs the new barrier result
- Test: `tests/main.swift`

**Interfaces:**
- `DiskStore.save` returns or records a monotonically increasing write generation internally.
- `DiskStoreWriter` exposes an actor-isolated barrier that waits for all encode tasks up to a generation and all writer tasks for that generation.

- [ ] **Step 1: Write a failing regression test for encode-before-flush**

  Block or delay encoding, call `DiskStore.flushSync()`, and assert that the barrier cannot complete before the delayed payload is staged. Also test `save → remove` and `remove → save` for one key.

- [ ] **Step 2: Track encode tasks and generations**

  Replace untracked `Task.detached` work with a tracked task/generation mechanism. The tracked task must always report encode failure to the writer diagnostics and must not silently let a later flush claim completion.

- [ ] **Step 3: Make writer ordering explicit**

  Ensure a late save cannot overwrite a newer remove, and a later save can intentionally recreate a removed key. Keep the existing debounce behavior for normal hot paths.

- [ ] **Step 4: Keep termination bounded and observable**

  Preserve the three-second cap, but log pending generations/keys when the timeout expires. Do not block ordinary Store operations on this barrier.

- [ ] **Step 5: Run focused and project verification**

  Run: `bash tests/run.sh`

  Expected: PASS.

  Run: `xcodebuild -project apps/macos/Desire.xcodeproj -scheme Desire -configuration Debug build`

  Expected: `BUILD SUCCEEDED`.

### Task 3: Add Agent turn ownership and cancellation regression coverage

**Files:**
- Modify: `apps/macos/Desire/Features/Agent/AgentSessionStore.swift:220-230, 790-850, 929-967, 1504-1597, 1600-2430`
- Modify: `apps/macos/Desire/Features/Agent/UserPromptCenter.swift` only if the prompt owner must carry a turn ID
- Modify: `tests/main.swift` only for pure turn-state helpers, if extracted
- Test: bridge/eval path in `tests/agent-eval.py` or a new deterministic Agent lifecycle fixture

**Interfaces:**
- `processLoop(turnID: UUID) async` owns one turn.
- `isCurrentTurn(_ turnID: UUID) -> Bool` is the only accepted guard for asynchronous turn write-back.
- `cancel()` invalidates the current turn before cancelling its task.

- [ ] **Step 1: Add a failing lifecycle regression**

  Drive `cancel → immediate send`, `clear → send`, and `loadConversation → send`; assert that only the new turn appends assistant/tool messages and that the final `isProcessing` state belongs to the new turn.

- [ ] **Step 2: Add `activeTurnID` and owner-aware task creation**

  Generate a UUID at each new/resumed turn, capture it in the Task closure, and invalidate it before starting a replacement turn.

- [ ] **Step 3: Guard every cross-await write-back**

  Apply the current-turn guard around streaming flushes, tool results, approval/askUser continuations, queued-turn transitions, post-work, completion handlers, and deferred cleanup. `Task.isCancelled` remains a cancellation check but is not an ownership check.

- [ ] **Step 4: Make cancellation complete only the owned turn**

  Ensure an old `defer` cannot clear a newer turn's `isProcessing`, `currentAction`, handlers, checkpoint, or messages. Preserve existing approval and prompt continuation resumption semantics.

- [ ] **Step 5: Run Agent evaluation and pure tests**

  Run: `bash tests/run.sh`

  Expected: PASS.

  Run: `python3 tests/agent-eval.py --cleanup` with the app started using the documented automation command.

  Expected: existing evaluation suite passes and lifecycle cases show no cross-turn messages.

### Task 4: Make Remote and sync registration operations atomic

**Files:**
- Modify: `crates/api/src/modules/remote/remote_service.rs:202-247, 355-395`
- Modify: `crates/api/src/modules/auth/auth_service.rs:173-206`
- Modify: `crates/api/src/modules/sync/sync_service.rs:296-322`
- Modify: `crates/common/migrations/` with a new incremental migration only if quota indexes/columns are required
- Test: `tools/api-remote-smoke.py` or a new `tools/api-concurrency-smoke.py`

**Interfaces:**
- `pairing_claim` performs one transactional claim and returns success only for the transaction that changed the unclaimed row.
- `inbox_take` locks rows before returning and deleting them.
- `key_check_set` and `key_escrow_set` accept the first value exactly once and reject a conflicting value.

- [ ] **Step 1: Add concurrent smoke cases before implementation**

  Launch two simultaneous claim requests for one code and two simultaneous pull requests for one frame. Assert one claim succeeds and one consumer receives the frame.

- [ ] **Step 2: Implement atomic pairing claim**

  Use a transaction with `SELECT ... FOR UPDATE`, or a conditional update with `claimed_at IS NULL` and an affected-row check. Publish the notification only after commit.

- [ ] **Step 3: Implement locked inbox take**

  Add `FOR UPDATE` to the bounded pending-row selection inside the existing transaction. Preserve at-most-once consumption and lane ordering.

- [ ] **Step 4: Implement first-writer-wins key registration**

  Make fingerprint and escrow registration conditional/transactional. A same-value retry remains idempotent; a different value returns conflict without partial writes.

- [ ] **Step 5: Add inbox quota and cleanup indexes if required by the schema**

  Bound pending rows and bytes per user/device/lane, return a rate/storage error when exceeded, and add an incremental migration for the TTL cleanup index. Preserve snapshot `replace=true` behavior.

- [ ] **Step 6: Run Rust verification**

  Run: `cargo fmt --check && cargo test --workspace && cargo build --workspace`

  Expected: all commands pass.

  Run: `python3 tools/api-remote-smoke.py` against the local dev API.

  Expected: existing remote smoke plus concurrency cases pass.

### Task 5: Centralize strict local bridge authentication

**Files:**
- Create: `apps/macos/Desire/App/BearerAuthentication.swift`
- Modify: `apps/macos/Desire/App/AutomationServer.swift:133-141`
- Modify: `apps/macos/Desire/App/MCPService.swift:36-44`
- Modify: `tests/run.sh`
- Modify: `tests/main.swift`

**Interfaces:**
- `BearerAuthentication.matches(header: String?, token: String) -> Bool` performs complete scheme/value matching.

- [ ] **Step 1: Add pure tests for the authentication parser**

  Test exact success, missing header, wrong token, configured-token prefix, extra suffix, wrong scheme, mixed-case `Bearer`, and duplicate/ambiguous authorization values.

- [ ] **Step 2: Implement the Foundation-only parser**

  Parse the scheme and credentials instead of using `contains`. Reject malformed or ambiguous values. Preserve the existing optional-token behavior when no token is configured.

- [ ] **Step 3: Replace both server-local implementations**

  Route AutomationServer and MCPService through the shared helper without changing ports, launch flags, or HTTP status semantics.

- [ ] **Step 4: Run pure tests and build**

  Run: `bash tests/run.sh`

  Expected: PASS.

  Run: `xcodebuild -project apps/macos/Desire.xcodeproj -scheme Desire clean build`

  Expected: no code warnings and `BUILD SUCCEEDED`.

### Task 6: Add Rust and release quality gates

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `scripts/release.sh:113-165`
- Create: `tools/api-ci-smoke.sh` only if the existing smoke scripts cannot run in CI
- Test: CI workflow validation and local command sequence

**Interfaces:**
- Rust CI job is independent of the Xcode job and blocks the main quality gate.
- Release prep stages only explicit version/changelog/website files and refuses unexpected dirty state according to the documented release workflow.

- [ ] **Step 1: Add Rust CI commands**

  Add a workspace job running `cargo fmt --check`, `cargo test --workspace`, `cargo build --workspace`, and the API smoke path with isolated test data.

- [ ] **Step 2: Make release staging explicit**

  Replace `git add -A` with an allowlist of files changed by version preparation, and fail if unrelated uncommitted changes are present unless the user explicitly confirms them.

- [ ] **Step 3: Add secret and artifact checks**

  Reject known secret files, `.env` variants, temporary test artifacts, and unexpected untracked files before the release commit path.

- [ ] **Step 4: Verify workflow scripts locally**

  Run: `bash -n scripts/release.sh tools/*.sh` for changed shell scripts, `cargo fmt --check`, and the existing release/changelog verification commands.

  Expected: all checks pass without creating a commit or tag.

### Task 7: Introduce `WindowBrowsingContext` and fix session identity

**Files:**
- Create: `apps/macos/Desire/Features/Browsing/WindowBrowsingContext.swift`
- Modify: `apps/macos/Desire/Views/ContentView.swift`
- Modify: `apps/macos/Desire/Features/Tabs/TabManager.swift`
- Modify: `apps/macos/Desire/Features/Profile/ProfileStore.swift`
- Modify: `apps/macos/Desire/App/SessionRestore.swift`
- Modify: `apps/macos/Desire/App/AppState.swift`
- Test: multi-window automation scenarios and session restore regression fixture

**Interfaces:**
- `@MainActor final class WindowBrowsingContext: ObservableObject` owns `windowID`, `sessionKey`, `profileID`, `profileDataStore`, and the window's tab manager/context accessors.
- `SessionRestore.Result` returns the adopted `sessionID` and `sessionKey` together.

- [ ] **Step 1: Add a failing two-window/Profile test**

  Open two windows, assign different profiles, create/login scoped state, duplicate and restore tabs, and assert each window resolves its own Profile data store and session key.

- [ ] **Step 2: Add the context without removing existing accessors**

  Construct it at the window composition root and route the existing TabManager/session values through it. Keep compatibility accessors temporarily so migration is incremental.

- [ ] **Step 3: Remove global current-window Profile semantics**

  Keep `ProfileStore` responsible for definitions and cached website stores. Move current Profile selection and scoped Store access to the window context; AppState must not change every window when one window changes profile.

- [ ] **Step 4: Migrate all Tab creation paths**

  Pass the context's `profileDataStore` through add, duplicate, restore, external-link, middle-click, split, and cross-window transfer paths.

- [ ] **Step 5: Fix SessionRestore return identity**

  Return the actual adopted identity after assigning `manager.sessionKey = lastKey`; update ContentView bindings and session coordinator registration from the structured result.

- [ ] **Step 6: Verify multi-window behavior**

  Run the documented automation bridge scenarios for two windows, Profile switching, session restore, background last-tab close, and cross-window tab transfer.

  Expected: no foreground window is closed accidentally and no session/profile data crosses windows.

### Task 8: Bind Agent, floating ball, prompts, and MCP to window contexts

**Files:**
- Modify: `apps/macos/Desire/Features/Agent/AgentBallPanel.swift`
- Modify: `apps/macos/Desire/Features/Agent/AgentBallOverlay.swift`
- Modify: `apps/macos/Desire/Features/Agent/UserPromptCenter.swift`
- Modify: `apps/macos/Desire/Views/ContentView.swift`
- Modify: `apps/macos/Desire/App/MCPService.swift`
- Modify: `apps/macos/Desire/App/AutomationServer.swift` only where window resolution is currently implicit
- Test: multi-window Agent/MCP/approval/prompt scenarios

**Interfaces:**
- `PendingUserQuestion` carries an owning `windowID`/conversation ID.
- MCP connection context stores its default window and allows a per-call window override.
- Agent ball callbacks are registered by window ID rather than overwriting one process-wide closure.

- [ ] **Step 1: Add failing cross-window ownership tests**

  Ask a question in window A while window B is key, click the floating ball in both windows, and issue MCP calls from two sessions. Assert each action reaches its declared owner.

- [ ] **Step 2: Replace global prompt ownership**

  Scope pending questions by Agent session/window. Only the owner renders and resolves a question; cancellation and timeout resume the matching continuation once.

- [ ] **Step 3: Replace singleton floating-ball callbacks**

  Register callbacks by `windowID` or instantiate a ball host per window. Resolve the target TabManager from the host context at action time.

- [ ] **Step 4: Make MCP sessions connection-scoped**

  Store state by MCP session/connection identifier, enforce the client session header, pass per-call window values to `AutomationServer.callEndpoint`, and filter events by the owning window.

- [ ] **Step 5: Run bridge and Agent regression suites**

  Run: `python3 tests/agent-eval.py --cleanup` plus the documented multi-window bridge scenarios.

  Expected: no cross-window prompt, ball action, MCP call, or event leakage.

### Task 9: Move Agent context preparation off MainActor

**Files:**
- Modify: `apps/macos/Desire/Features/Agent/AgentSessionStore.swift:1329-1410`
- Modify: `apps/macos/Desire/Features/Agent/ContextCompaction.swift`
- Create: `apps/macos/Desire/Features/Agent/ContextPreparation.swift` if a focused utility is needed
- Modify: `tests/run.sh`
- Modify: `tests/main.swift`

**Interfaces:**
- A Foundation-only preparation function accepts an immutable message snapshot and budget/revision, and returns prepared messages plus revision metadata.
- MainActor applies results only when the captured revision and conversation ID still match.

- [ ] **Step 1: Add pure performance/correctness tests**

  Assert compaction, repair, tool-result summarization, and huge-message capping are deterministic for the same snapshot; assert a stale revision is rejected by the apply guard.

- [ ] **Step 2: Extract preparation from AgentSessionStore**

  Keep page context, Keychain, Store access, and message publication on MainActor; move only pure snapshot transformation off actor isolation.

- [ ] **Step 3: Add cancellation propagation**

  Cancel the detached/actor work when a new turn or conversation arrives. Never allow stale prepared messages to overwrite current state.

- [ ] **Step 4: Verify streaming and long-context behavior**

  Run `bash tests/run.sh`, the 40 KB stream evaluation, and the documented main-thread probe.

  Expected: no stale result writes and no regression in tool-call repair or prompt composition.

### Task 10: Documentation, observability, and final verification

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/ROADMAP.md` only for completed status and new follow-ups
- Modify: `AGENTS.md` only if repository layout or verification rules changed
- Modify: relevant `CHANGELOG.md` Unreleased sections through `python3 scripts/changelog.py add ...`
- Test: all existing test/build/smoke commands

**Interfaces:**
- Documentation reflects current sandbox, target versions, file layout, and completed migration status.
- Logs identify pending DiskStore generations, Agent turn IDs, window IDs, and Remote/MCP session IDs without leaking secrets.

- [ ] **Step 1: Add diagnostic fields without sensitive payloads**

  Add structured identifiers and counts to existing `os.Logger`/`tracing` paths. Never log API keys, full tokens, message contents, or encrypted payloads.

- [ ] **Step 2: Update architecture and roadmap docs**

  Remove stale claims, record actual boundaries and completed phases, and document remaining thresholds rather than promising unimplemented behavior.

- [ ] **Step 3: Add changelog entries through the repository script**

  Use `python3 scripts/changelog.py add Fixed` or the appropriate type; do not manually rewrite the Unreleased header.

- [ ] **Step 4: Run final verification**

  Run:

  ```bash
  bash tests/run.sh
  cargo fmt --check
  cargo test --workspace
  cargo build --workspace
  xcodebuild -project apps/macos/Desire.xcodeproj -scheme Desire -configuration Release clean build 2>&1 | tee /tmp/desire-clean-build.log
  grep -E "warning:" /tmp/desire-clean-build.log
  ```

  Expected: all tests/builds pass; the warning scan contains no code warnings, with only the documented `appintentsmetadataprocessor` exception if present.

  Run the documented Agent eval, Remote smoke, API smoke, multi-window bridge scenarios, and two consecutive runs of the new concurrency/lifecycle tests.
