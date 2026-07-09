# Responsive Design Mode Enhancement — Design Spec

## Overview

Enhance the current responsive design mode from a minimal implementation (5 Apple-only presets, framed viewport) into a full-featured responsive debugging tool: 20+ cross-platform device presets, device bezel rendering, draggable viewport resize, orientation toggle, ruler overlay, touch event simulation, media query inspector, network throttling simulation, and viewport screenshot.

## Architecture

### Double-Layer Separation

**Global singleton** (`ResponsiveDesignStore`): manages the preset database (full device list, categories, custom preset persistence).

**Per-tab config** (`Tab.responsiveConfig: ResponsiveConfig`): per-instance responsive state — each tab can independently enter/exit responsive mode with its own settings.

### File Layout

```
Features/ResponsiveDesign/
├── ResponsiveDesignStore.swift    # Global store (preset management, persistence)
├── ResponsiveConfig.swift         # Per-tab config struct
├── DevicePreset.swift             # Enhanced model
├── ResponsiveDesignBar.swift      # Top bar (enhanced)
├── DeviceFrameOverlay.swift       # Device bezel + drag handles overlay
├── RulerOverlay.swift             # Ruler overlay
├── MediaQueryInspector.swift      # Media query status panel
├── ThrottlePreset.swift           # Network throttle enum
└── TouchSimulation.swift          # Touch simulation JS injection
```

## Model Layer

### DevicePreset (enhanced)

```swift
enum DeviceCategory: String, CaseIterable, Codable {
    case phone, foldable, tablet, desktop, watch
}

struct DevicePreset: Identifiable, Codable {
    let id: UUID
    let name: String
    let width: Int
    let height: Int
    let icon: String          // SF Symbol name
    let category: DeviceCategory
    let frameAssetName: String? // nil = no bezel rendering
    let isFoldable: Bool       // if true, has unfoldedSize
    let unfoldedSize: CGSize?  // foldable unfolded dimensions
}
```

### Device Presets (full list)

| Category | Device | Size |
|----------|--------|------|
| Phone | iPhone SE | 375×667 |
| Phone | iPhone 14 Pro | 390×844 |
| Phone | iPhone 14 Pro Max | 430×932 |
| Phone | Samsung Galaxy S24 | 360×780 |
| Phone | Google Pixel 9 | 393×852 |
| Phone | Google Pixel 9 Pro | 393×852 |
| Foldable | Galaxy Z Fold 6 (folded) | 374×512 |
| Foldable | Galaxy Z Fold 6 (unfolded) | 717×512 |
| Foldable | Galaxy Z Flip 6 | 375×812 |
| Foldable | Pixel Fold (folded) | 373×556 |
| Foldable | Pixel Fold (unfolded) | 746×556 |
| Foldable | Surface Duo | 540×720 |
| Tablet | iPad 10 | 820×1180 |
| Tablet | iPad Pro 12.9" | 1024×1366 |
| Tablet | Galaxy Tab S9 | 800×1280 |
| Tablet | Surface Pro | 1440×960 |
| Desktop | HD | 1366×768 |
| Desktop | WXGA+ | 1440×900 |
| Desktop | Full HD | 1920×1080 |
| Desktop | QHD | 2560×1440 |
| Watch | Apple Watch 45mm | 396×484 |
| Watch | Apple Watch 41mm | 352×430 |

### ResponsiveConfig

```swift
struct ResponsiveConfig {
    var isEnabled = false
    var selectedPreset: DevicePreset?
    var customSize = CGSize(width: 375, height: 667)
    var orientation: ResponsiveOrientation = .portrait
    var showRulers = false
    var showMediaQueryInspector = false
    var networkThrottle: ThrottlePreset = .none
    var pixelRatio: Double = 2.0
    var touchSimulationEnabled = false

    var effectiveSize: CGSize {
        if let preset = selectedPreset {
            return orientation == .portrait
                ? CGSize(width: preset.width, height: preset.height)
                : CGSize(width: preset.height, height: preset.width)
        }
        return orientation == .portrait ? customSize : CGSize(width: customSize.height, height: customSize.width)
    }
}
```

### Orientation

```swift
enum ResponsiveOrientation: String, CaseIterable, Codable {
    case portrait, landscape
}
```

### ThrottlePreset

```swift
enum ThrottlePreset: String, CaseIterable, Codable {
    case none, slow3G, fast3G, offline
}
```

Network throttling in WKWebView is limited on macOS. Implementation options:
- Slow 3G: ~100 Kbps, 500ms latency (simulated via delayed WKNavigationDelegate callbacks + custom URLProtocol)
- Fast 3G: ~1.5 Mbps, 200ms latency
- Offline: prevent network requests via URLProtocol returning errors
- Note: True bandwidth limiting is not supported by WKWebView APIs; this is a best-effort simulation

## Store Layer

### ResponsiveDesignStore

