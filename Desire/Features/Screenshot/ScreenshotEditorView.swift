import AppKit
import SwiftUI

struct ScreenshotEditorView: View {
    @ObservedObject var store: ScreenshotStore
    @State private var isDrawing = false
    @State private var currentPoints: [CGPoint] = []
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var showColorPicker = false

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
                    let s = min(size.width / image.size.width, size.height / image.size.height)
                    let ox = (size.width - image.size.width * s) / 2
                    let oy = (size.height - image.size.height * s) / 2

                    ctx.translateBy(x: ox, y: oy)
                    ctx.scaleBy(x: s, y: s)

                    ctx.withCGContext { cg in
                        for annotation in store.annotations {
                            annotation.draw(in: cg)
                        }

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
                            temp.draw(in: cg)
                        }

                        if store.currentTool == .pen && isDrawing {
                            let pen = PenAnnotation(points: currentPoints, color: store.currentColor, strokeWidth: store.strokeWidth)
                            pen.draw(in: cg)
                        }
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
