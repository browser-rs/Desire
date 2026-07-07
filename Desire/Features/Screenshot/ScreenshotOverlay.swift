//
//  ScreenshotOverlay.swift
//  Desire
//
//  Created by mankong on 2026/7/5.
//

import AppKit
import Combine
import SwiftUI

@MainActor
private final class ScreenshotToolbarModel: ObservableObject {
    @Published var activeTool: ScreenshotTool = .select
    @Published var activeColor: ScreenshotColor = .red
    @Published var strokeWidth: CGFloat = 2
    @Published var fontSize: CGFloat = 16
    @Published var fillEnabled: Bool = false
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    /// True when the active color came from NSColorPanel (not the palette).
    /// Used to render the "custom" swatch with the current picked color.
    @Published var customColor: ScreenshotColor?
}

private struct ScreenshotToolbar: View {
    @ObservedObject var model: ScreenshotToolbarModel

    let onToolChange: (ScreenshotTool) -> Void
    let onColorChange: (ScreenshotColor) -> Void
    let onStrokeWidthChange: (CGFloat) -> Void
    let onFontSizeChange: (CGFloat) -> Void
    let onFillToggle: () -> Void
    let onPickColor: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onRedraw: () -> Void
    let onSave: () -> Void
    let onCopy: () -> Void
    let onCancel: () -> Void

    private struct ToolItem: Hashable {
        let tool: ScreenshotTool
        let icon: String
        let help: LocalizedStringKey

        func hash(into hasher: inout Hasher) { hasher.combine(tool) }
        static func == (lhs: ToolItem, rhs: ToolItem) -> Bool { lhs.tool == rhs.tool }
    }

    private let tools: [ToolItem] = [
        .init(tool: .select,     icon: "cursorarrow",          help: "Select"),
        .init(tool: .rectangle,  icon: "rectangle",            help: "Rectangle"),
        .init(tool: .ellipse,    icon: "circle",               help: "Ellipse"),
        .init(tool: .arrow,      icon: "arrow.up.right",       help: "Arrow"),
        .init(tool: .brush,      icon: "pencil",               help: "Brush"),
        .init(tool: .mosaic,     icon: "square.grid.3x3",      help: "Mosaic"),
        .init(tool: .text,       icon: "textformat",           help: "Text"),
        .init(tool: .number,     icon: "number.circle",        help: "Number")
    ]

    /// Stroke width presets (points): thin / medium / thick.
    private let strokeOptions: [(width: CGFloat, iconSize: CGFloat, help: LocalizedStringKey)] = [
        (2, 6,  "Thin"),
        (4, 10, "Medium"),
        (6, 14, "Thick")
    ]

