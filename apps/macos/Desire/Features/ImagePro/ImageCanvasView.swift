import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 画布（v0.8.46 重写）：单一坐标变换 `ImageCanvasTransform`。
/// 事件 → base 像素（工具数据一律存 base）；覆盖层 base → 画布坐标。
/// 组件职责：只做"手势 → 文档操作"和覆盖层绘制，不碰像素算法。
struct ImageCanvasView: View {
    @ObservedObject private var session: ImageEditorSession
    @ObservedObject private var canvas: ImageCanvasModel
    @ObservedObject private var document: ImageEditorDocument

    // 交互中的临时几何（一律 base 像素）
    @State private var strokePoints: [CGPoint] = []
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var lassoPoints: [CGPoint] = []
    @State private var cropRect: CGRect?
    @State private var cropDrag: CropDrag?
    @State private var lastCropClick = Date.distantPast
    @State private var combineMode: ImageEditorRaster.SelectionCombine = .replace
    @State private var retouchStart: CGPoint?
    @State private var retouchLast: CGPoint?
    @State private var hoverCanvas: CGPoint?
    @State private var textAnchor: CGPoint?
    @State private var textEntry = ""
    @State private var showTextEntry = false
    /// 非空 = 正在重编辑该文字层（点回文字打开）。
    @State private var editingTextID: UUID?
    @FocusState private var textFocused: Bool
    @State private var panLast: CGPoint?
    @State private var moveStart: CGPoint?
    @State private var moveStartOffset: CGSize = .zero

    private enum CropHandle {
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
        case inside
    }

    private struct CropDrag {
        var handle: CropHandle
        var startPoint: CGPoint   // canvas
        var startRect: CGRect     // base
        var createdNew: Bool
    }

    init(session: ImageEditorSession) {
        _session = ObservedObject(wrappedValue: session)
        _canvas = ObservedObject(wrappedValue: session.canvas)
        _document = ObservedObject(wrappedValue: session.document)
    }

    private var transform: ImageCanvasTransform {
        ImageCanvasTransform(containerSize: canvas.containerSize,
                             displaySize: document.canvasSize,
                             baseSize: document.canvasSize,
                             geometryOps: [],
                             zoom: canvas.zoom,
                             pan: canvas.pan)
    }

