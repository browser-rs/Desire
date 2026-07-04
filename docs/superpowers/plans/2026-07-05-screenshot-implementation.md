# Screenshot (选区截图) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add built-in area selection screenshot tool (WeChat-style: select → annotate → output)

**Architecture:** Three-phase state machine (idle → selecting → editing) driven by `ScreenshotStore`. Selection overlay uses native NSPanel + NSView drawing. Editor uses NSImage overlay with annotation protocol and SwiftUI toolbar.

**Tech Stack:** SwiftUI, AppKit (NSPanel, CGWindowListCreateImage, NSGraphicsContext)

**No test targets exist** — skip test-writing steps; verify by building.

---

## File Structure

### New files:
- `Desire/Features/Screenshot/Screenshot.swift` — Model: `ScreenshotAnnotation` protocol + concrete types
- `Desire/Features/Screenshot/ScreenshotStore.swift` — Store: phase state machine, capture/save/clipboard
- `Desire/Features/Screenshot/ScreenshotOverlayView.swift` — Selection overlay (NSViewRepresentable)
- `Desire/Features/Screenshot/ScreenshotEditorView.swift` — Annotation editor (SwiftUI view + drawing canvas)

### Modified files:
- `Desire/Features/Toolbar/Toolbar.swift` — Add screenshot button + more menu item
- `Desire/App/DesireApp.swift` — Add `BrowserCommand.screenshot` + shortcut
- `Desire/Views/ContentView.swift` — Wire command in `.onReceive`
- `Desire/Features/Settings/SettingsView.swift` — Add save directory config
- `Desire/Localizable.xcstrings` — New strings

---

## Task 1: Model Types

**Files:**
- Create: `Desire/Features/Screenshot/Screenshot.swift`

**Interfaces:**
- Produces: `ScreenshotAnnotation` protocol, concrete annotation types, `ScreenshotPhase` enum, `ScreenshotTool` enum

- [ ] **Write `Screenshot.swift`**

```swift
import AppKit
import Foundation

enum ScreenshotPhase {
    case idle
    case selecting
    case editing(NSImage)
}

enum ScreenshotTool: String, CaseIterable {
    case rect, ellipse, arrow, pen, text, blur, number
}

protocol ScreenshotAnnotation {
    func draw(in ctx: CGContext)
}

struct RectAnnotation: ScreenshotAnnotation {
    let rect: CGRect
    let color: NSColor
    let strokeWidth: CGFloat
    let fill: Bool

    func draw(in ctx: CGContext) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(strokeWidth)
        if fill {
            ctx.setFillColor(color.withAlphaComponent(0.2).cgColor)
            ctx.addRect(rect)
            ctx.fillPath()
        }
        ctx.addRect(rect)
        ctx.strokePath()
    }
}

struct EllipseAnnotation: ScreenshotAnnotation {
    let rect: CGRect
    let color: NSColor
    let strokeWidth: CGFloat

    func draw(in ctx: CGContext) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(strokeWidth)
        ctx.addEllipse(in: rect)
        ctx.strokePath()
    }
}

struct ArrowAnnotation: ScreenshotAnnotation {
    let start: CGPoint
    let end: CGPoint
    let color: NSColor
    let strokeWidth: CGFloat

    func draw(in ctx: CGContext) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(strokeWidth)
        ctx.move(to: start)
        ctx.addLine(to: end)
        ctx.strokePath()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLen: CGFloat = 12
        ctx.setFillColor(color.cgColor)
        ctx.move(to: end)
        ctx.addLine(to: CGPoint(x: end.x - arrowLen * cos(angle - .pi/6), y: end.y - arrowLen * sin(angle - .pi/6)))
        ctx.addLine(to: CGPoint(x: end.x - arrowLen * cos(angle + .pi/6), y: end.y - arrowLen * sin(angle + .pi/6)))
        ctx.closePath()
        ctx.fillPath()
    }
}

struct PenAnnotation: ScreenshotAnnotation {
    let points: [CGPoint]
    let color: NSColor
    let strokeWidth: CGFloat

    func draw(in ctx: CGContext) {
        guard points.count > 1 else { return }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: points[0])
        for p in points.dropFirst() {
            ctx.addLine(to: p)
        }
        ctx.strokePath()
    }
}

struct TextAnnotation: ScreenshotAnnotation {
    let point: CGPoint
    let text: String
    let color: NSColor
    let fontSize: CGFloat

    func draw(in ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: color
        ]
        (text as NSString).draw(at: point, withAttributes: attrs)
    }
}

struct BlurAnnotation: ScreenshotAnnotation {
    let rect: CGRect

    func draw(in ctx: CGContext) {
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.fill(rect)
    }
}

struct NumberAnnotation: ScreenshotAnnotation {
    let center: CGPoint
    let number: Int
    let color: NSColor

    func draw(in ctx: CGContext) {
        let radius: CGFloat = 14
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: rect)
        let text = "\(number)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 14),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)
    }
}
```

