import SwiftUI
import Vision

/// 图片编辑器（v0.8.12 旗舰 D，19+20）：macOS 预览量级——旋转/翻转/裁剪/
/// 尺寸 + 画笔/箭头/矩形/文字/马赛克标注。零第三方依赖；⌘S 保存（.bak
/// 快照 + 原子写）；⌘Z 单步撤销（操作历史栈）。
struct ImageEditorView: View {
    @Environment(\.appAccent) private var appAccent: Color
    let fileURL: URL
    let fileName: String
    let onBack: () -> Void

    // MARK: - 状态

    /// 当前显示位图（每次操作生成新 CGImage——不可变值语义，⌘Z 即回退栈）。
    @State private var image: CGImage?
    /// 操作历史（undo 栈；上限 20）。
    @State private var history: [CGImage] = []
    /// 历史面板（v0.8.13 基础件 2）：每步的操作名与栈（栈底=原图）。
    @State private var historySteps: [String] = []
    @State private var showHistory = false
    @State private var loadError: String?
    @State private var hasUnsavedChanges = false
    @State private var statusNote: String?

    // 裁剪
    @State private var cropMode = false
    @State private var cropStart: CGPoint?
    @State private var cropRect: CGRect?
    @State private var cropAspect: CGFloat = 0   // 0 = 自由

    // 标注
    enum Tool: String, CaseIterable {
        case none, brush, arrow, line, rectangle, ellipse, polygon, text, bubble, mosaic
        var icon: String {
            switch self {
            case .none: "cursorarrow"
            case .brush: "paintbrush"
            case .arrow: "arrow.up.right"
            case .line: "line.diagonal"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .polygon: "diamond"
            case .text: "textformat"
            case .bubble: "number.circle"
            case .mosaic: "square.grid.3x3"
            }
        }
    }
    @State private var tool: Tool = .none
    @State private var strokeColor: Color = .red
    @State private var strokeWidth: CGFloat = 3
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    /// 画笔轨迹（当前笔画；松手烙进叠加层）。
    @State private var brushPoints: [CGPoint] = []
    /// 多边形（v0.8.15）：单击加点，点回首点附近闭合；切换工具清空。
    @State private var polygonPoints: [CGPoint] = []
    @State private var polygonDragStart: CGPoint?
    /// 序号气泡（v0.8.15）：点击落位自动编号。
    @State private var bubbleCounter = 0

    // 文字标注
    @State private var textEntry = ""
    @State private var showTextEntry = false
    @State private var textAnchor: CGPoint?

    // 尺寸调整
    @State private var showResize = false
    @State private var resizeWidth = ""

    /// 视图显示尺寸（点击坐标 → 位图像素换算用）。
    @State private var displaySize: CGSize = .zero
    /// 缩放（v0.8.17 增补）：1 = 100% 原始像素；fitZoom = 适应窗口。
    @State private var zoom: CGFloat = 1
    @State private var fitZoom: CGFloat = 1
    @State private var isFitMode = true
    @State private var containerSize: CGSize = .zero
    @State private var pinchBase: CGFloat = 1
    /// 调色面板（21）与滤镜预设（v0.8.27 媒体批）与 OCR（22）。
    @State private var showAdjustments = false
    @State private var showFilters = false
    @State private var brightness: Double = 0
    @State private var contrast: Double = 1
    @State private var saturation: Double = 1
    @State private var sharpen: Double = 0
    @State private var exposure: Double = 0
    @State private var temperature: Double = 0
    @State private var ocrRunning = false
    @State private var ocrResult: String?