```swift
@MainActor
class ResponsiveDesignStore: ObservableObject {
    @Published var allPresets: [DevicePreset]  // full list
    @Published var customPresets: [DevicePreset] // user-saved custom presets

    func presets(for category: DeviceCategory) -> [DevicePreset]
    func saveCustomPreset(_ preset: DevicePreset)
    func deleteCustomPreset(_ preset: DevicePreset)
}
```

- Persists custom presets in UserDefaults
- Provides filtered views of presets by category
- No per-tab state — that stays in `ResponsiveConfig`

## View Layer

### ResponsiveDesignBar (enhanced)

Layout (compact HStack):
1. `← Exit` button
2. Device category pills (Phone / Fold / Tablet / Desktop / Watch) — selected category highlighted
3. Preset buttons within selected category (scrollable)
4. Orientation toggle `🔄`
5. Custom size fields (W × H)
6. Dimension label
7. Action shortcut toggles: `📐 Rulers` / `📷 Screenshot` / `📱 Touch` / `📊 Media Q`
8. Throttle dropdown (None / Slow 3G / Fast 3G / Offline)

Each toggle button is a small pill with icon, showing active state with tint color.

### DeviceFrameOverlay

Renders device bezel around the framed web view:
- Phone presets: rounded rectangle with notch/dynamic island indicator at top
- Tablet/desktop: simple thin border
- Watch: circular-ish frame

Drag handles on edges and corners for resizing:
- 4 edge handles (midpoint): resize one dimension
- 4 corner handles: resize both dimensions
- Bottom-right corner handle slightly larger with `↘` icon
- Handle size: ~12×12pt for corners, ~30×4pt for edges
- Cursor changes per handle (ns-resize, ew-resize, nwse-resize, nesw-resize)
- On drag: update `ResponsiveConfig.customSize`, deselect any preset

Implementation: SwiftUI overlay with DragGesture on each handle.

### RulerOverlay

- Top ruler: horizontal measurements matching viewport width
- Left ruler: vertical measurements matching viewport height
- Ruler height: 20pt
- Tick marks every 50px with labels at 0, 50, 100...
- Styled similarly to Xcode editor rulers
- Only shown when `config.showRulers == true`

### MediaQueryInspector

- Side panel (right side of viewport, ~240pt wide) or bottom sheet
- Injects JS: `[...document.styleSheets].flatMap(s => [...s.cssRules].filter(r => r.media))` → extracts all CSS media queries
- Evaluates each: `window.matchMedia(query).matches`
- Displays list with active/inactive indicator
- Updates on orientation/resize changes
- Only shown when `config.showMediaQueryInspector == true`

### TouchSimulation

- Injects JS on toggle:
  - `* { cursor: crosshair !important; touch-action: none; }`
  - Maps `mousedown` → `touchstart`, `mousemove` → `touchmove`, `mouseup` → `touchend`
  - Renders touch ripple effect (CSS animation on a temporary div)
  - Touch radius: ~20px
- Reverts JS on toggle off

### Viewport Screenshot

- Uses WKWebView `takeSnapshot(config:)` with the responsive viewport's exact frame
- Saves to Downloads folder or clipboard
- Triggered from bar button or keyboard shortcut

## ContentView Integration

Changes to `ContentView.swift`:

```
@StateObject private var responsiveDesignStore = ResponsiveDesignStore()
```

- ResponsiveDesignBar replaces the current inline responsive bar check
- Tab.responsiveConfig replaces Tab.isResponsiveMode / Tab.responsiveSize
- Web view gets additional overlays (device frame, rulers, drag handles, media query inspector)
- Network throttling hooks into WKNavigationDelegate

## Migration Path

1. Add `ResponsiveConfig` struct and `ResponsiveDesignStore` class (no functional change)
2. Add `var responsiveConfig = ResponsiveConfig()` to Tab
3. Keep `isResponsiveMode` and `responsiveSize` as computed properties for backward compat (or migrate all callers in one pass)
4. Replace ContentView inline bar with enhanced `ResponsiveDesignBar`
5. Build features incrementally

## Implementation Phases

### Phase 1: Foundation + Presets + Device Frames + Drag + Orientation
- Create all new model files
- Create `ResponsiveDesignStore` with 20+ presets
- Create `ResponsiveConfig`, migrate Tab state
- Enhance `ResponsiveDesignBar` with categories, orientation
- Build `DeviceFrameOverlay` with drag handles

### Phase 2: View Helpers
- `RulerOverlay`
- Touch simulation JS injection
- Viewport screenshot

### Phase 3: Dev Tools
- `MediaQueryInspector` panel + JS bridge
- Network throttling simulation (URLProtocol-based)

## Open Questions

1. Network throttling: WKWebView has no native bandwidth limiting API on macOS. Evaluate URLProtocol approach vs. simple notification banner ("Throttling enabled — real device testing recommended").
2. Media query inspector: needs `WKUserContentController` message handler for JS → Swift communication. Ensure no conflict with existing handlers.
3. Device frame assets: use SF Symbols programmatic shapes vs. static image assets.