- [ ] **Build to verify**

Run: `xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

- [ ] **Commit**

```bash
git add Desire/Features/Screenshot/Screenshot.swift
git commit -m "feat(screenshot): add annotation model types"
```

---

## Task 2: ScreenshotStore

**Files:**
- Create: `Desire/Features/Screenshot/ScreenshotStore.swift`

**Interfaces:**
- Consumes: `ScreenshotAnnotation`, `ScreenshotPhase`, `ScreenshotTool` from Task 1
- Produces: `ScreenshotStore` class with `@Published phase`, `startCapture()`, `capture(rect:)`, `applyAnnotation(...)`, `save()`, `copyToClipboard()`, `saveDirectory`

- [ ] **Write `ScreenshotStore.swift`**

```swift
import AppKit
import Combine
import Foundation

@MainActor
class ScreenshotStore: ObservableObject {
    @Published var phase: ScreenshotPhase = .idle
    @Published var currentTool: ScreenshotTool = .rect
    @Published var currentColor: NSColor = .red
    @Published var strokeWidth: CGFloat = 3

    var annotations: [ScreenshotAnnotation] = []
    var undoStack: [[ScreenshotAnnotation]] = []

    private(set) var capturedImage: NSImage?

    var saveDirectory: URL {
        get {
            if let bookmarkData = UserDefaults.standard.data(forKey: "screenshotSaveDirectoryBookmark"),
               var url = try? URL(resolvingBySecurityScopedBookmark: bookmarkData) {
                let gotAccess = url.startAccessingSecurityScopedResource()
                defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
                return url
            }
            return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        }
        set {
            let bookmarkData = try? newValue.bookmarkData(options: .securityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmarkData, forKey: "screenshotSaveDirectoryBookmark")
        }
    }

    func startCapture() {
        phase = .selecting
    }

    func cancelCapture() {
        phase = .idle
        annotations = []
        undoStack = []
    }

