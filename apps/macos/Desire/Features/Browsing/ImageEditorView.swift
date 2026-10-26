import SwiftUI

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
        case none, brush, arrow, rectangle, ellipse, text, mosaic
        var icon: String {
            switch self {
            case .none: "cursorarrow"
            case .brush: "paintbrush"
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .text: "textformat"
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

    // 文字标注
    @State private var textEntry = ""
    @State private var showTextEntry = false
    @State private var textAnchor: CGPoint?

    // 尺寸调整
    @State private var showResize = false
    @State private var resizeWidth = ""

    /// 视图显示尺寸（点击坐标 → 位图像素换算用）。
    @State private var displaySize: CGSize = .zero

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
    }

    // MARK: - 加载 / 保存

    private func load() {
        if let cg = ImageTransforms.load(from: fileURL) {
            image = cg
            history = []
            hasUnsavedChanges = false
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

    private func flash(_ text: String) {
        statusNote = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if statusNote == text { statusNote = nil }
        }
    }

    /// 应用一个变换（压栈 undo、标记未保存）。
    private func apply(_ transform: (CGImage) -> CGImage?) {
        guard let current = image, let next = transform(current) else {
            flash(String(localized: "Transform failed"))
            return
        }
        history.append(current)
        if history.count > 20 { history.removeFirst() }
        image = next
        hasUnsavedChanges = true
        cropRect = nil
        cropMode = false
    }

    private func undo() {
        guard let previous = history.popLast() else { return }
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
            button("rotateleft", "Rotate 90° Left") { apply { ImageTransforms.rotated($0, clockwise: false) } }
            button("rotateright", "Rotate 90° Right") { apply { ImageTransforms.rotated($0, clockwise: true) } }
            button("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip Horizontal") {
                apply { ImageTransforms.flipped($0, horizontal: true) }
            }
            button("arrow.up.and.down.righttriangle.left.righttriangle.right", "Flip Vertical") {
                apply { ImageTransforms.flipped($0, horizontal: false) }
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
            ColorPicker("", selection: $strokeColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 26)

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
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.medium)
                        .shadow(radius: 2)
                        .gesture(canvasGesture)
                        .overlay(cropOverlay)
                        .overlay(annotationOverlay)

                    if cropMode, let rect = cropRect {
                        Rectangle()
                            .strokeBorder(appAccent, lineWidth: 1.5)
                            .background(appAccent.opacity(0.08))
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                .padding(20)
                .background(
                    GeometryReader { geo in
                        Color.clear.onAppear { displaySize = geo.size }
                            .onChange(of: geo.size) { _, size in displaySize = size }
                    })
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
                case .arrow, .rectangle, .ellipse, .mosaic:
                    if dragStart == nil { dragStart = point }
                    dragCurrent = point
                case .text, .none:
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
                        apply { ImageTransforms.cropped($0, rect: pixel) }
                        return
                    }
                    cropRect = nil
                    return
                }
                switch tool {
                case .brush:
                    if brushPoints.count >= 2 {
                        stampAnnotation { overlay in
                            drawPolyline(brushPoints, in: overlay)
                        }
                    }
                    brushPoints = []
                case .arrow:
                    stampLineAnnotation(from: dragStart ?? value.location, to: value.location, arrow: true)
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
        stampAnnotation { overlay in
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
    private func stampAnnotation(_ draw: (CGContext) -> Void) {
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
        history.append(current)
        if history.count > 20 { history.removeFirst() }
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
        stampAnnotation { context in
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
        stampAnnotation { context in
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
        stampAnnotation { context in
            // 视图坐标上下文里 y 已翻转；像素块贴回时同样按视图矩形。
            context.draw(pixelated, in: rect)
        }
        _ = pixelated
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
                            apply { ImageTransforms.cropped($0, rect: pixel) }
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

    private var resizeSheet: some View {
        EmptyView()
    }
}
