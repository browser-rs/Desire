# Desire — macOS Browser (SwiftUI)

## Project structure

- **macOS app** (`SDKROOT = macosx`) — not iOS. Target: macOS 26.5.
- Entrypoint: `Desire/DesireApp.swift:11` (`@main struct DesireApp`)
- Xcode 26.6, Swift 5.0, file-system-synchronized group (all `.swift` files under `Desire/` are auto-included).
- No package dependencies, no SPM, no test targets.

## Build & run

Open `Desire.xcodeproj` in Xcode and build (⌘B) or run (⌘R).
CLI build: `xcodebuild -project Desire.xcodeproj -scheme Desire build`

**Always build before reporting completion.** Unverified claims are unacceptable.

## Key conventions

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — prefer `@MainActor` on observable types.
- Strict concurrency checking is on (`SWIFT_APPROACHABLE_CONCURRENCY = YES`).
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` — each file must `import` every framework it uses directly (e.g. `import WebKit` for `WKWebView`, `import Combine` for `ObservableObject`). Cross-module re-exports are not visible.
- App Sandbox is enabled with `ENABLE_USER_SELECTED_FILES = readonly` — file access must use `NSOpenPanel`/`NSOpenPanel` URLs and scoped bookmarks.
- Hardened Runtime is enabled.
- `COMBINE_HIDPI_IMAGES = YES` — use `@2x` asset variants for Retina.
- Bundle ID: `me.siwi.Desire`, team: `F8JZTX6J52`.

## Browser-specific context

Building a web browser on macOS. Consider:
- `WKWebView` for page rendering
- App Sandbox with `com.apple.security.network.client` entitlement for web access
- `ENABLE_USER_SELECTED_FILES = readonly` limits file access — downloads need `NSDownloadsDirectory` or user-selected save locations
- String catalogs (`LOCALIZATION_PREFERS_STRING_CATALOGS = YES`) for localization
