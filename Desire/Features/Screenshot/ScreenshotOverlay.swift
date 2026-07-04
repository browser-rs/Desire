//
//  ScreenshotOverlay.swift
//  Desire
//
//  Created by mankong on 2026/7/5.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class ScreenshotToolbarModel: ObservableObject {
    @Published var activeTool: ScreenshotTool = .select
    @Published var activeColor: ScreenshotColor = .red
    @Published var strokeWidth: CGFloat = 2
    @Published var canUndo: Bool = false
}

private struct ScreenshotToolbar: View {
    @ObservedObject var model: ScreenshotToolbarModel

    let onToolChange: (ScreenshotTool) -> Void
    let onColorChange: (ScreenshotColor) -> Void
    let onStrokeWidthChange: (CGFloat) -> Void
    let onUndo: () -> Void
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
                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 2)
                strokeButton(width: 2, icon: "circle", help: "Thin")
                strokeButton(width: 4, icon: "circle.fill", help: "Thick")
            }
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
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
                        .stroke(model.activeColor == color ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: model.activeColor == color ? 2 : 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func strokeButton(width: CGFloat, icon: String, help: LocalizedStringKey) -> some View {
        Button(action: { onStrokeWidthChange(width) }) {
            Image(systemName: icon)
                .font(.system(size: width + 8))
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
}

final class ScreenshotOverlayView: NSView {

    // MARK: - Inputs

    let capturedImage: NSImage
    var onResult: ((ScreenshotResult) -> Void)?

    // MARK: - State

    private let toolbarModel = ScreenshotToolbarModel()
    private var toolbarHostingView: NSHostingView<ScreenshotToolbar>?

    private var mode: ScreenshotMode = .idle
    private var selectionRect: CGRect = .zero
    private var dragStart: CGPoint = .zero
    private var originalRect: CGRect = .zero

    private var annotations: [ScreenshotAnnotation] = []
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

    init(frame: CGRect, capturedImage: NSImage) {
        self.capturedImage = capturedImage
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
            onUndo: { [weak self] in self?.undo() },
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
            ctx.addPath(CGPath(rect: bounds, transform: nil))
            ctx.addPath(CGPath(rect: selectionRect, transform: nil))
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
                    toolbarModel.canUndo = !annotations.isEmpty
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
            strokeWidth: toolbarModel.strokeWidth
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
        toolbarModel.canUndo = true
        needsDisplay = true
    }

    // MARK: - Text field

    private func showTextField(at point: CGPoint) {
        let tf = NSTextField(frame: NSRect(origin: point, size: NSSize(width: 240, height: 24)))
        tf.isBordered = false
        tf.drawsBackground = false
        tf.isBezeled = false
        tf.focusRingType = .none
        tf.font = .boldSystemFont(ofSize: 16)
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
            number: 0
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
            toolbarModel.canUndo = true
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
        toolbarModel.activeColor = color
        // Update live text field color if editing
        textField?.textColor = color.nsColor
        if var ann = editingTextAnnotation { ann.color = color; editingTextAnnotation = ann }
    }

    private func setStrokeWidth(_ width: CGFloat) {
        toolbarModel.strokeWidth = width
    }

    private func undo() {
        if textField != nil { cancelTextField() }
        if !annotations.isEmpty {
            annotations.removeLast()
            toolbarModel.canUndo = !annotations.isEmpty
            needsDisplay = true
        }
    }

    private func redraw() {
        if textField != nil { cancelTextField() }
        annotations.removeAll()
        currentAnnotation = nil
        toolbarModel.canUndo = false
        nextNumber = 1
        selectionRect = .zero
        mode = .idle
        needsDisplay = true
        positionToolbar()
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

        let panel = NSSavePanel()
        panel.title = String(localized: "Choose screenshot save location")
        panel.nameFieldStringValue = ScreenshotCapture.defaultFilename()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url {
                do {
                    try ScreenshotCapture.writePNG(composed, to: url)
                    self.onResult?(.saved(url))
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
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