    /// 显示位图与实际位图之间的缩放比。
    private var displayScale: CGFloat {
        guard let image, displaySize.width > 0 else { return 1 }
        return CGFloat(image.width) / displaySize.width
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            canvas
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: load)
        .sheet(isPresented: $showResize) { resizeSheet }
        .onChange(of: tool) { _, _ in
            polygonPoints = []
            polygonDragStart = nil
        }
    }

    // MARK: - 加载 / 保存

    private func load() {
        if let cg = ImageTransforms.load(from: fileURL) {
            image = cg
            history = []
            hasUnsavedChanges = false
            isFitMode = true
            zoom = 1
            pinchBase = 1
            // fitZoom 量完容器后由 recomputeFit 收敛；先给个保守初值防闪。
            DispatchQueue.main.async { recomputeFit() }
        } else {
            loadError = String(localized: "Could not load this image.")
        }
    }

    private func save() {
        guard let image else { return }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: fileURL.path) {
                let backup = fileURL.deletingPathExtension()
                    .appendingPathExtension(fileURL.pathExtension + ".bak")
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: fileURL, to: backup)
            }
            try ImageTransforms.save(image, to: fileURL)
            hasUnsavedChanges = false
            flash(String(localized: "Saved (.bak snapshot written)"))
        } catch {
            flash(String(localized: "Save failed: \(error.localizedDescription)"))
        }
    }

    /// 缩放（钳 5%~800%）；手动缩放退出"适应窗口"。
    private func setZoom(_ value: CGFloat) {
        zoom = min(8, max(0.05, value))
        isFitMode = false
    }

    /// 容器尺寸 → 适应窗口比例（画布 padding 20 两侧）。
    private func recomputeFit() {
        guard let image, containerSize.width > 40, containerSize.height > 40 else { return }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        fitZoom = min(1, min((containerSize.width - 40) / w, (containerSize.height - 40) / h))
        if isFitMode { zoom = fitZoom }
    }

    private func flash(_ text: String) {
        statusNote = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if statusNote == text { statusNote = nil }
        }
    }

    /// 应用一个变换（压栈 undo、标记未保存）。
    private func apply(label: String = String(localized: "Transform"), transform: (CGImage) -> CGImage?) {
        guard let current = image, let next = transform(current) else {
            flash(String(localized: "Transform failed"))
            return
        }
        pushHistory(current, label: label)
        image = next
        hasUnsavedChanges = true
        cropRect = nil
        cropMode = false
    }

    /// 压栈（v0.8.13 历史面板）：栈满丢弃最旧一步，历史条目同步。
    private func pushHistory(_ snapshot: CGImage, label: String) {
        history.append(snapshot)
        historySteps.append(label)
        if history.count > 20 {
            history.removeFirst()
            historySteps.removeFirst()
        }
    }

    /// 跳回任意一步：撤销栈顶到目标深度（栈保留目标之前的部分）。
    private func jumpToHistoryStep(_ depth: Int) {
        guard history.indices.contains(depth) else { return }
        let target = history[depth]
        history.removeSubrange((depth + 1)...)
        historySteps.removeSubrange((depth + 1)...)
        image = target
        hasUnsavedChanges = true
        cropRect = nil
    }

    private func undo() {
        guard let previous = history.popLast() else { return }
        if !historySteps.isEmpty { historySteps.removeLast() }
        image = previous
        hasUnsavedChanges = true
    }

    // MARK: - 子视图

    private var header: some View {
        HStack(spacing: 10) {
            Button { onBack() } label: {
                Label(String(localized: "Back to Page"), systemImage: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
            Text(fileName)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            if let image {
                Text("\(image.width) × \(image.height)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if hasUnsavedChanges {
                Text("Edited")
                    .font(.system(size: 9.5, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            // 缩放组（v0.8.17 增补）：-/百分比/+/适应/1:1，⌘=/⌘-/⌘0。
            if image != nil {
                HStack(spacing: 4) {
                    Button { setZoom(zoom / 1.25) } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("-", modifiers: .command)
                    .help("Zoom Out (⌘-)")
                    Text("\(Int((zoom * 100).rounded()))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 38)
                        .contentShape(Rectangle())
                        .onTapGesture { setZoom(1) }
                    Button { setZoom(zoom * 1.25) } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("=", modifiers: .command)
                    .help("Zoom In (⌘=)")
                    Button {
                        isFitMode = true
                        setZoom(fitZoom)
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("0", modifiers: .command)
                    .help("Fit to Window (⌘0)")
                    Button { setZoom(1) } label: {
                        Text("1:1").font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Actual Pixels")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
            Button { undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(history.isEmpty)
            .keyboardShortcut("z", modifiers: .command)
            .help("Undo (⌘Z)")
            Button {
                save()
            } label: {
                Label(String(localized: "Save (⌘S)"), systemImage: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
            .disabled(image == nil)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            // 变换
            button("rotateleft", "Rotate 90° Left") { apply(label: String(localized: "Rotate left"), transform: { ImageTransforms.rotated($0, clockwise: false) }) }
            button("rotateright", "Rotate 90° Right") { apply(label: String(localized: "Rotate right"), transform: { ImageTransforms.rotated($0, clockwise: true) }) }
            button("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip Horizontal") {
                apply(label: String(localized: "Flip horizontal"), transform: { ImageTransforms.flipped($0, horizontal: true) })
            }
            button("arrow.up.and.down.righttriangle.left.righttriangle.right", "Flip Vertical") {
                apply(label: String(localized: "Flip vertical"), transform: { ImageTransforms.flipped($0, horizontal: false) })
            }
            button("crop", "Crop") { cropMode.toggle() }
                .foregroundStyle(cropMode ? AnyShapeStyle(appAccent) : AnyShapeStyle(.primary))
            button("arrow.up.left.and.arrow.down.right", "Resize…") { showResize = true }

            Divider().frame(height: 16)

            // 标注工具
            ForEach(Tool.allCases, id: \.rawValue) { t in
                button(t.icon, t.rawValue.capitalized) { tool = t }
                    .foregroundStyle(tool == t ? AnyShapeStyle(appAccent) : AnyShapeStyle(.primary))
            }
            button("clock.arrow.circlepath", "History") { showHistory.toggle() }
                .foregroundStyle(showHistory ? AnyShapeStyle(appAccent) : AnyShapeStyle(.primary))
            ColorPicker("", selection: $strokeColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 26)

            Divider().frame(height: 16)
            button("slider.horizontal.3", "Adjustments…") {
                showAdjustments.toggle()
                if showAdjustments { showFilters = false }
            }
                .foregroundStyle(showAdjustments ? AnyShapeStyle(appAccent) : AnyShapeStyle(.primary))
            button("camera.filters", "Filters…") {
                showFilters.toggle()
                if showFilters { showAdjustments = false }
            }
                .foregroundStyle(showFilters ? AnyShapeStyle(appAccent) : AnyShapeStyle(.primary))
            button("doc.text.viewfinder", "Extract Text (OCR)") { runOCR() }
            button("printer", "Print") { printImage() }
            Menu {
                Button(String(localized: "Export as PNG")) { exportAs(type: "png") }
                Button(String(localized: "Export as JPEG")) { exportAs(type: "jpg") }
                Button(String(localized: "Export as HEIC")) { exportAs(type: "heic") }
                Button(String(localized: "Export as TIFF")) { exportAs(type: "tiff") }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Export as…")

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func button(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - 画布

    @ViewBuilder
    private var canvas: some View {
        if let image, let nsImage = makeNSImage(image) {
            GeometryReader { container in
                ScrollView([.horizontal, .vertical]) {
                ZStack {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.medium)
                        .shadow(radius: 2)
                        .frame(width: CGFloat(image.width) * zoom,
                               height: CGFloat(image.height) * zoom)
                        .gesture(canvasGesture)
                        .simultaneousGesture(MagnificationGesture()
                            .onChanged { value in
                                if pinchBase == 1 { pinchBase = zoom }
                                setZoom(pinchBase * value)
                            }
                            .onEnded { _ in pinchBase = 1 })
                        .onTapGesture(count: 2) {
                            // 双击：适应 ↔ 1:1
                            if abs(zoom - fitZoom) < 0.01 {
                                setZoom(1)
                            } else {
                                isFitMode = true
                                setZoom(fitZoom)
                            }
                        }
                        // displaySize 量图片本体（非带 padding 外框）——
                        // displayScale 才是精确的像素/显示换算。
                        .background(
                            GeometryReader { geo in
                                Color.clear.onAppear { displaySize = geo.size }
                                    .onChange(of: geo.size) { _, size in
                                        displaySize = size
                                        recomputeFit()
                                    }
                            })
                        .overlay(cropOverlay)
                        .overlay(annotationOverlay)
                        // 裁剪选框/多边形预览用图片本地坐标（原先挂在
                        // ZStack 上与手势坐标系差一个 padding——缩放后放大暴露）。
                        .overlay(alignment: .topLeading) {
                            if cropMode, let rect = cropRect {
                                Rectangle()
                                    .strokeBorder(appAccent, lineWidth: 1.5)
                                    .background(appAccent.opacity(0.08))
                                    .frame(width: rect.width, height: rect.height)
                                    .offset(x: rect.minX, y: rect.minY)
                            }
                            if tool == .polygon, polygonPoints.count >= 1 {
                                Path { path in
                                    path.move(to: polygonPoints[0])
                                    for p in polygonPoints.dropFirst() { path.addLine(to: p) }
                                }
                                .stroke(appAccent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                ForEach(Array(polygonPoints.enumerated()), id: \.offset) { index, p in
                                    Circle()
                                        .fill(index == 0 ? appAccent : Color(nsColor: .controlAccentColor).opacity(0.8))
                                        .frame(width: 7, height: 7)
                                        .position(p)
                                }
                            }
                        }

                    if showAdjustments {
                        adjustmentsPanel
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(14)
                    }
                    if showFilters {
                        filtersPanel
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(14)
                    }
                    if showHistory {
                        historyPanel
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(14)
                    }
                    if ocrResult != nil {
                        ocrPanel
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(14)
                    }
                }
                .padding(20)
                .frame(width: CGFloat(image.width) * zoom + 40,
                       height: CGFloat(image.height) * zoom + 40, alignment: .topLeading)
                }
                .onAppear {
                    containerSize = container.size
                    recomputeFit()
                }
                .onChange(of: container.size) { _, size in
                    containerSize = size
                    recomputeFit()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                Text(loadError)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func makeNSImage(_ cg: CGImage) -> NSImage? {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// 画布手势：裁剪模式拖选框；标注工具按下/拖动。
    private var canvasGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = value.location
                if cropMode {
                    if let start = cropStart {
                        var rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                          width: abs(point.x - start.x), height: abs(point.y - start.y))
                        if cropAspect > 0 {
                            let byWidth = rect.width / cropAspect < rect.height
                            if byWidth { rect.size.height = rect.width / cropAspect }
                            else { rect.size.width = rect.height * cropAspect }
                        }
                        cropRect = rect
                    }
                    return
                }
                switch tool {
                case .brush:
                    brushPoints.append(point)
                case .arrow, .rectangle, .ellipse, .mosaic, .line:
                    if dragStart == nil { dragStart = point }
                    dragCurrent = point
                case .polygon:
                    if polygonDragStart == nil { polygonDragStart = point }
                case .text, .bubble, .none:
                    break
                }
            }
            .onEnded { value in
                if cropMode {
                    if let rect = cropRect, rect.width >= 8, rect.height >= 8 {
                        let pixel = CGRect(
                            x: rect.minX * displayScale,
                            y: rect.minY * displayScale,
                            width: rect.width * displayScale,
                            height: rect.height * displayScale)
                        apply(label: String(localized: "Crop"), transform: { ImageTransforms.cropped($0, rect: pixel) })
                        return
                    }
                    cropRect = nil
                    return
                }
                switch tool {
                case .brush:
                    if brushPoints.count >= 2 {
                        stampAnnotation(label: String(localized: "Brush")) { overlay in
                            drawPolyline(brushPoints, in: overlay)
                        }
                    }
                    brushPoints = []
                case .arrow:
                    stampLineAnnotation(from: dragStart ?? value.location, to: value.location, arrow: true)
                    dragStart = nil; dragCurrent = nil
                case .line:
                    stampLineAnnotation(from: dragStart ?? value.location, to: value.location, arrow: false)
                    dragStart = nil; dragCurrent = nil
                case .rectangle:
                    stampRectAnnotation(from: dragStart ?? value.location, to: value.location, ellipse: false)
                    dragStart = nil; dragCurrent = nil
                case .ellipse:
                    stampRectAnnotation(from: dragStart ?? value.location, to: value.location, ellipse: true)
                    dragStart = nil; dragCurrent = nil
                case .mosaic:
                    stampMosaic(from: dragStart ?? value.location, to: value.location)
                    dragStart = nil; dragCurrent = nil
                case .polygon:
                    // 点击式：按下-松开几乎没位移才算点；点回首点 16pt 内闭合。
                    let point = value.location
                    let dragged = polygonDragStart.map {
                        abs($0.x - point.x) > 6 || abs($0.y - point.y) > 6
                    } ?? true
                    polygonDragStart = nil
                    guard !dragged else { return }
                    if let first = polygonPoints.first, polygonPoints.count >= 3,
                       abs(first.x - point.x) < 16, abs(first.y - point.y) < 16 {
                        stampPolygon(polygonPoints)
                        polygonPoints = []
                    } else {
                        polygonPoints.append(point)
                    }
                case .bubble:
                    let point = value.location
                    let dragged = dragStart.map {
                        abs($0.x - point.x) > 6 || abs($0.y - point.y) > 6
                    } ?? false
                    dragStart = nil
                    guard !dragged else { return }
                    bubbleCounter += 1
                    stampBubble(at: point, number: bubbleCounter)
                case .text, .none:
                    break
                }
            }
    }

    /// 文字标注：非裁剪 + text 工具单击 = 弹输入，提交后烙字。
    private var annotationOverlay: some View {
        Group {
            if tool == .text {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        textAnchor = location
                        textEntry = ""
                        showTextEntry = true
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            if showTextEntry, let anchor = textAnchor {
                VStack(spacing: 4) {
                    TextField(String(localized: "Text to place"), text: $textEntry)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit { commitText(at: anchor) }
                    HStack {
                        Button(String(localized: "Place")) { commitText(at: anchor) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button(String(localized: "Cancel")) { showTextEntry = false }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
                .position(x: min(anchor.x + 130, max(140, displaySize.width - 130)),
                          y: max(anchor.y, 40))
            }
        }
    }

    private func commitText(at anchor: CGPoint) {
        let text = textEntry.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { showTextEntry = false; return }
        let nsColor = NSColor(strokeColor)
        let fontSize = max(14, 16 * displayScale)
        stampAnnotation(label: String(localized: "Text")) { overlay in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: nsColor,
                .paragraphStyle: paragraph,
            ]
            (text as NSString).draw(at: anchor, withAttributes: attributes)
            _ = overlay
        }
        showTextEntry = false
    }

    // MARK: - 标注烙印（CG 层）

    /// 在与当前位图同尺寸的透明画布上执行绘制 → 烙进图 → 压栈。
    private func stampAnnotation(label: String, _ draw: (CGContext) -> Void) {
        guard let current = image else { return }
        let w = current.width, h = current.height
        guard let overlay = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: current.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // 视图坐标 → 位图坐标（y 翻转：CG 原点左下）。
        overlay.translateBy(x: 0, y: CGFloat(h))
        overlay.scaleBy(x: displayScale, y: -displayScale)
        overlay.setLineCap(.round)
        draw(overlay)
        guard let overlayImage = overlay.makeImage(),
              let merged = ImageTransforms.flattened(current, overlay: overlayImage) else { return }
        pushHistory(current, label: label)
        image = merged
        hasUnsavedChanges = true
    }

    private func cgColorApp(_ color: Color) -> CGColor {
        NSColor(color).usingColorSpace(.deviceRGB)?.cgColor ?? CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    }

    private func drawPolyline(_ points: [CGPoint], in context: CGContext) {
        guard points.count >= 2 else { return }
        context.setStrokeColor(cgColorApp(strokeColor))
        context.setLineWidth(strokeWidth)
        context.addLines(between: points)
        context.strokePath()
    }

    private func stampLineAnnotation(from: CGPoint, to: CGPoint, arrow: Bool) {
        stampAnnotation(label: String(localized: "Arrow")) { context in
            context.setStrokeColor(cgColorApp(strokeColor))
            context.setLineWidth(strokeWidth)
            context.move(to: from)
            context.addLine(to: to)
            context.strokePath()
            if arrow {
                // 箭头头：两短线沿终点方向张开 25°。
                let angle = atan2(to.y - from.y, to.x - from.x)
                let head = max(10, strokeWidth * 4)
                for offset in [CGFloat.pi * 0.75, -CGFloat.pi * 0.75] {
                    context.move(to: to)
                    context.addLine(to: CGPoint(
                        x: to.x + head * cos(angle + offset),
                        y: to.y + head * sin(angle + offset)))
                    context.strokePath()
                }
            }
        }
    }

    private func stampRectAnnotation(from: CGPoint, to: CGPoint, ellipse: Bool) {
        stampAnnotation(label: String(localized: ellipse ? "Ellipse" : "Rectangle")) { context in
            context.setStrokeColor(cgColorApp(strokeColor))
            context.setLineWidth(strokeWidth)
            let rect = CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                              width: abs(to.x - from.x), height: abs(to.y - from.y))
            if ellipse {
                context.strokeEllipse(in: rect)
            } else {
                context.stroke(rect)
            }
        }
    }

    /// 多边形闭合（v0.8.15）：≥3 点，首尾连线。
    private func stampPolygon(_ points: [CGPoint]) {
        stampAnnotation(label: String(localized: "Polygon")) { context in
            context.setStrokeColor(cgColorApp(strokeColor))
            context.setLineWidth(strokeWidth)
            context.addLines(between: points + [points[0]])
            context.strokePath()
        }
    }

    /// 序号气泡（v0.8.15）：实心圆 + 白色序号，半径随序号位数微扩。
    private func stampBubble(at point: CGPoint, number: Int) {
        stampAnnotation(label: String(localized: "Bubble")) { context in
            let digits = String(number).count
            let radius = 9.0 * displayScale + CGFloat(digits - 1) * 5.0 * displayScale
            let rect = CGRect(x: point.x - radius, y: point.y - radius,
                              width: radius * 2, height: radius * 2)
            context.setFillColor(cgColorApp(strokeColor))
            context.fillEllipse(in: rect)
            let text = String(number) as NSString
            let fontSize = radius * 1.05
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                      withAttributes: attributes)
        }
    }

    /// 马赛克：把选区矩形内的原图下采样（8px 块）再贴回——真模糊由
    /// CIPixellate 近似（块内均值）。区域小，直接从原图重取即可。
    private func stampMosaic(from: CGPoint, to: CGPoint) {
        guard let current = image else { return }
        let rect = CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                          width: max(8, abs(to.x - from.x)), height: max(8, abs(to.y - from.y)))
        let pixel = CGRect(x: rect.minX * displayScale, y: rect.minY * displayScale,
                           width: rect.width * displayScale, height: rect.height * displayScale)
        guard let region = ImageTransforms.cropped(current, rect: pixel),
              // 8px 块下采样再放大回原尺寸 = 像素化。
              let tiny = ImageTransforms.resized(region, width: max(1, Int(pixel.width / 12)),
                                                 height: max(1, Int(pixel.height / 12))),
              let pixelated = ImageTransforms.resized(tiny, width: Int(pixel.width),
                                                      height: Int(pixel.height)) else { return }
        stampAnnotation(label: String(localized: "Mosaic")) { context in
            // 视图坐标上下文里 y 已翻转；像素块贴回时同样按视图矩形。
            context.draw(pixelated, in: rect)
        }
        _ = pixelated
    }

    /// OCR 结果浮层（22）：识别文本可复制。
    @ViewBuilder
    private var ocrPanel: some View {
        if let text = ocrResult {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Extracted Text")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button(String(localized: "Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    Button { ocrResult = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                }
                ScrollView {
                    Text(text)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            .padding(12)
            .frame(width: 320)
            .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
            .shadow(radius: 4)
        }
    }

    /// 操作历史面板（v0.8.13）：列出每步操作，点击跳回该步（其后步骤丢弃）。
    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History")
                .font(.system(size: 11, weight: .semibold))
            ScrollView {
                VStack(spacing: 2) {
                    // 栈顶在前 = 最新操作在上；index = 撤销深度。
                    let steps = historySteps.enumerated().reversed().map { ($0.offset, $0.element) }
                    ForEach(steps, id: \.0) { pair in
                        let depth = pair.0
                        let label = pair.1
                        Button {
                            jumpToHistoryStep(depth)
                        } label: {
                            HStack(spacing: 6) {
                                Text("\(depth + 1)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(label)
                                    .font(.system(size: 10.5))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(depth == historySteps.count - 1 ? appAccent.opacity(0.14) : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                    // 栈底 = 原图
                    Button {
                        jumpToHistoryStep(0)
                    } label: {
                        HStack(spacing: 6) {
                            Text("0")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(String(localized: "Original"))
                                .font(.system(size: 10.5))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
            }
            .frame(maxHeight: 200)
        }
        .padding(12)
        .frame(width: 200)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .shadow(radius: 4)
    }

    /// 打印（v0.8.14 基础件 3）：当前位图适配上纸（横竖向随图）。
    private func printImage() {
        guard let image, let nsImage = makeNSImage(image) else { return }
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        let isLandscape = image.width > image.height
        printInfo.isVerticallyCentered = true
        printInfo.isHorizontallyCentered = true
        printInfo.orientation = isLandscape ? .landscape : .portrait
        let printView = NSImageView(frame: NSRect(
            origin: .zero,
            size: nsImage.size))
        printView.image = nsImage
        printView.imageScaling = .scaleProportionallyUpOrDown
        let op = NSPrintOperation(view: printView, printInfo: printInfo)
        op.showsPrintPanel = true
        op.run()
    }

    /// 调色滑杆浮层（21；v0.8.27 媒体批补曝光/色温）：Apply 烙进位图（可撤销）。
    private var adjustmentsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Adjustments")
                .font(.system(size: 11, weight: .semibold))
            sliderRow(String(localized: "Brightness"), value: $brightness, range: -0.3...0.3)
            sliderRow(String(localized: "Contrast"), value: $contrast, range: 0.5...1.8)
            sliderRow(String(localized: "Saturation"), value: $saturation, range: 0...2)
            sliderRow(String(localized: "Sharpen"), value: $sharpen, range: 0...2)
            sliderRow(String(localized: "Exposure"), value: $exposure, range: -2...2)
            sliderRow(String(localized: "Color Temperature"), value: $temperature, range: -100...100)
            HStack {
                Button(String(localized: "Apply")) {
                    apply(label: String(localized: "Adjustments"), transform: {
                        ImageTransforms.adjusted($0, brightness: brightness, contrast: contrast,
                                                 saturation: saturation, sharpen: sharpen,
                                                 exposure: exposure, temperature: temperature)
                    })
                    showAdjustments = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(String(localized: "Reset")) {
                    brightness = 0; contrast = 1; saturation = 1; sharpen = 0
                    exposure = 0; temperature = 0
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 230)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .shadow(radius: 4)
    }

    /// 滤镜预设浮层（v0.8.27 媒体批）：点选即烙印（历史栈可撤销）。
    private var filtersPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Filters")
                .font(.system(size: 11, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) {
                ForEach(ImageFilterPreset.allCases.filter { $0 != .none }) { preset in
                    Button {
                        apply(label: preset.localizedTitle) {
                            ImageTransforms.photoFiltered($0, preset: preset)
                        }
                    } label: {
                        Text(preset.localizedTitle)
                            .font(.system(size: 10.5))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
            }
            .frame(width: 206)
            Text("Click a filter to bake it in — undo (⌘Z) reverts.")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .shadow(radius: 4)
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10.5))
                .frame(width: 66, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    /// OCR（22）：Vision 识别 → 结果浮层（可复制），复用 ocrImage 管线。
    private func runOCR() {
        guard let image, !ocrRunning else { return }
        ocrRunning = true
        ocrResult = nil
        Task { @MainActor in
            defer { ocrRunning = false }
            do {
                let result = try await VisionOCRService.recognize(cgImage: image)
                ocrResult = result.text.isEmpty
                    ? String(localized: "No text found in this image.")
                    : result.text
            } catch {
                ocrResult = error.localizedDescription
            }
        }
    }

    /// 导出为新文件（NSSavePanel；格式按所选扩展名）。
    private func exportAs(type: String) {
        guard let image else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (fileName as NSString).deletingPathExtension + ".\(type)"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try ImageTransforms.save(image, to: dest)
            flash(String(localized: "Exported → \(dest.lastPathComponent)"))
        } catch {
            flash(String(localized: "Export failed: \(error.localizedDescription)"))
        }
    }

    private var cropOverlay: some View {
        Group {
            if cropMode {
                Text(String(localized: "Drag to select the crop area"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.regularMaterial))
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 状态条 / 尺寸调整

    private var statusBar: some View {
        HStack(spacing: 8) {
            if cropMode {
                HStack(spacing: 6) {
                    Text("Aspect")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    ForEach([("Free", CGFloat(0)), ("1:1", 1), ("4:3", 4.0 / 3.0), ("16:9", 16.0 / 9.0)], id: \.0) { label, ratio in
                        Button(label) {
                            cropAspect = ratio
                        }
                        .font(.system(size: 10))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    Button(String(localized: "Apply Crop")) {
                        if let rect = cropRect {
                            let pixel = CGRect(x: rect.minX * displayScale, y: rect.minY * displayScale,
                                               width: rect.width * displayScale, height: rect.height * displayScale)
                            apply(label: String(localized: "Crop"), transform: { ImageTransforms.cropped($0, rect: pixel) })
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            }
            Spacer()
            if let statusNote {
                Text(statusNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(appAccent)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .overlay(alignment: .top) { Divider() }
    }

    /// 尺寸调整（v0.8.26 办公增强：此处此前是 EmptyView，按钮点了没反应）：
    /// 输入目标宽度、按原比例算高度，走历史栈可撤销。
    private var resizeSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Resize Image"))
                .font(.system(size: 14, weight: .semibold))
            if let image {
                Text(String(localized: "Current: \(image.width) × \(image.height) px"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(String(localized: "Width (px)"))
                        .font(.system(size: 12))
                    TextField("", text: $resizeWidth)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onSubmit { applyResize() }
                }
                if let height = computedResizeHeight {
                    Text(String(localized: "Height: \(height) px (aspect ratio kept)"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { showResize = false }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Apply")) { applyResize() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(computedResizeHeight == nil)
            }
        }
        .padding(18)
        .frame(width: 320)
        .onAppear {
            if resizeWidth.isEmpty, let image { resizeWidth = "\(image.width)" }
        }
    }

    private var computedResizeHeight: Int? {
        guard let image, image.width > 0,
              let width = Int(resizeWidth.trimmingCharacters(in: .whitespaces)), width > 0 else {
            return nil
        }
        return max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
    }

    private func applyResize() {
        guard let height = computedResizeHeight,
              let width = Int(resizeWidth.trimmingCharacters(in: .whitespaces)) else { return }
        apply(label: String(localized: "Resize \(width)×\(height)")) {
            ImageTransforms.resized($0, width: width, height: height)
        }
        showResize = false
    }
}