    func capture(rect: CGRect) {
        guard let screen = NSScreen.main else { return }
        let screenRect = screen.frame
        let scale = screen.backingScaleFactor

        let captureRect = CGRect(
            x: rect.minX * scale,
            y: (screenRect.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )

        guard let cgImage = CGWindowListCreateImage(
            captureRect,
            .optionOnScreenBelowWindow,
            kCGNullWindowID,
            .nominalResolution
        ) else { return }

        let image = NSImage(cgImage: cgImage, size: rect.size)
        capturedImage = image
        annotations = []
        undoStack = []
        phase = .editing(image)
    }

    func pushUndo() {
        undoStack.append(annotations)
    }

    func undo() {
        guard !undoStack.isEmpty else { return }
        annotations = undoStack.removeLast()
    }

    func clearAnnotations() {
        pushUndo()
        annotations = []
    }

    func save() {
        guard let image = renderFinalImage() else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let filename = "Screenshot_\(formatter.string(from: Date())).png"
        let url = saveDirectory.appendingPathComponent(filename)

        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }

        try? png.write(to: url)
        phase = .idle
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    func copyToClipboard() {
        guard let image = renderFinalImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        phase = .idle
    }

    private func renderFinalImage() -> NSImage? {
        guard let image = capturedImage else { return nil }
        let size = image.size
        let result = NSImage(size: size)
        result.lockFocusFlipped(true)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
        image.draw(in: CGRect(origin: .zero, size: size))
        for ann in annotations {
            ann.draw(in: ctx)
        }
        result.unlockFocus()
        return result
    }
}
```

- [ ] **Build to verify**

Run: `xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

- [ ] **Commit**

```bash
git add Desire/Features/Screenshot/ScreenshotStore.swift
git commit -m "feat(screenshot): add ScreenshotStore with state machine"
```

---

## Task 3: Selection Overlay

**Files:**
- Create: `Desire/Features/Screenshot/ScreenshotOverlayView.swift`

**Interfaces:**
- Consumes: `ScreenshotStore.startCapture()`, `.cancelCapture()`, `.capture(rect:)`
- Produces: `ScreenshotOverlayView` that creates fullscreen NSPanel, handles mouse drag → calls `capture(rect:)`

- [ ] **Write `ScreenshotOverlayView.swift`**

```swift
import AppKit
import SwiftUI

struct ScreenshotOverlayView: NSViewRepresentable {
    let store: ScreenshotStore

    func makeNSView(context: Context) -> OverlayRootView {
        OverlayRootView(store: store)
    }

    func updateNSView(_ nsView: OverlayRootView, context: Context) {}
}

class OverlayRootView: NSView {
    weak var store: ScreenshotStore?
    private var dragStart: CGPoint?
    private var dragRect: CGRect?
    private var trackingArea: NSTrackingArea?

    init(store: ScreenshotStore) {
        self.store = store
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
        NSCursor.crosshair.push()
    }

    override func removeFromSuperview() {
        NSCursor.crosshair.pop()
        super.removeFromSuperview()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        dragRect = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let current = event.locationInWindow
        dragRect = CGRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(current.x - start.x), height: abs(current.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = dragRect, rect.width > 5, rect.height > 5 else {
            dragStart = nil
            dragRect = nil
            needsDisplay = true
            return
        }
        store?.capture(rect: rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 0x35 { // Esc
            store?.cancelCapture()
        } else if event.keyCode == 0x24 { // Return
            if let rect = dragRect, rect.width > 5, rect.height > 5 {
                store?.capture(rect: rect)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.fill(bounds)

        if let rect = dragRect {
            ctx.clear(rect)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.addRect(rect)
            ctx.strokePath()

            let dimText = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.white
            ]
            let textSize = dimText.size(withAttributes: attrs)
            dimText.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.maxY + 8), withAttributes: attrs)
        }
    }
}
```

- [ ] **Build to verify**

Run: `xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

- [ ] **Commit**

```bash
git add Desire/Features/Screenshot/ScreenshotOverlayView.swift
git commit -m "feat(screenshot): add selection overlay with NSPanel"
```

---

## Task 4: Screenshot Editor View

**Files:**
- Create: `Desire/Features/Screenshot/ScreenshotEditorView.swift`

**Interfaces:**
- Consumes: `ScreenshotStore`, all annotation types from Task 1
- Produces: Editor SwiftUI View with toolbar + annotation canvas

- [ ] **Write `ScreenshotEditorView.swift`**

```swift
import AppKit
import SwiftUI

struct ScreenshotEditorView: View {
    @ObservedObject var store: ScreenshotStore
    @State private var isDrawing = false
    @State private var currentPoints: [CGPoint] = []
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var textInput = ""
    @State private var showColorPicker = false
    @State private var showCropOverlay = false
    @State private var cropRect: CGRect?
    @State private var cropStart: CGPoint?