    var body: some View {
        GeometryReader { geo in
            let t = transform
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                imageLayer(t)
                overlays(t)
                    .allowsHitTesting(false)
                ImageEventCatcher(
                    onPoint: { kind, point, flags in
                        handlePoint(kind, point, flags)
                    },
                    onMagnify: { delta, anchor in
                        canvas.zoom(by: 1 + delta, anchor: anchor)
                    },
                    onScroll: { dx, dy, anchor, command in
                        if command {
                            canvas.zoom(by: dy < 0 ? 1.1 : 1 / 1.1, anchor: anchor)
                        } else {
                            canvas.pan = CGSize(width: canvas.pan.width - dx,
                                                height: canvas.pan.height - dy)
                        }
                    },
                    onDoubleClick: { anchor in
                        guard session.tool == .hand || session.tool == .zoom else { return }
                        if abs(canvas.zoom - canvas.fitZoom) < 0.01 {
                            canvas.zoom(to: 1, anchor: anchor)
                        } else {
                            canvas.fit()
                        }
                    },
                    onSizeChange: { size in
                        syncContainer(size)
                    },
                    onKey: { key in
                        if key == "\r" {
                            if session.tool == .crop, cropRect != nil {
                                applyCrop()
                                return true
                            }
                            return false
                        }
                        return session.handleKey(key)
                    }
                )
                if showTextEntry, let anchor = textAnchor {
                    textCard(anchor: t.canvasPoint(fromBasePixel: anchor))
                }
                if session.tool == .crop, let rect = cropRect {
                    cropBar(rect: rect)
                }
            }
            .clipped()
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, let image = ImageTransforms.load(from: url) else { return }
                        Task { @MainActor in
                            session.document.placeImage(image, name: url.lastPathComponent)
                            session.flash(String(localized: "Image placed"))
                        }
                    }
                }
                return true
            }
            .onAppear { syncContainer(geo.size) }
            .onChange(of: geo.size) { _, size in syncContainer(size) }
            .onChange(of: document.canvasSize) { _, _ in syncContainer(geo.size) }
            .onChange(of: document.revision) { _, _ in
                syncProbe()
            }
            .onChange(of: canvas.zoom) { _, _ in syncProbe() }
            .onChange(of: canvas.pan) { _, _ in syncProbe() }
            .onChange(of: canvas.containerSize) { _, _ in syncProbe() }
            .onChange(of: session.tool) { _, _ in
                if session.tool != .crop { cropRect = nil }
                syncProbe()
            }
        }
    }

    // MARK: - 同步

    private func syncContainer(_ size: CGSize) {
        canvas.containerSize = size
        canvas.updateContent(display: document.canvasSize,
                             base: document.canvasSize,
                             ops: [])
        canvas.recomputeFit()
        syncProbe()
    }

    private func syncProbe() {
        #if DEBUG
        let t = transform
        ImageEditorDebug.latest = [
            "zoom": Double(canvas.zoom),
            "fitZoom": Double(canvas.fitZoom),
            "isFitMode": canvas.isFitMode,
            "panW": Double(canvas.pan.width), "panH": Double(canvas.pan.height),
            "containerW": Double(canvas.containerSize.width),
            "containerH": Double(canvas.containerSize.height),
            "originX": Double(t.origin.x), "originY": Double(t.origin.y),
            "dispW": Double(t.contentSize.width), "dispH": Double(t.contentSize.height),
            "baseW": document.canvasSize.width, "baseH": document.canvasSize.height,
            "displayScale": Double(t.basePerCanvasPoint),
            "tool": session.tool.rawValue,
            "cropMode": session.tool == .crop,
            "cropRectW": cropRect?.width ?? 0, "cropRectH": cropRect?.height ?? 0,
            "selectionEmpty": document.selection.isEmpty,
            "selectionDesc": document.selection.describe,
            "selectionBounds": document.selection.bounds(canvasSize: document.canvasSize).map {
                [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)]
            } ?? [],
            "brushPoints": strokePoints.count,
            "historyCount": document.historyTitles.count,
            "redoCount": document.redoCount,
            "layers": document.layers.count,
            "activeLayer": document.activeLayer?.name ?? "",
            "textCard": showTextEntry,
            "editingText": editingTextID?.uuidString ?? "",
            "textHit": document.textLayerID(at: session.cursorBase ?? .zero)?.uuidString ?? "",
            "cursorX": session.cursorBase.map { Double($0.x) } ?? -1,
            "cursorY": session.cursorBase.map { Double($0.y) } ?? -1,
            "textEntry": textEntry,
            "textFocused": textFocused,
        ]
        #endif
    }

    // MARK: - 图像层

    @ViewBuilder
    private func imageLayer(_ t: ImageCanvasTransform) -> some View {
        if let cg = session.canvasImage() {
            // 用 CGImage 直出（scale = 1：1 像素 = 1 点），像素级缩放由
            // interpolation 决定：>=100% 用 nearest（像素清晰不糊），
            // <100% 用 high（高质量缩小）。NSImage 包装在 Retina 上会被
            // AppKit 再插值一次，画面发虚（用户实测"画布很模糊"）。
            Image(decorative: cg, scale: 1, orientation: .up)
                .resizable()
                .interpolation(canvas.zoom >= 1 ? .none : .high)
                .frame(width: t.contentSize.width, height: t.contentSize.height)
                .position(x: t.origin.x + t.contentSize.width / 2,
                          y: t.origin.y + t.contentSize.height / 2)
                .shadow(radius: 3)
        }
    }

    // MARK: - 覆盖层

    @ViewBuilder
    private func overlays(_ t: ImageCanvasTransform) -> some View {
        ZStack(alignment: .topLeading) {
            selectionOverlay(t)
            lassoPreview(t)
            shapePreview(t)
            gradientPreview(t)
            strokePreview(t)
            guideOverlay(t)
            cropOverlay(t)
            cloneSampleMarker(t)
            brushCursor(t)
        }
    }

    @ViewBuilder
    private func selectionOverlay(_ t: ImageCanvasTransform) -> some View {
        if session.tool == .marquee, let start = dragStart, let current = dragCurrent {
            let rect = t.canvasRect(fromBaseRect: normalized(start, current))
            marchingAnts(rect: rect, ellipse: session.marqueeEllipse, phase: 0)
                .opacity(0.9)
        } else if let bounds = document.selection.bounds(canvasSize: document.canvasSize) {
            // 自定义蒙版（魔棒/套索）：额外把真实形状叠出来（灰度蒙版 screen
            // 提亮），否则只看到包围盒蚂蚁线，完全不知道选了什么。
            if let mask = document.selection.mask {
                Image(decorative: mask, scale: 1)
                    .resizable()
                    .interpolation(.low)
                    .frame(width: t.contentSize.width, height: t.contentSize.height)
                    .scaleEffect(x: 1, y: -1)
                    .position(x: t.origin.x + t.contentSize.width / 2,
                              y: t.origin.y + t.contentSize.height / 2)
                    .opacity(0.28)
                    .blendMode(.screen)
            }
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 100) * 9
                marchingAnts(rect: t.canvasRect(fromBaseRect: bounds),
                             ellipse: document.selection.isEllipse,
                             phase: phase)
            }
        }
    }

    private func marchingAnts(rect: CGRect, ellipse: Bool, phase: Double) -> some View {
        ZStack {
            let shape = ellipse ? AnyShape(Ellipse()) : AnyShape(Rectangle())
            shape
                .stroke(Color.black.opacity(0.85),
                        style: StrokeStyle(lineWidth: 1.4, dash: [6, 4], dashPhase: phase))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            shape
                .stroke(Color.white,
                        style: StrokeStyle(lineWidth: 1.4, dash: [6, 4], dashPhase: phase + 5))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    /// 渐变拖动实时预览（此前松手前完全看不到效果）。与
    /// ImageEditorRaster.drawGradient 同几何：线性 = from→to 轴（两端外延纯色），
    /// 径向 = from 圆心、半径 = |to-from|（外延）；颜色 = 前景→背景。
    /// 选区裁剪只在提交时生效（预览不裁，选区有蚂蚁线提示）。
    @ViewBuilder
    private func gradientPreview(_ t: ImageCanvasTransform) -> some View {
        if session.tool == .gradient, let start = dragStart, let current = dragCurrent {
            let a = t.canvasPoint(fromBasePixel: start)
            let b = t.canvasPoint(fromBasePixel: current)
            let colors = Gradient(colors: [session.primaryColor, session.secondaryColor])
            Canvas { context, _ in
                let imageRect = Path(CGRect(origin: t.origin, size: t.contentSize))
                if session.gradientRadial {
                    let radius = max(1, hypot(b.x - a.x, b.y - a.y))
                    context.fill(imageRect, with: .radialGradient(
                        colors, center: a, startRadius: 0, endRadius: radius))
                } else {
                    context.fill(imageRect, with: .linearGradient(
                        colors, startPoint: a, endPoint: b))
                }
            }
            .allowsHitTesting(false)
            .opacity(0.92)
        }
    }

    @ViewBuilder
    private func lassoPreview(_ t: ImageCanvasTransform) -> some View {
        if session.tool == .lasso, lassoPoints.count >= 2 {
            Path { path in
                let pts = lassoPoints.map { t.canvasPoint(fromBasePixel: $0) }
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.addLine(to: p) }
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.4, dash: [5, 3]))
            .shadow(color: .black.opacity(0.6), radius: 1)
        }
    }

    @ViewBuilder
    private func shapePreview(_ t: ImageCanvasTransform) -> some View {
        if session.tool == .shape, let start = dragStart, let current = dragCurrent {
            let a = t.canvasPoint(fromBasePixel: start)
            let b = t.canvasPoint(fromBasePixel: current)
            let color = session.primaryColor
            switch session.shape {
            case .rectangle, .ellipse:
                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                  width: abs(b.x - a.x), height: abs(b.y - a.y))
                if session.shape == .ellipse {
                    Ellipse()
                        .stroke(color, lineWidth: max(1, session.lineWidth * canvas.zoom))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                } else {
                    Rectangle()
                        .stroke(color, lineWidth: max(1, session.lineWidth * canvas.zoom))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            case .line, .arrow:
                Path { path in
                    path.move(to: a)
                    path.addLine(to: b)
                    if session.shape == .arrow {
                        let angle = atan2(b.y - a.y, b.x - a.x)
                        let head: CGFloat = max(10, session.lineWidth * 4) * canvas.zoom
                        for offset in [CGFloat.pi * 0.75, -CGFloat.pi * 0.75] {
                            path.move(to: b)
                            path.addLine(to: CGPoint(x: b.x + head * cos(angle + offset),
                                                     y: b.y + head * sin(angle + offset)))
                        }
                    }
                }
                .stroke(color, lineWidth: max(1, session.lineWidth * canvas.zoom))
            }
        }
    }

    @ViewBuilder
    private func strokePreview(_ t: ImageCanvasTransform) -> some View {
        if (session.tool == .brush || session.tool == .eraser),
           strokePoints.count >= 1 {
            Path { path in
                let pts = strokePoints.map { t.canvasPoint(fromBasePixel: $0) }
                guard let first = pts.first else { return }
                path.move(to: first)
                if pts.count == 1 {
                    path.addLine(to: CGPoint(x: first.x + 0.1, y: first.y))
                } else {
                    for p in pts.dropFirst() { path.addLine(to: p) }
                }
            }
            .stroke(session.tool == .eraser ? Color.white.opacity(0.5)
                                            : session.primaryColor.opacity(session.brushOpacity),
                    style: StrokeStyle(lineWidth: session.brushSize, lineCap: .round,
                                       lineJoin: .round))
            .opacity(0.75)
        }
    }

    @ViewBuilder
    private func cropOverlay(_ t: ImageCanvasTransform) -> some View {
        if session.tool == .crop, let rect = cropRect {
            let c = t.canvasRect(fromBaseRect: rect)
            let full = CGRect(origin: .zero, size: canvas.containerSize)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(full); path.addRect(c)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                Rectangle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
                    .frame(width: c.width, height: c.height)
                    .offset(x: c.minX, y: c.minY)
                Path { path in
                    for i in 1...2 {
                        let x = c.minX + c.width * CGFloat(i) / 3
                        path.move(to: CGPoint(x: x, y: c.minY))
                        path.addLine(to: CGPoint(x: x, y: c.maxY))
                        let y = c.minY + c.height * CGFloat(i) / 3
                        path.move(to: CGPoint(x: c.minX, y: y))
                        path.addLine(to: CGPoint(x: c.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                // 8 个手柄（角 10pt / 边 8pt）
                ForEach(Array(cropHandlePoints(c).enumerated()), id: \.offset) { _, item in
                    Rectangle()
                        .fill(Color.white)
                        .overlay(Rectangle().stroke(Color.black.opacity(0.7), lineWidth: 1))
                        .frame(width: item.size, height: item.size)
                        .position(item.point)
                }
                // 尺寸标签（图片像素）
                Text(verbatim: "\(Int(rect.width)) × \(Int(rect.height)) px")
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.65)))
                    .foregroundStyle(.white)
                    .position(x: c.midX, y: max(c.minY - 14, 12))
            }
        }
    }

    @ViewBuilder
    private func brushCursor(_ t: ImageCanvasTransform) -> some View {
        if (session.tool == .brush || session.tool == .eraser || session.tool == .retouch),
           let hover = hoverCanvas {
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
                .background(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
                .frame(width: max(2, session.brushSize * canvas.zoom),
                       height: max(2, session.brushSize * canvas.zoom))
                .position(hover)
        }
    }

    @ViewBuilder
    private func textCard(anchor: CGPoint) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $textEntry)
                .font(.system(size: 12))
                .frame(width: 260, height: 84)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor)))
                .focused($textFocused)
            HStack {
                Button(String(localized: "Place")) { commitText() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(String(localized: "Cancel")) {
                    showTextEntry = false
                    textAnchor = nil
                    editingTextID = nil
                    refocusCanvas()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .position(x: min(max(anchor.x, 150), canvas.containerSize.width - 150),
                  y: max(anchor.y, 50))
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                textFocused = true
            }
        }
    }

    @ViewBuilder
    private func cropBar(rect: CGRect) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(Int(rect.width)) × \(Int(rect.height))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Button(String(localized: "Apply")) { applyCrop() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(String(localized: "Cancel")) {
                cropRect = nil
                session.tool = .move
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(12)
    }

    // MARK: - 事件

    private func handlePoint(_ kind: ImageEventCatcher.Kind,
                             _ point: CGPoint,
                             _ flags: NSEvent.ModifierFlags) {
        let t = transform
        switch kind {
        case .moved:
            hoverCanvas = point
            session.cursorBase = t.basePixel(fromCanvas: point)
        case .exited:
            hoverCanvas = nil
            session.cursorBase = nil
        case .down:
            down(t, point, flags)
        case .dragged:
            dragged(t, point)
        case .up:
            up(t, point)
        }
        syncProbe()
    }

    private func down(_ t: ImageCanvasTransform, _ point: CGPoint,
                      _ flags: NSEvent.ModifierFlags) {
        let base = t.basePixel(fromCanvas: point)
        #if DEBUG
        // 事件时刻几何快照（大图错位排查：事后探针可能已被首帧 fit 覆盖）
        ImageEditorDebug.lastStamp["evtZoom"] = Double(t.zoom)
        ImageEditorDebug.lastStamp["evtOriginX"] = Double(t.origin.x)
        ImageEditorDebug.lastStamp["evtOriginY"] = Double(t.origin.y)
        ImageEditorDebug.lastStamp["evtContainerW"] = Double(t.containerSize.width)
        ImageEditorDebug.lastStamp["evtContainerH"] = Double(t.containerSize.height)
        ImageEditorDebug.lastStamp["evtDisplayW"] = Double(t.displaySize.width)
        ImageEditorDebug.lastStamp["evtDisplayH"] = Double(t.displaySize.height)
        ImageEditorDebug.lastStamp["evtCanvasX"] = Double(point.x)
        ImageEditorDebug.lastStamp["evtCanvasY"] = Double(point.y)
        ImageEditorDebug.lastStamp["evtBaseX"] = Double(base.x)
        ImageEditorDebug.lastStamp["evtBaseY"] = Double(base.y)
        #endif
        if document.isActiveLayerLocked,
           [.brush, .eraser, .text, .shape, .move].contains(session.tool) {
            session.flash(String(localized: "Layer is locked"))
            return
        }
        // 画笔/形状/文字按文档坐标绘制；图层有缩放/旋转/偏移时先烘平，
        // 否则坐标会被二次变换。
        if [.brush, .eraser, .shape, .text, .gradient].contains(session.tool) {
            document.bakeActiveLayerGeometry()
        }
        switch session.tool {
        case .hand:
            panLast = point
        case .move:
            moveStart = base
            moveStartOffset = document.activeLayerOffset
            document.beginContinuousEdit("Move")
        case .zoom:
            canvas.zoom(by: flags.contains(.option) ? 0.8 : 1.25, anchor: point)
        case .retouch:
            if [.clone, .heal].contains(session.retouchMode), flags.contains(.option) {
                session.cloneSample = base
                session.flash(String(localized: "Sample set"))
                return
            }
            document.beginContinuousEdit(session.retouchMode.localizedTitle)
            retouchStart = base
            retouchLast = base
            session.beginLiveRetouch()
            applyRetouch(to: base)
        case .eyedropper:
            if let color = document.sampleColor(at: base) {
                session.setPrimaryColor(color)
            }
        case .brush, .eraser:
            strokePoints = [base]
        case .marquee, .shape, .gradient:
            combineMode = selectionCombine(from: flags)
            dragStart = base
            dragCurrent = base
        case .crop:
            downCrop(point)
        case .lasso:
            combineMode = selectionCombine(from: flags)
            lassoPoints = [base]
        case .wand:
            combineMode = selectionCombine(from: flags)
        case .text:
            // 点回已有文字 = 重编辑（规格载入卡片与工具选项）；
            // 点空白 = 新建文字层。
            if let hit = document.textLayerID(at: base),
               let spec = document.textSpec(of: hit) {
                beginEditText(spec, layerID: hit)
            } else {
                textAnchor = base
                textEntry = ""
                editingTextID = nil
                showTextEntry = true
            }
        }
    }

    private func dragged(_ t: ImageCanvasTransform, _ point: CGPoint) {
        let base = t.basePixel(fromCanvas: point)
        session.cursorBase = base
        switch session.tool {
        case .hand:
            if let last = panLast {
                canvas.pan = CGSize(width: canvas.pan.width + point.x - last.x,
                                    height: canvas.pan.height + point.y - last.y)
            }
            panLast = point
        case .move:
            if let start = moveStart {
                var target = CGSize(width: moveStartOffset.width + base.x - start.x,
                                    height: moveStartOffset.height + base.y - start.y)
                if session.snapping,
                   let size = document.activeBitmap.map({
                       CGSize(width: CGFloat($0.width), height: CGFloat($0.height)) }) {
                    target = snapOffset(target, layerSize: size)
                }
                document.setLayerOffset(document.activeLayerID, target)
            }
        case .brush, .eraser:
            strokePoints.append(base)
        case .retouch:
            let start = retouchLast ?? base
            let dist = hypot(base.x - start.x, base.y - start.y)
            let step = max(1, session.brushSize * 0.25)
            var t: CGFloat = 0
            while t < dist {
                t += step
                let p = CGPoint(x: start.x + (base.x - start.x) * (t / dist),
                                y: start.y + (base.y - start.y) * (t / dist))
                applyRetouch(to: p)
            }
            retouchLast = base
        case .marquee, .shape, .gradient:
            dragCurrent = base
        case .crop:
            dragCrop(point)
        case .lasso:
            if lassoPoints.last.map({ hypot($0.x - base.x, $0.y - base.y) > 2 }) ?? true {
                lassoPoints.append(base)
            }
        case .eyedropper:
            if let color = document.sampleColor(at: base) {
                session.setPrimaryColor(color)
            }
        case .wand, .text, .zoom:
            break
        }
    }

    private func up(_ t: ImageCanvasTransform, _ point: CGPoint) {
        let base = t.basePixel(fromCanvas: point)
        switch session.tool {
        case .hand:
            panLast = nil
        case .move:
            moveStart = nil
        case .brush, .eraser:
            if strokePoints.isEmpty { strokePoints = [base] }
            commitStroke(t)
        case .marquee:
            if let start = dragStart {
                let rect = normalized(start, base)
                if rect.width >= 2, rect.height >= 2 {
                    document.setSelectionRect(rect, ellipse: session.marqueeEllipse,
                                              feather: session.selectionFeather,
                                              combine: combineMode)
                    session.flash(String(localized: "Selection created"))
                } else {
                    document.clearSelection()
                }
            }
            dragStart = nil
            dragCurrent = nil
        case .lasso:
            lassoPoints.append(base)
            if lassoPoints.count >= 3 {
                let mask = ImageEditorRaster.polygonMask(points: lassoPoints,
                                                         size: document.canvasSize,
                                                         feather: 0)
                document.setSelectionMask(mask, feather: session.selectionFeather,
                                          combine: combineMode)
                session.flash(String(localized: "Lasso selection"))
            }
            lassoPoints = []
        case .wand:
            guard let composite = document.composite(),
                  let mask = ImageSelectionAdvanced.magicWandMask(
                      image: composite, start: base,
                      tolerance: session.wandTolerance, contiguous: true) else { return }
            document.setSelectionMask(mask, feather: session.selectionFeather,
                                      combine: combineMode)
            session.flash(String(localized: "Magic wand selection"))
        case .shape:
            commitShape(t)
        case .gradient:
            commitGradient()
        case .crop:
            upCrop()
        case .retouch:
            if [.blur, .sharpen].contains(session.retouchMode) {
                applyDeferredRetouch(at: base)
            }
            session.endLiveRetouch()
            retouchStart = nil
            retouchLast = nil
        case .eyedropper, .text, .zoom:
            break
        }
        syncProbe()
    }

    // MARK: - 提交

    /// 一次修饰戳：直接画进常驻上下文（克隆=平移取源，减淡/加深=渐变混合），
    /// 然后把上下文快照推给文档显示。模糊/锐化留到松手（模式不支持实时）。
    private func applyRetouch(to point: CGPoint) {
        guard [.clone, .heal, .dodge, .burn].contains(session.retouchMode),
              let ctx = session.liveRetouchContext,
              let mask = session.liveRetouchMask,
              let base = session.liveRetouchBase else { return }
        let r = max(1, session.liveRetouchRadius)
        let stampRect = CGRect(x: point.x - r, y: point.y - r,
                               width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.clip(to: stampRect, mask: mask)
        switch session.retouchMode {
        case .clone, .heal:
            if let sample = session.cloneSample {
                let base2 = session.liveRetouchBase ?? base
                ctx.draw(base2, in: stampRect.offsetBy(
                    dx: point.x - sample.x, dy: point.y - sample.y))
            }
        case .dodge, .burn:
            let colors = session.retouchMode == .dodge
                ? [CGColor(gray: 1, alpha: CGFloat(session.retouchStrength) * 0.5),
                   CGColor(gray: 1, alpha: 0)] as CFArray
                : [CGColor(gray: 0, alpha: CGFloat(session.retouchStrength) * 0.7),
                   CGColor(gray: 0, alpha: 0)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors, locations: [0, 1]) {
                ctx.setBlendMode(session.retouchMode == .dodge ? .plusLighter : .multiply)
                ctx.drawRadialGradient(gradient,
                                       startCenter: point, startRadius: 0,
                                       endCenter: point, endRadius: r, options: [])
                ctx.setBlendMode(.normal)
            }
        default:
            break
        }
        ctx.restoreGState()
        if let image = ctx.makeImage() {
            document.setBitmapLive(document.activeLayerID, image)
        }
    }

    /// 模糊/锐化：松手时整幅应用一次（区域版留待后续）。
    private func applyDeferredRetouch(at point: CGPoint) {
        guard let bitmap = document.activeBitmap else { return }
        let effect: CGImage?
        if session.retouchMode == .blur {
            effect = ImageEditorRaster.blurred(bitmap, radius: max(1, session.brushSize * 0.35))
        } else {
            effect = ImageEditorRaster.sharpened(bitmap, amount: 0.8)
        }
        guard let effect else { return }
        document.setBitmapLive(document.activeLayerID, effect)
    }

    /// 网格（每 50 图像像素，过密自动放大间距）+ 中心/三分参考线。
    @ViewBuilder
    private func guideOverlay(_ t: ImageCanvasTransform) -> some View {
        if session.showGrid || session.showCenterGuides {
            let content = t.contentSize
            let origin = t.origin
            Path { path in
                if session.showGrid {
                    var step: CGFloat = 50
                    while step * t.zoom < 14 { step *= 2 }
                    var x = step
                    while x < t.displaySize.width {
                        path.move(to: CGPoint(x: origin.x + x * t.zoom, y: origin.y))
                        path.addLine(to: CGPoint(x: origin.x + x * t.zoom,
                                                 y: origin.y + content.height))
                        x += step
                    }
                    var y = step
                    while y < t.displaySize.height {
                        path.move(to: CGPoint(x: origin.x, y: origin.y + y * t.zoom))
                        path.addLine(to: CGPoint(x: origin.x + content.width,
                                                 y: origin.y + y * t.zoom))
                        y += step
                    }
                }
                if session.showCenterGuides {
                    for ratio in [CGFloat(0.5), 1.0 / 3.0, 2.0 / 3.0] {
                        let x = origin.x + content.width * ratio
                        path.move(to: CGPoint(x: x, y: origin.y))
                        path.addLine(to: CGPoint(x: x, y: origin.y + content.height))
                        let y = origin.y + content.height * ratio
                        path.move(to: CGPoint(x: origin.x, y: y))
                        path.addLine(to: CGPoint(x: origin.x + content.width, y: y))
                    }
                }
            }
            .stroke(Color.white.opacity(session.showGrid ? 0.10 : 0.16), lineWidth: 0.6)
        }
    }

    /// 移动吸附：图层中心靠近画布中心/三分线时对齐（阈值 6 图像像素）。
    private func snapOffset(_ offset: CGSize, layerSize: CGSize) -> CGSize {
        let canvas = document.canvasSize
        let threshold: CGFloat = 6
        var result = offset
        let centerX = offset.width + layerSize.width / 2
        let centerY = offset.height + layerSize.height / 2
        for ratio in [CGFloat(0.5), 1.0 / 3.0, 2.0 / 3.0] {
            let targetX = canvas.width * ratio
            if abs(centerX - targetX) <= threshold {
                result.width = targetX - layerSize.width / 2
            }
            let targetY = canvas.height * ratio
            if abs(centerY - targetY) <= threshold {
                result.height = targetY - layerSize.height / 2
            }
        }
        return CGSize(width: result.width.rounded(), height: result.height.rounded())
    }

    @ViewBuilder
    private func cloneSampleMarker(_ t: ImageCanvasTransform) -> some View {
        if session.tool == .retouch, let sample = session.cloneSample {
            let p = t.canvasPoint(fromBasePixel: sample)
            ZStack {
                Circle().stroke(Color.white, lineWidth: 1.2).frame(width: 14, height: 14)
                Rectangle().fill(Color.white).frame(width: 18, height: 1)
                Rectangle().fill(Color.white).frame(width: 1, height: 18)
            }
            .shadow(color: .black.opacity(0.6), radius: 1)
            .position(p)
        }
    }

    private func commitStroke(_ t: ImageCanvasTransform) {
        _ = t
        defer { strokePoints = [] }
        guard let bitmap = document.activeBitmap, strokePoints.isEmpty == false else { return }
        let erase = session.tool == .eraser
        let mask = document.selection.maskImage(canvasSize: document.canvasSize)
        guard let output = ImageEditorRaster.stroke(
            bitmap, points: strokePoints,
            size: session.brushSize,
            color: session.primaryCGColor,
            opacity: session.brushOpacity,
            hardness: session.brushHardness,
            erase: erase,
            clipMask: mask,
            contentOffset: document.activeLayerOffset) else { return }
        document.replaceActiveBitmap(output, title: erase ? "Erase" : "Brush")
    }

    private func commitGradient() {
        defer {
            dragStart = nil
            dragCurrent = nil
        }
        guard let start = dragStart, let end = dragCurrent,
              let bitmap = document.activeBitmap else { return }
        let colors = [session.primaryCGColor, ImageEditorRaster.color(from: NSColor(session.secondaryColor))]
        let mask = document.selection.maskImage(canvasSize: document.canvasSize)
        guard let output = ImageEditorRaster.drawGradient(
            bitmap, from: start, to: end, colors: colors,
            radial: session.gradientRadial, clipMask: mask,
            contentOffset: document.activeLayerOffset) else { return }
        document.replaceActiveBitmap(output, title: String(localized: "Gradient"))
    }

    private func commitShape(_ t: ImageCanvasTransform) {
        defer {
            dragStart = nil
            dragCurrent = nil
        }
        guard let start = dragStart, let current = dragCurrent,
              let bitmap = document.activeBitmap else { return }
        let width = session.lineWidth
        var fill: CGColor?
        if session.fillShapes, session.shape == .rectangle || session.shape == .ellipse {
            fill = session.primaryCGColor
        }
        let stroke = session.shape == .rectangle || session.shape == .ellipse
            ? (session.fillShapes ? nil : session.primaryCGColor)
            : session.primaryCGColor
        guard let output = ImageEditorRaster.drawShape(
            bitmap, shape: session.shape, from: start, to: current,
            stroke: stroke, fill: fill, lineWidth: width,
            cornerRadius: session.cornerRadius, dashed: session.dashedStroke,
            contentOffset: document.activeLayerOffset) else { return }
        document.replaceActiveBitmap(output, title: session.shape.localizedTitle)
    }

    /// 把会话里的文字样式字段装进规格（hex 存色）。
    private func textSpec(text: String, anchor: CGPoint) -> ImageTextSpec {
        var spec = ImageTextSpec(text: text, anchorX: Double(anchor.x), anchorY: Double(anchor.y))
        spec.fontName = session.textFontFamily
        spec.weight = session.textWeight
        spec.fontSize = Double(session.fontSize)
        spec.colorHex = ImageEditorRaster.hexString(from: session.primaryCGColor)
        spec.alignment = session.textAlignment
        spec.lineSpacing = session.textLineSpacing
        spec.strokeWidth = Double(session.textStrokeWidth)
        spec.strokeColorHex = ImageEditorRaster.hexString(
            from: ImageEditorRaster.color(from: NSColor(session.textStrokeColor)))
        spec.shadow = session.textShadow
        if session.textBackground {
            spec.backgroundHex = ImageEditorRaster.hexString(
                from: ImageEditorRaster.color(from: NSColor(session.textBackgroundColor)))
        }
        return spec
    }

    /// 点回文字层：规格载入会话（卡片与选项栏跟随），进入重编辑态。
    private func beginEditText(_ spec: ImageTextSpec, layerID: UUID) {
        editingTextID = layerID
        document.selectLayer(layerID)
        textEntry = spec.text
        textAnchor = spec.anchor
        session.textFontFamily = spec.fontName
        session.textWeight = spec.weight
        session.fontSize = CGFloat(spec.fontSize)
        if let c = ImageEditorRaster.color(from: spec.colorHex) {
            session.primaryColor = Color(nsColor: NSColor(cgColor: c) ?? .white)
        }
        session.textAlignment = spec.alignment
        session.textLineSpacing = spec.lineSpacing
        session.textStrokeWidth = CGFloat(spec.strokeWidth)
        if let c = ImageEditorRaster.color(from: spec.strokeColorHex) {
            session.textStrokeColor = Color(nsColor: NSColor(cgColor: c) ?? .black)
        }
        session.textShadow = spec.shadow
        if let hex = spec.backgroundHex,
           let c = ImageEditorRaster.color(from: hex) {
            session.textBackground = true
            session.textBackgroundColor = Color(nsColor: NSColor(cgColor: c) ?? .black)
        } else {
            session.textBackground = false
        }
        showTextEntry = true
    }

    private func commitText() {
        defer {
            showTextEntry = false
            textAnchor = nil
            editingTextID = nil
            refocusCanvas()
        }
        let trimmed = textEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        // 重编辑：空文本 = 删除该文字层；否则按当前样式重渲染（锚点保留原位）。
        if let id = editingTextID {
            guard trimmed.isEmpty == false else {
                document.selectLayer(id)
                document.deleteActiveLayer()
                return
            }
            let anchor = document.textSpec(of: id)?.anchor
                ?? textAnchor
                ?? CGPoint(x: 20, y: 20)
            _ = document.updateTextLayer(id, spec: textSpec(text: trimmed, anchor: anchor))
            return
        }
        // 新建：文字 = 自己的透明图层（烙进当前层的老行为废弃——不可再编辑）。
        guard let anchor = textAnchor, trimmed.isEmpty == false else { return }
        _ = document.addTextLayer(spec: textSpec(text: trimmed, anchor: anchor))
    }

    // MARK: - 裁剪（拖框 + 8 手柄 + 框内拖动 + 双击应用）

    private func downCrop(_ point: CGPoint) {
        let t = transform
        if let rect = cropRect {
            let canvasRect = t.canvasRect(fromBaseRect: rect)
            if Date().timeIntervalSince(lastCropClick) < 0.35,
               canvasRect.insetBy(dx: -6, dy: -6).contains(point) {
                applyCrop()
                return
            }
            if let handle = cropHandle(at: point, in: canvasRect) {
                cropDrag = CropDrag(handle: handle, startPoint: point,
                                    startRect: rect, createdNew: false)
                lastCropClick = Date()
                return
            }
        }
        // 新建框：起点吸附到图像像素
        let start = clampToCanvas(t.basePixel(fromCanvas: point))
        cropRect = CGRect(origin: start, size: .zero)
        cropDrag = CropDrag(handle: .bottomRight, startPoint: point,
                            startRect: CGRect(origin: start, size: .zero),
                            createdNew: true)
        lastCropClick = Date()
    }

    private func dragCrop(_ point: CGPoint) {
        guard let drag = cropDrag else { return }
        let t = transform
        let current = clampToCanvas(t.basePixel(fromCanvas: point))
        let start = drag.startRect
        var rect: CGRect
        if drag.createdNew {
            rect = normalized(start.origin, current)
        } else if drag.handle == .inside {
            let startCanvas = t.basePixel(fromCanvas: drag.startPoint)
            let dx = current.x - startCanvas.x
            let dy = current.y - startCanvas.y
            rect = start.offsetBy(dx: dx, dy: dy)
            rect = clampRectInsideCanvas(rect)
        } else {
            var minX = start.minX, minY = start.minY
            var maxX = start.maxX, maxY = start.maxY
            switch drag.handle {
            case .topLeft: minX = current.x; minY = current.y
            case .topRight: maxX = current.x; minY = current.y
            case .bottomLeft: minX = current.x; maxY = current.y
            case .bottomRight: maxX = current.x; maxY = current.y
            case .top: minY = current.y
            case .bottom: maxY = current.y
            case .left: minX = current.x
            case .right: maxX = current.x
            case .inside: break
            }
            rect = CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        }
        rect = applyCropAspect(rect, createdNew: drag.createdNew)
        rect = clampRectInsideCanvas(rect)
        cropRect = CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(),
                          width: rect.width.rounded(), height: rect.height.rounded())
    }

    private func upCrop() {
        cropDrag = nil
        if let rect = cropRect, rect.width < 4 || rect.height < 4 {
            cropRect = nil
        }
    }

    private func cropHandle(at point: CGPoint, in rect: CGRect) -> CropHandle? {
        let tol: CGFloat = 12
        let pts: [(CropHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.top, CGPoint(x: rect.midX, y: rect.minY)),
            (.bottom, CGPoint(x: rect.midX, y: rect.maxY)),
            (.left, CGPoint(x: rect.minX, y: rect.midY)),
            (.right, CGPoint(x: rect.maxX, y: rect.midY)),
        ]
        for (handle, p) in pts where abs(point.x - p.x) <= tol && abs(point.y - p.y) <= tol {
            return handle
        }
        if rect.contains(point) { return .inside }
        return nil
    }

    private func applyCropAspect(_ rect: CGRect, createdNew: Bool) -> CGRect {
        guard session.cropAspect > 0, rect.width > 1, rect.height > 1 else { return rect }
        var r = rect
        if createdNew {
            if r.width / session.cropAspect < r.height {
                r.size.height = r.width / session.cropAspect
            } else {
                r.size.width = r.height * session.cropAspect
            }
        } else {
            // 手柄调整：以宽为主锁比例
            r.size.height = r.width / session.cropAspect
        }
        return r
    }

    private func clampToCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), document.canvasSize.width),
                y: min(max(0, p.y), document.canvasSize.height))
    }

    private func clampRectInsideCanvas(_ rect: CGRect) -> CGRect {
        let bounds = CGRect(origin: .zero, size: document.canvasSize)
        var r = rect.intersection(bounds)
        if r.isNull { r = .zero }
        return r
    }

    /// 裁剪框 8 个手柄的画布坐标（绘制与命中判定共用一套位置）。
    private func cropHandlePoints(_ rect: CGRect) -> [(point: CGPoint, size: CGFloat)] {
        let corner: CGFloat = 10
        let edge: CGFloat = 8
        return [
            (CGPoint(x: rect.minX, y: rect.minY), corner),
            (CGPoint(x: rect.maxX, y: rect.minY), corner),
            (CGPoint(x: rect.minX, y: rect.maxY), corner),
            (CGPoint(x: rect.maxX, y: rect.maxY), corner),
            (CGPoint(x: rect.midX, y: rect.minY), edge),
            (CGPoint(x: rect.midX, y: rect.maxY), edge),
            (CGPoint(x: rect.minX, y: rect.midY), edge),
            (CGPoint(x: rect.maxX, y: rect.midY), edge),
        ]
    }
    private func applyCrop() {
        guard let rect = cropRect else { return }
        document.crop(to: rect)
        cropRect = nil
        session.tool = .move
        session.flash(String(localized: "Cropped"))
        syncContainer(canvas.containerSize)
    }

    /// ⇧ = 加选，⌥ = 减选，⇧⌥ = 交叉。
    private func selectionCombine(from flags: NSEvent.ModifierFlags)
        -> ImageEditorRaster.SelectionCombine {
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        if shift && option { return .intersect }
        if shift { return .add }
        if option { return .subtract }
        return .replace
    }

    /// 文字输入结束/取消后把第一响应者还给画布，单键快捷键立即可用。
    private func refocusCanvas() {
        guard let view = ImageEventCatcher.EventView.active else { return }
        view.window?.makeFirstResponder(view)
    }

    // MARK: - 工具函数

    private func normalized(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
