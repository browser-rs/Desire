# Screenshot (选区截图) — Design Spec

## Overview

Built-in area selection screenshot tool for Desire browser. WeChat-style workflow:
select region → annotate → copy to clipboard / save to Pictures.

## Architecture

```
Features/Screenshot/
├── Screenshot.swift              # Model types
├── ScreenshotStore.swift         # Store (state machine + capture + save)
├── ScreenshotOverlayView.swift   # Selection overlay (NSWindow/NSView)
├── ScreenshotEditorView.swift    # Annotation editor (toolbar + canvas)
```

### Three-Phase State Machine

| Phase | Description | UI |
|-------|-------------|----|
| `idle` | 未启动 | — |
| `selecting` | 用户拖拽选区 | Full-screen transparent NSPanel + crosshair |
| `editing(NSImage)` | 标注中 | Editor window: canvas + annotation tools |

Transitions:
```
idle → selecting     (startCapture())
selecting → idle     (Esc)
selecting → editing  (capture(rect:))
editing → idle       (save / copyToClipboard / discard)
editing → editing    (apply tool)
```

## Phase 1 — Selection Overlay

**OverlayWindow** (`NSPanel`, extends `NSWindow`):
- Style: `.nonactivatingPanel`, `.borderless`, `.fullScreen`
- Level: `.screenSaverWindow` (above everything)
- Background: clear, with semi-transparent dimming overlay drawn in `NSView.draw()`
- Cursor: crosshair (`NSCursor.crosshair`)

**Selection logic** (in overlay `NSView`):
- `mouseDown` → record start point
- `mouseDragged` → update drag rect → `needsDisplay = true`
- `mouseUp` → rect finalized
- Draw: dimmed background + bright selection rectangle + corner size label
- Keyboard: `Esc` → cancel, `Return` → confirm

**Confirm → capture**:
```
let cgImage = CGWindowListCreateImage(rect, .optionOnScreenBelowWindow, windowID, .nominalResolution)
let image = NSImage(cgImage: cgImage, size: rect.size)
```

## Phase 2 — Annotation Editor

**EditorWindow** (`NSWindow`):
- Title: "Screenshot"
- Fixed size matching captured image (up to ~80% of screen)
- Content: `ScreenshotEditorView` (SwiftUI)

**Toolbar** (horizontal, top of editor):
| Tool | Icon | Behavior |
|------|------|----------|
| Select | arrow.pointer | 选取已有标注 |
| Rectangle | rectangle | Drag to draw rectangle (border fill) |
| Ellipse | circle | Drag to draw ellipse |
| Arrow | arrow.right | Drag → arrowhead at end |
| Pen | scribble | Freehand drawing |
| Text | textformat | Click to place text field |
| Blur | circle.dotted | Drag to mark blur region |
| Number | textformat.123 | Click to place numbered circle |
| Color | circle.hexagonpath | Color picker popover |
| Undo | arrow.uturn.left | Pop last annotation |
| Clear | trash | Remove all annotations |
| Crop | crop | Drag crop rect, confirm to trim |
| Rotate | rotate.right | Rotate 90° clockwise |

**Drawing canvas:**
- `NSImageView` for background (captured image)
- Overlay `NSView` subclass with `draw()` for annotations
- Each annotation stored as protocol `ScreenshotAnnotation`:
  - `RectAnnotation`, `EllipseAnnotation`, `ArrowAnnotation`, `PenAnnotation`,
    `TextAnnotation`, `BlurAnnotation`, `NumberAnnotation`
- Undo: `[ScreenshotAnnotation]` stack, pop on undo

**Text input:**
- `NSTextView` placed on canvas, Enter to confirm
- Supports font size, color from current tool color

**Blur:**
- `CIFilter(name: "CIGaussianBlur")` applied to the region

**Crop:**
- Temporary overlay similar to selection phase
- Cropped with `CGImage.cropping(to:)`

**Rotate:**
- `NSImage` rotated via `CGImage` + `CGContext`

## Phase 3 — Output

- **Copy to Clipboard**: `NSPasteboard.general.clearContents()` + `writeObjects([image])`
- **Save to Pictures**: `FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first`
  - Filename: `"Screenshot_YYYY-MM-DD_HHmmss.png"`
  - Configurable directory via Settings (`ScreenshotStore.saveDirectory`)

## Entry Points

1. **Toolbar button** — new `CapsuleButton` with `camera.viewfinder` icon in Toolbar's nav group
2. **Keyboard shortcut** — `Cmd+Shift+4` (new `BrowserCommand.screenshot`)
3. **More Menu item** — "Screenshot…" in the toolbar popover

## Settings Integration

In `SettingsView` → Shortcuts tab: add "Screenshot" shortcut description.
In `SettingsView` → General tab: add "Screenshot save location" with path picker.

## Files Modified

| File | Change |
|------|--------|
| `Toolbar.swift` | Add screenshot CapsuleButton + moreMenuItem |
| `ContentView.swift` | Wire BrowserCommand.screenshot |
| `DesireApp.swift` | Add shortcut for screenshot |
| `SettingsView.swift` | Add save directory picker |
| `Localizable.xcstrings` | Add screenshot-related strings |

## New Files Created

| File | Purpose |
|------|---------|
| `Features/Screenshot/Screenshot.swift` | Model: ScreenshotAnnotation protocol + concrete types |
| `Features/Screenshot/ScreenshotStore.swift` | Store: phase state machine, capture/save/clipboard logic |
| `Features/Screenshot/ScreenshotOverlayView.swift` | NSViewRepresentable for selection overlay |
| `Features/Screenshot/ScreenshotEditorView.swift` | SwiftUI editor: toolbar + annotation canvas |

## Open Questions (resolved)

- **Full annotation tool set**: Rich (rect, ellipse, arrow, pen, text, blur, number, color, undo, clear, crop, rotate)
- **Entry**: Toolbar button + Cmd+Shift+4
- **Default save**: Pictures directory, configurable in Settings
- **Output**: Both clipboard copy and file save