    /// Font size presets (points): small / medium / large.
    private let fontSizeOptions: [(size: CGFloat, iconSize: CGFloat, help: LocalizedStringKey)] = [
        (12, 10, "Small"),
        (16, 13, "Medium"),
        (22, 16, "Large")
    ]

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(tools, id: \.self) { item in
                    toolButton(item)
                }
                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 2)
                actionButton(icon: "arrow.uturn.backward", help: "Undo", action: onUndo, enabled: model.canUndo)
                actionButton(icon: "arrow.uturn.forward", help: "Redo", action: onRedo, enabled: model.canRedo)
                actionButton(icon: "crop", help: "Redraw", action: onRedraw, enabled: true)
                actionButton(icon: "xmark", help: "Cancel", action: onCancel, enabled: true)
                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 2)
                actionButton(icon: "square.and.arrow.down", help: "Save", action: onSave, enabled: true)
                actionButton(icon: "doc.on.doc", help: "Copy", action: onCopy, enabled: true)
            }
            HStack(spacing: 4) {
                ForEach(ScreenshotColor.palette, id: \.self) { color in
                    colorSwatch(color)
                }
                customColorSwatch
                if let extras = contextControls {
                    Divider()
                        .frame(height: 18)
                        .padding(.horizontal, 2)
                    extras
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
    }

    /// Context-dependent second-row controls based on the active tool.
    private var contextControls: AnyView? {
        switch model.activeTool {
        case .rectangle, .ellipse:
            return AnyView(
                HStack(spacing: 4) {
                    fillToggleButton()
                    ForEach(strokeOptions, id: \.width) { opt in
                        strokeButton(width: opt.width, iconSize: opt.iconSize, help: opt.help)
                    }
                }
            )
        case .arrow, .brush, .mosaic:
            return AnyView(
                HStack(spacing: 4) {
                    ForEach(strokeOptions, id: \.width) { opt in
                        strokeButton(width: opt.width, iconSize: opt.iconSize, help: opt.help)
                    }
                }
            )
        case .text:
            return AnyView(
                HStack(spacing: 4) {
                    ForEach(fontSizeOptions, id: \.size) { opt in
                        fontSizeButton(size: opt.size, iconSize: opt.iconSize, help: opt.help)
                    }
                }
            )
        default:
            return nil
        }
    }

    private func toolButton(_ item: ToolItem) -> some View {
        Button(action: { onToolChange(item.tool) }) {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(model.activeTool == item.tool ? Color.accentColor.opacity(0.25) : Color.clear)
                )
                .foregroundStyle(model.activeTool == item.tool ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .help(item.help)
    }

    private func actionButton(icon: String, help: LocalizedStringKey, action: @escaping () -> Void, enabled: Bool) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 22)
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private func colorSwatch(_ color: ScreenshotColor) -> some View {
        Button(action: { onColorChange(color) }) {
            Circle()
                .fill(Color(red: color.r, green: color.g, blue: color.b, opacity: color.a))
                .frame(width: 16, height: 16)
                .overlay(
                    Circle()
                        .stroke(isActiveColor(color) ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isActiveColor(color) ? 2 : 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(color == .black ? "Black" : (color == .white ? "White" : helpForPalette(color)))
    }

    /// Custom-color swatch: a rainbow ring that opens the system color picker.
    /// When a custom color is active, the inner disc shows the picked color.
    private var customColorSwatch: some View {
        Button(action: onPickColor) {
            ZStack {
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [.red, .yellow, .green, .blue, .purple, .red],
                            center: .center
                        ),
                        lineWidth: 2
                    )
                    .frame(width: 16, height: 16)
                if let custom = model.customColor {
                    Circle()
                        .fill(Color(red: custom.r, green: custom.g, blue: custom.b, opacity: custom.a))
                        .frame(width: 10, height: 10)
                }
            }
            .frame(width: 16, height: 16)
            .overlay(
                Circle()
                    .stroke(model.customColor != nil ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Pick color…")
    }

    private func fillToggleButton() -> some View {
        let isOn = model.fillEnabled
        return Button(action: onFillToggle) {
            Image(systemName: isOn ? "rectangle.fill" : "rectangle")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn ? Color.accentColor.opacity(0.25) : Color.clear)
                )
                .foregroundStyle(isOn ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .help(isOn ? "Filled" : "Outlined")
    }

    private func strokeButton(width: CGFloat, iconSize: CGFloat, help: LocalizedStringKey) -> some View {
        Button(action: { onStrokeWidthChange(width) }) {
            Image(systemName: "circle.fill")
                .font(.system(size: iconSize))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(model.strokeWidth == width ? Color.accentColor.opacity(0.25) : Color.clear)
                )
                .foregroundStyle(model.strokeWidth == width ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func fontSizeButton(size: CGFloat, iconSize: CGFloat, help: LocalizedStringKey) -> some View {
        Button(action: { onFontSizeChange(size) }) {
            Image(systemName: "textformat")
                .font(.system(size: iconSize))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(model.fontSize == size ? Color.accentColor.opacity(0.25) : Color.clear)
                )
                .foregroundStyle(model.fontSize == size ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func isActiveColor(_ color: ScreenshotColor) -> Bool {
        // A palette color is "active" only when there's no custom color override
        // (i.e. customColor is nil) and it equals model.activeColor.
        model.customColor == nil && model.activeColor == color
    }

    private func helpForPalette(_ color: ScreenshotColor) -> LocalizedStringKey {
        switch color {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        default: return ""
        }
    }
}

final class ScreenshotOverlayView: NSView {

    // MARK: - Inputs

    let capturedImage: NSImage
    /// Folder where the screenshot is written when the user clicks Save.
    /// The Settings store resolves security-scope access; we just write here.
    let saveFolder: URL
    var onResult: ((ScreenshotResult) -> Void)?

    // MARK: - State

    private let toolbarModel = ScreenshotToolbarModel()
    private var toolbarHostingView: NSHostingView<ScreenshotToolbar>?

    private var mode: ScreenshotMode = .idle
    private var selectionRect: CGRect = .zero
    private var dragStart: CGPoint = .zero
    private var originalRect: CGRect = .zero

    private var annotations: [ScreenshotAnnotation] = []
    private var redoStack: [ScreenshotAnnotation] = []
    private var currentAnnotation: ScreenshotAnnotation?
    private var nextNumber: Int = 1

    private var textField: NSTextField?
    private var editingTextAnnotation: ScreenshotAnnotation?

    private var _mosaicCache: NSImage?
    private var mosaicCache: NSImage? {
        if _mosaicCache == nil {
            _mosaicCache = ScreenshotCapture.buildMosaicSource(from: capturedImage)
        }
        return _mosaicCache
    }

    // MARK: - Init

    init(frame: CGRect, capturedImage: NSImage, saveFolder: URL) {
        self.capturedImage = capturedImage
        self.saveFolder = saveFolder
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        let toolbar = ScreenshotToolbar(
            model: toolbarModel,
            onToolChange: { [weak self] tool in self?.setActiveTool(tool) },
            onColorChange: { [weak self] color in self?.setActiveColor(color) },
            onStrokeWidthChange: { [weak self] width in self?.setStrokeWidth(width) },
            onFontSizeChange: { [weak self] size in self?.setFontSize(size) },
            onFillToggle: { [weak self] in self?.toggleFill() },
            onPickColor: { [weak self] in self?.pickColor() },
            onUndo: { [weak self] in self?.undo() },
            onRedo: { [weak self] in self?.redo() },
            onRedraw: { [weak self] in self?.redraw() },
            onSave: { [weak self] in self?.saveImage() },
            onCopy: { [weak self] in self?.copyImage() },
            onCancel: { [weak self] in self?.cancel() }
        )
        let hosting = NSHostingView(rootView: toolbar)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        hosting.isHidden = true
        toolbarHostingView = hosting
    }

    // MARK: - NSView overrides

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        // Track mouse moved without dragging
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. Draw the captured image as the base.
        //    Use NSImage.draw(in:) rather than CGContext.draw(cg, in:) because
        //    NSImage's draw respects isFlipped; CGContext.draw renders the image
        //    upside-down in a flipped view (image's top row maps to rect.maxY,
        //    which is the bottom of the view in a flipped coordinate system).
        ctx.saveGState()
        capturedImage.draw(in: bounds)
        ctx.restoreGState()

        // 2. Dim outside the selection (or everywhere if no selection)
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        if selectionRect.isEmpty || selectionRect.width < 1 || selectionRect.height < 1 {
            ctx.fill(bounds)
        } else {
            ctx.beginPath()
            ctx.addRect(bounds)
            ctx.addRect(selectionRect)
            ctx.fillPath(using: .evenOdd)
        }
        ctx.restoreGState()

        // 3. Clip to selection and draw annotations
        if !selectionRect.isEmpty && selectionRect.width > 1 && selectionRect.height > 1 {
            ctx.saveGState()
            ctx.clip(to: selectionRect)
            for ann in annotations {
                ScreenshotAnnotationRenderer.draw(
                    ann,
                    in: ctx,
                    canvasSize: bounds.size,
                    mosaicSource: mosaicCache
                )
            }
            if let current = currentAnnotation {
                ScreenshotAnnotationRenderer.draw(
                    current,
                    in: ctx,
                    canvasSize: bounds.size,
                    mosaicSource: mosaicCache
                )
            }
            ctx.restoreGState()
        }

        // 4. Selection border + handles
        if !selectionRect.isEmpty && selectionRect.width > 1 && selectionRect.height > 1 {
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(selectionRect)

            if case .editing = mode {
                drawHandles(in: ctx)
            }
        }

        // 5. Size tooltip during draw/resize
        if case .drawingSelection = mode {
            drawSizeTooltip(in: ctx)
        } else if case .adjustingSelection = mode {
            drawSizeTooltip(in: ctx)
        }
    }

    private func drawHandles(in ctx: CGContext) {
        let handleSize: CGFloat = 8
        let centers: [CGPoint] = [
            CGPoint(x: selectionRect.minX, y: selectionRect.minY),
            CGPoint(x: selectionRect.midX, y: selectionRect.minY),
            CGPoint(x: selectionRect.maxX, y: selectionRect.minY),
            CGPoint(x: selectionRect.maxX, y: selectionRect.midY),
            CGPoint(x: selectionRect.maxX, y: selectionRect.maxY),
            CGPoint(x: selectionRect.midX, y: selectionRect.maxY),
            CGPoint(x: selectionRect.minX, y: selectionRect.maxY),
            CGPoint(x: selectionRect.minX, y: selectionRect.midY)
        ]
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1)
        for center in centers {
            let rect = CGRect(
                x: center.x - handleSize / 2,
                y: center.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            ctx.fill(rect)
            ctx.stroke(rect)
        }
    }

    private func drawSizeTooltip(in ctx: CGContext) {
        let w = Int(selectionRect.width)
        let h = Int(selectionRect.height)
        let text = "\(w) × \(h)"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        ]
        let nsText = text as NSString
        let textSize = nsText.size(withAttributes: attrs)
        let padding: CGFloat = 4
        let tooltipSize = CGSize(width: textSize.width + padding * 2, height: textSize.height + padding)
        // Place at top-left of selection, just above
        var origin = CGPoint(
            x: selectionRect.minX,
            y: selectionRect.minY - tooltipSize.height - 4
        )
        if origin.y < 0 {
            origin.y = selectionRect.minY + 4
        }
        let tooltipRect = CGRect(origin: origin, size: tooltipSize)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.fill(tooltipRect)
        let textRect = CGRect(
            x: origin.x + padding,
            y: origin.y + padding / 2,
            width: textSize.width,
            height: textSize.height
        )
        nsText.draw(in: textRect, withAttributes: attrs)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        positionToolbar()
    }

    private func positionToolbar() {
        guard let hosting = toolbarHostingView else { return }

        let showToolbar: Bool
        switch mode {
        case .editing, .adjustingSelection, .drawingAnnotation:
            showToolbar = !selectionRect.isEmpty && selectionRect.width > 1 && selectionRect.height > 1
        default:
            showToolbar = false
        }
        hosting.isHidden = !showToolbar
        guard showToolbar else { return }

        // Compute size
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.setFrameSize(size)

        let margin: CGFloat = 8
        var origin = CGPoint(
            x: selectionRect.maxX - size.width,
            y: selectionRect.maxY + margin
        )
        // If overflow bottom, place above selection
        if origin.y + size.height > bounds.maxY {
            origin.y = selectionRect.minY - margin - size.height
        }
        // Clamp x
        if origin.x < bounds.minX { origin.x = bounds.minX }
        if origin.x + size.width > bounds.maxX {
            origin.x = bounds.maxX - size.width
        }
        if origin.y < bounds.minY { origin.y = bounds.minY }
        hosting.setFrameOrigin(origin)
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        // If we're editing text, click anywhere else commits it first
        if textField != nil {
            commitTextField()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let tool = toolbarModel.activeTool

        switch tool {
        case .select:
            handleSelectToolDown(point: point)
        case .rectangle, .ellipse, .arrow, .brush, .mosaic:
            handleShapeToolDown(point: point, tool: tool)
        case .text:
            handleTextToolDown(point: point)
        case .number:
            handleNumberToolDown(point: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch mode {
        case .drawingSelection:
            selectionRect = CGRect(
                x: min(dragStart.x, point.x),
                y: min(dragStart.y, point.y),
                width: abs(point.x - dragStart.x),
                height: abs(point.y - dragStart.y)
            )
            needsDisplay = true

        case .adjustingSelection(let handle):
            let dx = point.x - dragStart.x
            let dy = point.y - dragStart.y
            var newRect = originalRect
            switch handle {
            case .topLeft:
                newRect.origin.x += dx; newRect.size.width -= dx
                newRect.origin.y += dy; newRect.size.height -= dy
            case .top:
                newRect.origin.y += dy; newRect.size.height -= dy
            case .topRight:
                newRect.size.width += dx
                newRect.origin.y += dy; newRect.size.height -= dy
            case .right:
                newRect.size.width += dx
            case .bottomRight:
                newRect.size.width += dx; newRect.size.height += dy
            case .bottom:
                newRect.size.height += dy
            case .bottomLeft:
                newRect.origin.x += dx; newRect.size.width -= dx
                newRect.size.height += dy
            case .left:
                newRect.origin.x += dx; newRect.size.width -= dx
            case .body:
                newRect.origin.x += dx; newRect.origin.y += dy
            default:
                break
            }
            // Allow flip when dragged past opposite edge
            if newRect.width < 0 {
                newRect.origin.x += newRect.width
                newRect.size.width = -newRect.width
            }
            if newRect.height < 0 {
                newRect.origin.y += newRect.height
                newRect.size.height = -newRect.height
            }
            // Clamp to bounds
            newRect.origin.x = max(bounds.minX, min(newRect.origin.x, bounds.maxX))
            newRect.origin.y = max(bounds.minY, min(newRect.origin.y, bounds.maxY))
            if newRect.origin.x + newRect.width > bounds.maxX {
                newRect.size.width = bounds.maxX - newRect.origin.x
            }
            if newRect.origin.y + newRect.height > bounds.maxY {
                newRect.size.height = bounds.maxY - newRect.origin.y
            }
            selectionRect = newRect
            needsDisplay = true
            positionToolbar()

        case .drawingAnnotation(let tool):
            guard var ann = currentAnnotation else { break }
            if tool == .rectangle || tool == .ellipse || tool == .arrow {
                if ann.points.count >= 2 {
                    ann.points[1] = point
                } else {
                    ann.points.append(point)
                }
            } else {
                ann.points.append(point)
            }
            currentAnnotation = ann
            needsDisplay = true

        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .drawingSelection:
            let minSize: CGFloat = 10
            if selectionRect.width < minSize || selectionRect.height < minSize {
                selectionRect = .zero
                mode = .idle
            } else {
                mode = .editing
            }
            positionToolbar()
            needsDisplay = true

        case .adjustingSelection:
            mode = .editing
            positionToolbar()
            needsDisplay = true

        case .drawingAnnotation(let tool):
            if let ann = currentAnnotation {
                var valid = true
                if tool == .rectangle || tool == .ellipse || tool == .arrow {
                    if ann.points.count >= 2 {
                        let p1 = ann.points[0]
                        let p2 = ann.points[1]
                        if abs(p1.x - p2.x) < 3 && abs(p1.y - p2.y) < 3 {
                            valid = false
                        }
                    } else {
                        valid = false
                    }
                } else if tool == .brush || tool == .mosaic {
                    if ann.points.count < 2 {
                        valid = false
                    }
                }
                if valid {
                    annotations.append(ann)
                    // New action invalidates the redo stack.
                    redoStack.removeAll()
                    toolbarModel.canUndo = true
                    toolbarModel.canRedo = false
                }
                currentAnnotation = nil
            }
            mode = .editing
            needsDisplay = true
            positionToolbar()

        default:
            break
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Over the floating toolbar → use default arrow so SwiftUI buttons
        // own their hover/click affordances (otherwise the crosshair stays).
        if let hosting = toolbarHostingView, !hosting.isHidden, hosting.frame.contains(point) {
            NSCursor.arrow.set()
            return
        }
        let cursor = cursorForPoint(point)
        cursor.set()
    }

    override func resetCursorRects() {
        // Default to arrow across the whole overlay; `mouseMoved` dynamically
        // switches to crosshair/resize/beam based on position and active tool.
        addCursorRect(bounds, cursor: .arrow)
    }

    private func cursorForPoint(_ point: CGPoint) -> NSCursor {
        let tool = toolbarModel.activeTool
        if tool == .text {
            return .iBeam
        }
        if tool != .select {
            return .crosshair
        }
        if !selectionRect.isEmpty {
            if let handle = hitTestHandle(point) {
                switch handle {
                case .topLeft, .bottomRight, .topRight, .bottomLeft: return .crosshair
                case .top, .bottom: return .resizeUpDown
                case .left, .right: return .resizeLeftRight
                default: return .arrow
                }
            }
            if selectionRect.contains(point) {
                return .closedHand
            }
        }
        return .crosshair
    }

    // MARK: - Hit testing

    private func hitTestHandle(_ point: CGPoint) -> ScreenshotHandle? {
        let handleSize: CGFloat = 12
        func test(_ center: CGPoint) -> Bool {
            let zone = CGRect(
                x: center.x - handleSize / 2,
                y: center.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            return zone.contains(point)
        }

        let rect = selectionRect
        let centers: [(CGPoint, ScreenshotHandle)] = [
            (CGPoint(x: rect.minX, y: rect.minY), .topLeft),
            (CGPoint(x: rect.midX, y: rect.minY), .top),
            (CGPoint(x: rect.maxX, y: rect.minY), .topRight),
            (CGPoint(x: rect.maxX, y: rect.midY), .right),
            (CGPoint(x: rect.maxX, y: rect.maxY), .bottomRight),
            (CGPoint(x: rect.midX, y: rect.maxY), .bottom),
            (CGPoint(x: rect.minX, y: rect.maxY), .bottomLeft),
            (CGPoint(x: rect.minX, y: rect.midY), .left)
        ]
        for (center, handle) in centers {
            if test(center) {
                return handle
            }
        }
        return nil
    }

    // MARK: - Tool handlers

    private func handleSelectToolDown(point: CGPoint) {
        if !selectionRect.isEmpty {
            if let handle = hitTestHandle(point), handle != .body {
                mode = .adjustingSelection(handle: handle)
                dragStart = point
                originalRect = selectionRect
                return
            }
            if selectionRect.contains(point) {
                mode = .adjustingSelection(handle: .body)
                dragStart = point
                originalRect = selectionRect
                return
            }
        }
        // Start new selection
        mode = .drawingSelection
        selectionRect = CGRect(origin: point, size: .zero)
        dragStart = point
        needsDisplay = true
        positionToolbar()
    }

    private func handleShapeToolDown(point: CGPoint, tool: ScreenshotTool) {
        guard !selectionRect.isEmpty, selectionRect.contains(point) else {
            handleSelectToolDown(point: point)
            return
        }
        mode = .drawingAnnotation(tool)
        currentAnnotation = ScreenshotAnnotation(
            tool: tool,
            points: [point, point],
            color: toolbarModel.activeColor,
            strokeWidth: toolbarModel.strokeWidth,
            fillEnabled: toolbarModel.fillEnabled
        )
        needsDisplay = true
    }

    private func handleTextToolDown(point: CGPoint) {
        guard !selectionRect.isEmpty, selectionRect.contains(point) else {
            handleSelectToolDown(point: point)
            return
        }
        showTextField(at: point)
    }

    private func handleNumberToolDown(point: CGPoint) {
        guard !selectionRect.isEmpty, selectionRect.contains(point) else {
            handleSelectToolDown(point: point)
            return
        }
        let ann = ScreenshotAnnotation(
            tool: .number,
            points: [point],
            color: toolbarModel.activeColor,
            strokeWidth: toolbarModel.strokeWidth,
            number: nextNumber
        )
        annotations.append(ann)
        nextNumber += 1
        redoStack.removeAll()
        toolbarModel.canUndo = true
        toolbarModel.canRedo = false
        needsDisplay = true
    }

    // MARK: - Text field

    private func showTextField(at point: CGPoint) {
        let fontPt = toolbarModel.fontSize
        // Match the field height to the font for cleaner placement.
        let fieldHeight = max(24, fontPt + 8)
        let tf = NSTextField(frame: NSRect(origin: point, size: NSSize(width: 240, height: fieldHeight)))
        tf.isBordered = false
        tf.drawsBackground = false
        tf.isBezeled = false
        tf.focusRingType = .none
        tf.font = .boldSystemFont(ofSize: fontPt)
        tf.textColor = toolbarModel.activeColor.nsColor
        tf.placeholderString = String(localized: "Text")
        tf.stringValue = ""
        tf.delegate = self
        tf.target = self
        tf.action = #selector(textFieldEnterPressed(_:))
        addSubview(tf)
        window?.makeFirstResponder(tf)
        textField = tf
        editingTextAnnotation = ScreenshotAnnotation(
            tool: .text,
            points: [point],
            color: toolbarModel.activeColor,
            strokeWidth: toolbarModel.strokeWidth,
            text: "",
            number: 0,
            fontSize: fontPt
        )
    }

    @objc private func textFieldEnterPressed(_ sender: NSTextField) {
        commitTextField()
    }

    private func commitTextField() {
        guard let tf = textField, var ann = editingTextAnnotation else { return }
        let text = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            ann.text = text
            annotations.append(ann)
            redoStack.removeAll()
            toolbarModel.canUndo = true
            toolbarModel.canRedo = false
        }
        tf.removeFromSuperview()
        textField = nil
        editingTextAnnotation = nil
        needsDisplay = true
    }

    private func cancelTextField() {
        textField?.removeFromSuperview()
        textField = nil
        editingTextAnnotation = nil
        needsDisplay = true
    }

    // MARK: - Toolbar actions

    private func setActiveTool(_ tool: ScreenshotTool) {
        if textField != nil { commitTextField() }
        toolbarModel.activeTool = tool
    }

    private func setActiveColor(_ color: ScreenshotColor) {
        // Picking from the palette clears the custom-color override.
        toolbarModel.customColor = nil
        toolbarModel.activeColor = color
        // Update live text field color if editing
        textField?.textColor = color.nsColor
        if var ann = editingTextAnnotation { ann.color = color; editingTextAnnotation = ann }
    }

    private func setStrokeWidth(_ width: CGFloat) {
        toolbarModel.strokeWidth = width
    }

    private func setFontSize(_ size: CGFloat) {
        toolbarModel.fontSize = size
        // Update live text field font if editing
        textField?.font = .boldSystemFont(ofSize: size)
    }

    private func toggleFill() {
        toolbarModel.fillEnabled.toggle()
    }

    private func undo() {
        if textField != nil { cancelTextField() }
        guard let ann = annotations.popLast() else { return }
        redoStack.append(ann)
        toolbarModel.canUndo = !annotations.isEmpty
        toolbarModel.canRedo = !redoStack.isEmpty
        needsDisplay = true
    }

    private func redo() {
        if textField != nil { cancelTextField() }
        guard let ann = redoStack.popLast() else { return }
        annotations.append(ann)
        toolbarModel.canUndo = true
        toolbarModel.canRedo = !redoStack.isEmpty
        needsDisplay = true
    }

    private func redraw() {
        if textField != nil { cancelTextField() }
        annotations.removeAll()
        redoStack.removeAll()
        currentAnnotation = nil
        toolbarModel.canUndo = false
        toolbarModel.canRedo = false
        nextNumber = 1
        selectionRect = .zero
        mode = .idle
        needsDisplay = true
        positionToolbar()
    }

    // MARK: - Color picker

    /// Show the system color panel and route its changes into the toolbar.
    /// NSColorPanel sends its action continuously as the user drags swatches,
    /// giving a live preview in the overlay.
    @objc private func colorPanelDidChange(_ sender: NSColorPanel) {
        let ns = sender.color.usingColorSpace(.sRGB) ?? sender.color
        let sc = ScreenshotColor(
            r: Double(ns.redComponent),
            g: Double(ns.greenComponent),
            b: Double(ns.blueComponent),
            a: Double(ns.alphaComponent)
        )
        toolbarModel.customColor = sc
        toolbarModel.activeColor = sc
        textField?.textColor = sc.nsColor
        if var ann = editingTextAnnotation { ann.color = sc; editingTextAnnotation = ann }
    }

    private func pickColor() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelDidChange(_:)))
        panel.isContinuous = true
        panel.makeKeyAndOrderFront(nil)
    }

    private func cancel() {
        onResult?(.cancelled)
    }

    // MARK: - Save / Copy

    private func saveImage() {
        if textField != nil { commitTextField() }
        guard !selectionRect.isEmpty, selectionRect.width > 1, selectionRect.height > 1 else { return }

        let scale = window?.screen?.backingScaleFactor ?? 2.0
        guard let composed = ScreenshotCapture.composite(
            annotations: annotations,
            onto: capturedImage,
            in: selectionRect,
            canvasSize: bounds.size,
            scale: scale,
            mosaicSource: mosaicCache
        ) else { return }

        // Write directly to the configured save folder (WeChat-style one-click save).
        // Settings already started security-scope access on the folder, so we just
        // need to ensure the directory exists and pick a non-colliding filename.
        let filename = ScreenshotCapture.defaultFilename()
        let target = uniqueURL(in: saveFolder, for: filename)
        do {
            try FileManager.default.createDirectory(
                at: saveFolder,
                withIntermediateDirectories: true
            )
            try ScreenshotCapture.writePNG(composed, to: target)
            onResult?(.saved(target))
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Pick a non-colliding URL inside `folder` for `filename`, appending " 2", " 3", …
    private func uniqueURL(in folder: URL, for filename: String) -> URL {
        let base = folder.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        var i = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
            i += 1
        }
    }

    private func copyImage() {
        if textField != nil { commitTextField() }
        guard !selectionRect.isEmpty, selectionRect.width > 1, selectionRect.height > 1 else { return }

        let scale = window?.screen?.backingScaleFactor ?? 2.0
        guard let composed = ScreenshotCapture.composite(
            annotations: annotations,
            onto: capturedImage,
            in: selectionRect,
            canvasSize: bounds.size,
            scale: scale,
            mosaicSource: mosaicCache
        ) else { return }

        ScreenshotCapture.copyToPasteboard(composed)
        onResult?(.copied)
    }

    // MARK: - Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+Z for undo
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "z" {
            undo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if textField != nil {
            cancelTextField()
            return
        }
        if currentAnnotation != nil {
            currentAnnotation = nil
            mode = .editing
            needsDisplay = true
            return
        }
        onResult?(.cancelled)
    }
}

extension ScreenshotOverlayView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField, tf === textField else { return }
        commitTextField()
    }
}