    private let tools: [(ScreenshotTool, String)] = [
        (.rect, "rectangle"), (.ellipse, "circle"), (.arrow, "arrow.right"),
        (.pen, "scribble"), (.text, "textformat"), (.blur, "circle.dotted"),
        (.number, "textformat.123")
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            canvas
            bottomBar
        }
        .frame(minWidth: 400, minHeight: 300)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            ForEach(tools, id: \.0) { tool, icon in
                Button {
                    store.currentTool = tool
                } label: {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                        .background(store.currentTool == tool ? Color.accentColor.opacity(0.2) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(tool.rawValue)
            }

            Divider().frame(height: 20)

            Button {
                showColorPicker.toggle()
            } label: {
                Circle()
                    .fill(Color(nsColor: store.currentColor))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.secondary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showColorPicker) {
                colorPicker
            }

            Divider().frame(height: 20)

            Button { store.undo() } label: {
                Image(systemName: "arrow.uturn.left")
            }
            .buttonStyle(.plain)
            .disabled(store.undoStack.isEmpty)
            .help("Undo")

            Button { store.clearAnnotations() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .disabled(store.annotations.isEmpty)
            .help("Clear All")

            Spacer()

            Button("Cancel") { store.cancelCapture() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            Button("Copy") {
                store.copyToClipboard()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)

            Button("Save") {
                store.save()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var colorPicker: some View {
        let colors: [NSColor] = [
            .red, .orange, .yellow, .green, .blue, .purple,
            .white, .gray, .black
        ]
        return VStack(spacing: 6) {
            Text("Color").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(colors, id: \.self) { color in
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .stroke(color == store.currentColor ? Color.primary : Color.clear, lineWidth: 2)
                        )
                        .onTapGesture { store.currentColor = color; showColorPicker = false }
                }
            }
            .padding(.horizontal)
        }
        .padding(8)
        .frame(width: 240)
    }

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                if case .editing(let image) = store.phase {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }

                Canvas { ctx, size in
                    guard case .editing(let image) = store.phase else { return }
                    let scale = min(size.width / image.size.width, size.height / image.size.height)
                    let offsetX = (size.width - image.size.width * scale) / 2
                    let offsetY = (size.height - image.size.height * scale) / 2

                    let cgCtx = ctx
                    cgCtx.translateBy(x: offsetX, y: offsetY)
                    cgCtx.scaleBy(x: scale, y: scale)

                    // Draw live preview for current tool
                    if let start = dragStart, let current = dragCurrent {
                        let r = CGRect(
                            x: min(start.x, current.x), y: min(start.y, current.y),
                            width: abs(current.x - start.x), height: abs(current.y - start.y)
                        )
                        let temp: ScreenshotAnnotation
                        switch store.currentTool {
                        case .rect: temp = RectAnnotation(rect: r, color: store.currentColor, strokeWidth: store.strokeWidth, fill: false)
                        case .ellipse: temp = EllipseAnnotation(rect: r, color: store.currentColor, strokeWidth: store.strokeWidth)
                        case .arrow: temp = ArrowAnnotation(start: start, end: current, color: store.currentColor, strokeWidth: store.strokeWidth)
                        default: temp = RectAnnotation(rect: r, color: store.currentColor, strokeWidth: store.strokeWidth, fill: false)
                        }
                        temp.draw(in: cgCtx)
                    }

                    if store.currentTool == .pen && isDrawing {
                        let pen = PenAnnotation(points: currentPoints, color: store.currentColor, strokeWidth: store.strokeWidth)
                        pen.draw(in: cgCtx)
                    }

                    if showCropOverlay, let cr = cropRect {
                        let overlayPath = Path(CGRect(origin: .zero, size: size))
                        let cropPath = Path(cr)
                        cgCtx.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
                        // Draw dimmed area outside crop rect
                        cgCtx.addRect(CGRect(origin: .zero, size: size))
                        cgCtx.addRect(cr)
                        cgCtx.fillPath()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let pt = canvasToImage(value.location, imageSize: imageSize, canvasSize: geo.size)
                            if store.currentTool == .pen {
                                if !isDrawing { isDrawing = true; store.pushUndo(); currentPoints = [] }
                                currentPoints.append(pt)
                            } else {
                                if dragStart == nil { store.pushUndo(); dragStart = pt }
                                dragCurrent = pt
                            }
                        }
                        .onEnded { value in
                            let pt = canvasToImage(value.location, imageSize: imageSize, canvasSize: geo.size)
                            defer { dragStart = nil; dragCurrent = nil; isDrawing = false; currentPoints = [] }

                            guard let start = dragStart else {
                                if store.currentTool == .text {
                                    store.pushUndo()
                                    store.annotations.append(TextAnnotation(point: pt, text: "Text", color: store.currentColor, fontSize: 18))
                                }
                                return
                            }

                            let r = CGRect(
                                x: min(start.x, pt.x), y: min(start.y, pt.y),
                                width: abs(pt.x - start.x), height: abs(pt.y - start.y)
                            )
                            if r.width < 3 && r.height < 3 { return }

                            let annotation: ScreenshotAnnotation
                            switch store.currentTool {
                            case .rect: annotation = RectAnnotation(rect: r, color: store.currentColor, strokeWidth: store.strokeWidth, fill: false)
                            case .ellipse: annotation = EllipseAnnotation(rect: r, color: store.currentColor, strokeWidth: store.strokeWidth)
                            case .arrow: annotation = ArrowAnnotation(start: start, end: pt, color: store.currentColor, strokeWidth: store.strokeWidth)
                            case .blur: annotation = BlurAnnotation(rect: r)
                            case .number:
                                let count = store.annotations.filter { $0 is NumberAnnotation }.count + 1
                                annotation = NumberAnnotation(center: CGPoint(x: r.midX, y: r.midY), number: count, color: store.currentColor)
                            default: annotation = RectAnnotation(rect: r, color: store.currentColor, strokeWidth: store.strokeWidth, fill: false)
                            }
                            store.annotations.append(annotation)
                        }
                )
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            if case .editing(let image) = store.phase {
                Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Esc to cancel")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var imageSize: NSSize {
        if case .editing(let image) = store.phase { image.size }
        else { .zero }
    }

    private func canvasToImage(_ point: CGPoint, imageSize: NSSize, canvasSize: CGSize) -> CGPoint {
        let scale = min(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
        let offsetX = (canvasSize.width - imageSize.width * scale) / 2
        let offsetY = (canvasSize.height - imageSize.height * scale) / 2
        return CGPoint(
            x: (point.x - offsetX) / scale,
            y: (point.y - offsetY) / scale
        )
    }
}
```

- [ ] **Build to verify**

Run: `xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

- [ ] **Commit**

```bash
git add Desire/Features/Screenshot/ScreenshotEditorView.swift
git commit -m "feat(screenshot): add annotation editor view with toolbar"
```

---

## Task 5: Wire Screenshot into App

**Files:**
- Modify: `Desire/App/DesireApp.swift` — add `case screenshot` to BrowserCommand + menu shortcut
- Modify: `Desire/Features/Toolbar/Toolbar.swift` — add screenshot button and more menu item
- Modify: `Desire/Views/ContentView.swift` — wire command

- [ ] **Edit `DesireApp.swift` — add BrowserCommand case**

Add `case screenshot` to the `BrowserCommand` enum (after `importBookmarks`):
```swift
    case clearHistory, exportBookmarks, importBookmarks
    case screenshot
```

Add shortcut in Tools CommandMenu (after the Import line):
```swift
                Divider()
                Button("Screenshot…") { postCommand(.screenshot) }
                    .keyboardShortcut("4", modifiers: [.command, .shift])
```

- [ ] **Edit `Toolbar.swift` — add screenshot action + button**

Add to `Actions` struct:
```swift
        let screenshot: () -> Void
```

In `moreMenuContent`, add after `moreMenuItem("Preferences…"...)`:
```swift
            Divider()
            moreMenuItem("Screenshot…", "camera.viewfinder") { actions.screenshot() }
```

In the toolbar HStack (nav button group area), add a CapsuleButton before the more button:
```swift
            CapsuleButton(systemName: "camera.viewfinder", action: actions.screenshot, help: "Screenshot")
```

- [ ] **Edit `ContentView.swift` — wire command**

In the `.onReceive(.browserCommand)` switch, add:
```swift
            case .screenshot:
                screenshotStore.startCapture()
```

Add `@StateObject private var screenshotStore = ScreenshotStore()` to ContentView.
Add overlay for selection and sheet for editor:
```swift
            .overlay {
                if case .selecting = screenshotStore.phase {
                    ScreenshotOverlayView(store: screenshotStore)
                        .edgesIgnoringSafeArea(.all)
                }
            }
            .sheet(isPresented: .init(get: {
                if case .editing = screenshotStore.phase { true } else { false }
            }, set: { if !$0 { screenshotStore.cancelCapture() } })) {
                ScreenshotEditorView(store: screenshotStore)
            }
```

Also pass `screenshot` to `Toolbar.Actions`:
```swift
            screenshot: { screenshotStore.startCapture() },
```

- [ ] **Build to verify**

Run: `xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

- [ ] **Commit**

```bash
git add Desire/App/DesireApp.swift Desire/Features/Toolbar/Toolbar.swift Desire/Views/ContentView.swift
git commit -m "feat(screenshot): wire screenshot into toolbar, menu, and command dispatch"
```

---

## Task 6: Localization + Settings

**Files:**
- Modify: `Desire/Features/Settings/SettingsView.swift` — add save directory picker
- Modify: `Desire/Localizable.xcstrings` — add screenshot-related strings

- [ ] **Edit `SettingsView.swift` — add save directory row**

In the General section, after the download location row, add:
```swift
                HStack {
                    Text("Screenshot save location")
                    Spacer()
                    Text(screenshotDirDisplay)
                        .foregroundStyle(.secondary)
                    Button("Change…") { chooseScreenshotDir() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
```

Add state and method:
```swift
    @State private var screenshotDirDisplay: String = "Pictures"

    private func chooseScreenshotDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose screenshot save location")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let store = ScreenshotStore()
        store.saveDirectory = url
        screenshotDirDisplay = url.lastPathComponent
    }
```

- [ ] **Add xcstrings entries**

Add to `Localizable.xcstrings`:
```json
    "Screenshot…" : {
      "comment" : "Screenshot menu item",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Screenshot…" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "截图…" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "截圖…" } }
      }
    },
    "Screenshot" : {
      "comment" : "Screenshot toolbar help",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Screenshot" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "截图" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "截圖" } }
      }
    },
    "Cancel" : {
      "comment" : "Cancel button",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Cancel" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "取消" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "取消" } }
      }
    },
    "Copy" : {
      "comment" : "Copy to clipboard button",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Copy" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "复制" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "複製" } }
      }
    },
    "Save" : {
      "comment" : "Save button",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Save" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "保存" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "儲存" } }
      }
    },
    "Undo" : {
      "comment" : "Undo button",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Undo" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "撤销" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "復原" } }
      }
    },
    "Clear All" : {
      "comment" : "Clear annotations button",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Clear All" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "清除全部" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "清除全部" } }
      }
    },
    "Color" : {
      "comment" : "Color picker label",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Color" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "颜色" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "顏色" } }
      }
    },
    "Esc to cancel" : {
      "comment" : "Editor bottom bar hint",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Esc to cancel" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "Esc 取消" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "Esc 取消" } }
      }
    },
    "Screenshot save location" : {
      "comment" : "Settings label",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Screenshot save location" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "截图保存位置" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "截圖儲存位置" } }
      }
    },
    "Choose screenshot save location" : {
      "comment" : "Open panel message",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Choose screenshot save location" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "选择截图保存位置" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "選擇截圖儲存位置" } }
      }
    }
```

- [ ] **Build to verify**

Run: `xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

- [ ] **Commit**

```bash
git add Desire/Features/Settings/SettingsView.swift Desire/Localizable.xcstrings
git commit -m "feat(screenshot): add settings + localizations"
```
