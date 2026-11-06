import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// ImagePro 编辑器主界面（v0.8.46 重写）：顶栏 / 工具选项 / 工具轨 / 画布 /
/// 检查器（图层·历史·调整）/ 状态栏。所有编辑动作走 ImageEditorDocument。
struct ImageEditorView: View {
    let fileURL: URL
    let fileName: String
    var onBack: () -> Void

    @StateObject private var session: ImageEditorSession
    @ObservedObject private var document: ImageEditorDocument
    @State private var inspector: Inspector?
    @State private var exportFormat = "png"
    @State private var showAI = false
    @State private var showTextStyle = false
    @State private var showCanvasSize = false
    @State private var showImageSize = false
    @State private var sizeWidth = ""
    @State private var sizeHeight = ""
    @State private var pendingTemplate: ImageEditorTemplate?
    @State private var showDiscardAlert = false
    @State private var aiPrompt = ""
    @Environment(\.appAccent) private var appAccent

    enum Inspector: String, CaseIterable {
        case layers, history, adjustments, histogram
        var symbol: String {
            switch self {
            case .layers: return "square.3.layers.3d"
            case .history: return "clock.arrow.circlepath"
            case .adjustments: return "slider.horizontal.3"
            case .histogram: return "chart.bar"
            }
        }
        var title: String {
            switch self {
            case .layers: return String(localized: "Layers")
            case .history: return String(localized: "History")
            case .adjustments: return String(localized: "Adjustments")
            case .histogram: return String(localized: "Histogram")
            }
        }
    }

    init(fileURL: URL, fileName: String, onBack: @escaping () -> Void) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.onBack = onBack
        let created = ImageEditorSession(fileURL: fileURL, name: fileName)
        _session = StateObject(wrappedValue: created)
        _document = ObservedObject(wrappedValue: created.document)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            toolOptionsBar
            Divider()
            HStack(spacing: 0) {
                toolRail
                Divider()
                ImageCanvasView(session: session)
                if let inspector {
                    Divider()
                    inspectorView(inspector)
                        .frame(width: 272)
                }
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showCanvasSize) {
            sizeSheet(title: String(localized: "Canvas Size")) {
                session.document.resizeCanvas(to: CGSize(width: CGFloat(Int(sizeWidth) ?? 0),
                                                          height: CGFloat(Int(sizeHeight) ?? 0)))
            }
        }
        .sheet(isPresented: $showImageSize) {
            sizeSheet(title: String(localized: "Image Size (px)")) {
                session.document.resize(to: CGSize(width: CGFloat(Int(sizeWidth) ?? 0),
                                                    height: CGFloat(Int(sizeHeight) ?? 0)))
            }
        }
        .alert(String(localized: "Discard unsaved changes?"), isPresented: $showDiscardAlert) {
            Button(String(localized: "Cancel"), role: .cancel) { pendingTemplate = nil }
            Button(String(localized: "Discard"), role: .destructive) {
                if let template = pendingTemplate { newDocument(template) }
                pendingTemplate = nil
            }
        }
        .onAppear { session.activate() }
        .onDisappear { session.removeKeyMonitor() }
        .onAppear {
            if inspector == nil { inspector = .layers }
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                onBack()
            } label: {
                Label(String(localized: "Back to Page"), systemImage: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)

            Text(session.displayName)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            if session.document.isDirty {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                    .help(String(localized: "Unsaved changes"))
            }

            Text(verbatim: "\(Int(session.canvasSize.width)) × \(Int(session.canvasSize.height))")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)

            Spacer(minLength: 8)

            // 撤销 / 重做
            iconButton("arrow.uturn.backward", help: String(localized: "Undo (⌘Z)")) {
                session.document.undo()
            }
            .disabled(session.document.historyTitles.isEmpty)
            .keyboardShortcut("z", modifiers: .command)

            iconButton("arrow.uturn.forward", help: String(localized: "Redo (⌘⇧Z)")) {
                session.document.redo()
            }
            .disabled(session.document.redoCount == 0)
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Divider().frame(height: 16)

            // 缩放
            zoomGroup

            Divider().frame(height: 16)

            iconButton("square.3.layers.3d", help: String(localized: "Layers")) {
                toggleInspector(.layers)
            }
            .foregroundStyle(inspector == .layers ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
            iconButton("clock.arrow.circlepath", help: String(localized: "History")) {
                toggleInspector(.history)
            }
            .foregroundStyle(inspector == .history ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
            iconButton("slider.horizontal.3", help: String(localized: "Adjustments")) {
                toggleInspector(.adjustments)
            }
            .foregroundStyle(inspector == .adjustments ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
            iconButton("chart.bar", help: String(localized: "Histogram")) {
                toggleInspector(.histogram)
            }
            .foregroundStyle(inspector == .histogram ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))

            Divider().frame(height: 16)

            Button {
                showAI.toggle()
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
            .help(String(localized: "Ask AI"))
            .popover(isPresented: $showAI, arrowEdge: .bottom) {
                aiPopover
            }

            Menu {
                Section(String(localized: "New Document")) {
                    ForEach(ImageEditorTemplate.all) { template in
                        Button(template.name) {
                            if session.document.isDirty {
                                pendingTemplate = template
                                showDiscardAlert = true
                            } else {
                                newDocument(template)
                            }
                        }
                    }
                }
                Section(String(localized: "Canvas Size")) {
                    ForEach(ImageEditorTemplate.all) { template in
                        Button(template.name) {
                            session.document.resizeCanvas(to: template.size)
                        }
                    }
                    Button(String(localized: "Custom Canvas Size…")) {
                        sizeWidth = "\(Int(session.canvasSize.width))"
                        sizeHeight = "\(Int(session.canvasSize.height))"
                        showCanvasSize = true
                    }
                }
                Button(String(localized: "Place Image…")) { placeImageFromPanel() }
                Button(String(localized: "Frame from Video…")) { frameFromVideo() }
                Button(String(localized: "Remove Background")) {
                    Task { @MainActor in
                        let result = await ImageEditorCommands.apply(
                            ["action": "cutout", "mode": "erase"],
                            session: session)
                        if let error = result["error"] as? String {
                            session.flash(error)
                        } else {
                            session.flash(String(localized: "Background removed"))
                        }
                    }
                }
                Toggle(String(localized: "Show Grid"), isOn: $session.showGrid)
                Toggle(String(localized: "Center Guides"), isOn: $session.showCenterGuides)
                Toggle(String(localized: "Snapping"), isOn: $session.snapping)
                Button(String(localized: "Image Size…")) {
                    sizeWidth = "\(Int(session.canvasSize.width))"
                    sizeHeight = "\(Int(session.canvasSize.height))"
                    showImageSize = true
                }
            } label: {
                Image(systemName: "aspectratio")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help(String(localized: "Canvas"))

            iconButton("square.and.arrow.down", help: String(localized: "Save (⌘S)")) {
                session.saveInPlace()
            }
            .keyboardShortcut("s", modifiers: .command)

            Menu {
                Button(String(localized: "Export as PNG…")) { export(as: "png") }
                Button(String(localized: "Export as JPEG…")) { export(as: "jpg") }
                Button(String(localized: "Export as TIFF…")) { export(as: "tiff") }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help(String(localized: "Export"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var zoomGroup: some View {
        HStack(spacing: 4) {
            iconButton("minus.magnifyingglass", help: String(localized: "Zoom Out (⌘-)")) {
                session.canvas.zoomFromCenter(by: 1 / 1.25)
            }
            .keyboardShortcut("-", modifiers: .command)
            Button {
                session.canvas.zoom(to: 1,
                                    anchor: CGPoint(x: session.canvas.containerSize.width / 2,
                                                    y: session.canvas.containerSize.height / 2))
            } label: {
                Text(verbatim: "\(Int((session.canvas.zoom * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .frame(minWidth: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(String(localized: "Actual Pixels (⌘1)"))
            .keyboardShortcut("1", modifiers: .command)
            iconButton("plus.magnifyingglass", help: String(localized: "Zoom In (⌘=)")) {
                session.canvas.zoomFromCenter(by: 1.25)
            }
            .keyboardShortcut("=", modifiers: .command)
            iconButton("arrow.down.right.and.arrow.up.left",
                       help: String(localized: "Fit (⌘0)")) {
                session.canvas.fit()
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }

    /// AI 入口：把自然语言交给当前 Agent 会话，由它调用 editImage 命令。
    private var aiPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Ask AI to edit this image"))
                .font(.system(size: 11, weight: .semibold))
            TextField(String(localized: "e.g. remove the background, brighten, crop to 1:1"),
                      text: $aiPrompt)
                .textFieldStyle(.roundedBorder)
                .frame(width: 330)
                .onSubmit(sendAIPrompt)
            // 引导工作流（迭代 18b）：一键把预设诉求交给 Agent。两行排布
            // 避免 330pt 弹窗里横向溢出。
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    ForEach(["Crop to 1:1", "Brighten", "Black & White"], id: \.self) { item in
                        chip(item)
                    }
                    Spacer()
                    Button(String(localized: "Send")) { sendAIPrompt() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(aiPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack(spacing: 6) {
                    ForEach(["Add text", "Remove background", "Make a YouTube cover"], id: \.self) { item in
                        chip(item)
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
    }

    private func chip(_ item: String) -> some View {
        Button(item) {
            aiPrompt = item
            sendAIPrompt()
        }
        .font(.system(size: 10))
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    private func sendAIPrompt() {
        let prompt = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard let target = AgentScheduler.shared.deliveryTarget else {
            session.flash(String(localized: "Open the Agent panel first"))
            return
        }
        let context = """
        当前打开的图片编辑器：\(session.fileURL?.path ?? "未命名文档")（\(Int(session.canvasSize.width))×\(Int(session.canvasSize.height)) 像素）。        请按我的要求编辑：\(prompt)。使用 editImage 工具执行，坐标一律用图片像素，完成后简要说明改了什么。
        """
        target.sendMessage(context)
        aiPrompt = ""
        showAI = false
        session.flash(String(localized: "Sent to Agent"))
    }

    // MARK: - 工具轨

    private var toolRail: some View {
        VStack(spacing: 4) {
            ForEach(ImageEditorTool.allCases, id: \.rawValue) { tool in
                Button {
                    session.tool = tool
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(session.tool == tool
                                  ? AnyShapeStyle(appAccent.opacity(0.18))
                                  : AnyShapeStyle(Color.clear)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(session.tool == tool
                                 ? AnyShapeStyle(appAccent) : AnyShapeStyle(.primary))
                .help("\(tool.localizedTitle)\(tool.hotKey.map { " (\($0.uppercased()))" } ?? "")")
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(width: 44)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    // MARK: - 工具选项

    private var toolOptionsBar: some View {
        HStack(spacing: 14) {
            Label(session.tool.localizedTitle, systemImage: session.tool.symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            ColorPicker("", selection: $session.primaryColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 34, height: 20)
                .help(String(localized: "Foreground Color"))
            Divider().frame(height: 14)
            Group {
                switch session.tool {
                case .brush, .eraser:
                    optionSlider(String(localized: "Size"), value: $session.brushSize,
                                 range: 1...300, width: 110)
                    optionSlider(String(localized: "Opacity"),
                                 value: Binding(get: { CGFloat(session.brushOpacity) },
                                                set: { session.brushOpacity = Double($0) }),
                                 range: 0.02...1, width: 90)
                    optionSlider(String(localized: "Hardness"),
                                 value: Binding(get: { CGFloat(session.brushHardness) },
                                                set: { session.brushHardness = Double($0) }),
                                 range: 0...1, width: 90)
                case .marquee:
                    Toggle(String(localized: "Ellipse"), isOn: $session.marqueeEllipse)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                    optionSlider(String(localized: "Feather"),
                                 value: Binding(get: { CGFloat(session.selectionFeather) },
                                                set: { session.selectionFeather = Double($0) }),
                                 range: 0...0.3, width: 90)
                case .wand:
                    optionSlider(String(localized: "Tolerance"),
                                 value: Binding(get: { CGFloat(session.wandTolerance) },
                                                set: { session.wandTolerance = Double($0) }),
                                 range: 1...120, width: 110)
                    optionSlider(String(localized: "Feather"),
                                 value: Binding(get: { CGFloat(session.selectionFeather) },
                                                set: { session.selectionFeather = Double($0) }),
                                 range: 0...0.3, width: 90)
                case .retouch:
                    Picker("", selection: $session.retouchMode) {
                        ForEach(ImageRetouchMode.allCases, id: \.rawValue) { mode in
                            Text(mode.localizedTitle).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 130)
                    optionSlider(String(localized: "Size"), value: $session.brushSize,
                                 range: 2...300, width: 100)
                    optionSlider(String(localized: "Strength"),
                                 value: Binding(get: { CGFloat(session.retouchStrength) },
                                                set: { session.retouchStrength = Double($0) }),
                                 range: 0.05...1, width: 90)
                    if [.clone, .heal].contains(session.retouchMode) {
                        Text(String(localized: "⌥ click to sample"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                case .gradient:
                    Toggle(String(localized: "Radial"), isOn: $session.gradientRadial)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                    ColorPicker("", selection: $session.secondaryColor, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 30)
                        .help(String(localized: "End Color"))
                    Text(String(localized: "Drag across the canvas"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                case .shape:
                    Picker("", selection: $session.shape) {
                        ForEach(ImageEditorShape.allCases, id: \.rawValue) { shape in
                            Text(shape.localizedTitle).tag(shape)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    optionSlider(String(localized: "Width"), value: $session.lineWidth,
                                 range: 1...40, width: 90)
                    Toggle(String(localized: "Fill"), isOn: $session.fillShapes)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                    Toggle(String(localized: "Dashed"), isOn: $session.dashedStroke)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                    if session.shape == .rectangle {
                        optionSlider(String(localized: "Corner Radius"),
                                     value: $session.cornerRadius, range: 0...80, width: 80)
                    }
                case .text:
                    textOptions
                case .crop:
                    Text(String(localized: "Aspect"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    ForEach([("Free", CGFloat(0)), ("1:1", 1), ("4:3", 4.0 / 3.0),
                             ("16:9", 16.0 / 9.0)], id: \.0) { label, ratio in
                        Button(label) { session.cropAspect = ratio }
                            .font(.system(size: 10))
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .tint(session.cropAspect == ratio ? AnyShapeStyle(appAccent) : nil)
                    }
                    Text(String(localized: "Drag a box, then Apply (⏎)"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "⇧ add · ⌥ subtract · ⇧⌥ intersect"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                case .move:
                    moveOptions
                case .hand:
                    Text(String(localized: "Drag to pan · ⌘scroll to zoom"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                case .zoom:
                    Text(String(localized: "Click to zoom in · ⌥click to zoom out"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                case .eyedropper:
                    Text(String(localized: "Click to sample a color"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                case .lasso:
                    Text(String(localized: "Drag to draw a selection"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "⇧ add · ⌥ subtract · ⇧⌥ intersect"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if !session.document.selection.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 9))
                    Text(session.document.selection.describe)
                        .font(.system(size: 10, design: .monospaced))
                    Button(String(localized: "Deselect")) {
                        session.document.clearSelection()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.borderless)
                    Button(String(localized: "Invert")) {
                        session.document.invertSelection()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.borderless)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    @ViewBuilder
    private var moveOptions: some View {
        if let layer = document.activeLayer {
            HStack(spacing: 6) {
                Text(String(localized: "Scale"))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { CGFloat(layer.scale) },
                    set: { document.setLayerScale(layer.id, Double($0)) }
                ), in: 0.1...4)
                .controlSize(.mini)
                .frame(width: 100)
                Text(verbatim: String(format: "%.0f%%", layer.scale * 100))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 38, alignment: .trailing)
            }
            HStack(spacing: 6) {
                Text(String(localized: "Rotation"))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { CGFloat(layer.rotation) },
                    set: { document.setLayerRotation(layer.id, Double($0)) }
                ), in: -180...180)
                .controlSize(.mini)
                .frame(width: 100)
                Text(verbatim: String(format: "%.0f°", layer.rotation))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 38, alignment: .trailing)
                Button(String(localized: "Reset")) {
                    document.resetLayerTransform(layer.id)
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)
            }
            Text(String(localized: "Drag to move · rotation/scale are non-destructive"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func frameFromVideo() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let result = ImageEditorVideo.extractFrame(from: url.path, time: 1.0)
        if let error = result.error {
            session.flash(error)
            return
        }
        guard let image = result.image else { return }
        document.placeImage(image, name: url.lastPathComponent)
        session.flash(String(localized: "Frame placed"))
    }

    private func placeImageFromPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let image = ImageTransforms.load(from: url) else { return }
        document.placeImage(image, name: url.lastPathComponent)
    }

    private var textOptions: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("", selection: Binding(
                    get: { session.textFontFamily ?? "System" },
                    set: { session.textFontFamily = $0 == "System" ? nil : $0 })) {
                    Text(String(localized: "System")).tag("System")
                    ForEach(["Helvetica Neue", "Avenir Next", "PingFang SC",
                             "Songti SC", "Kaiti SC", "Impact", "Georgia",
                             "Menlo", "Futura", "Optima"], id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
            } label: {
                Label(session.textFontFamily ?? String(localized: "System"),
                      systemImage: "character.textbox")
                    .font(.system(size: 10.5))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 120)

            Picker("", selection: $session.textWeight) {
                Text(String(localized: "Regular")).tag("regular")
                Text(String(localized: "Medium")).tag("medium")
                Text(String(localized: "Semibold")).tag("semibold")
                Text(String(localized: "Bold")).tag("bold")
                Text(String(localized: "Heavy")).tag("heavy")
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 96)

            optionSlider(String(localized: "Font Size"), value: $session.fontSize,
                         range: 8...240, width: 110)

            HStack(spacing: 2) {
                alignmentButton("text.alignleft", value: "left",
                                help: String(localized: "Align Left"))
                alignmentButton("text.aligncenter", value: "center",
                                help: String(localized: "Align Center"))
                alignmentButton("text.alignright", value: "right",
                                help: String(localized: "Align Right"))
            }

            Button {
                showTextStyle.toggle()
            } label: {
                Label(String(localized: "Style"), systemImage: "paintbrush")
                    .font(.system(size: 10.5))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .popover(isPresented: $showTextStyle, arrowEdge: .bottom) {
                textStyleEditor
            }
        }
    }

    private var textStyleEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Text Style"))
                .font(.system(size: 11, weight: .semibold))
            HStack(spacing: 8) {
                Text(String(localized: "Line Spacing"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Slider(value: $session.textLineSpacing, in: 0.8...2.0)
                    .controlSize(.mini)
                Text(verbatim: String(format: "%.2f", session.textLineSpacing))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Text(String(localized: "Stroke"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Slider(value: $session.textStrokeWidth, in: 0...10)
                    .controlSize(.mini)
                ColorPicker("", selection: $session.textStrokeColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 30)
            }
            Toggle(String(localized: "Shadow"), isOn: $session.textShadow)
                .toggleStyle(.checkbox)
                .font(.system(size: 10.5))
            HStack(spacing: 8) {
                Toggle(String(localized: "Background"), isOn: $session.textBackground)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10.5))
                ColorPicker("", selection: $session.textBackgroundColor, supportsOpacity: true)
                    .labelsHidden()
                    .frame(width: 30)
                    .disabled(!session.textBackground)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func alignmentButton(_ symbol: String, value: String, help: String) -> some View {
        Button {
            session.textAlignment = value
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(session.textAlignment == value
                          ? AnyShapeStyle(appAccent.opacity(0.18))
                          : AnyShapeStyle(Color.clear)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(session.textAlignment == value
                         ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
        .help(help)
    }

    private func optionSlider(_ label: String, value: Binding<CGFloat>,
                              range: ClosedRange<CGFloat>, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Slider(value: value, in: range)
                .controlSize(.mini)
                .frame(width: width)
            Text(verbatim: range.upperBound > 5
                 ? String(format: "%.0f", value.wrappedValue)
                 : String(format: "%.2f", value.wrappedValue))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .leading)
        }
    }

    // MARK: - 检查器

    @ViewBuilder
    private func inspectorView(_ kind: Inspector) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(kind.title).font(.system(size: 11, weight: .semibold))
                Spacer()
                Button {
                    inspector = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            switch kind {
            case .layers:
                ImageEditorLayersPanel(session: session)
            case .history:
                ImageEditorHistoryPanel(session: session)
            case .adjustments:
                ImageEditorAdjustmentsPanel(session: session)
            case .histogram:
                ImageEditorHistogramPanel(session: session)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private func toggleInspector(_ kind: Inspector) {
        inspector = inspector == kind ? nil : kind
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(Int(session.canvasSize.width)) × \(Int(session.canvasSize.height)) px")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Divider().frame(height: 12)
            if let cursor = session.cursorBase {
                Text(verbatim: "\(Int(cursor.x)), \(Int(cursor.y))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if !session.document.selection.isEmpty {
                Text(session.document.selection.describe)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let note = session.statusNote {
                Text(note).font(.system(size: 10.5)).foregroundStyle(appAccent)
            }
            HStack(spacing: 3) {
                Text(verbatim: "\(session.document.layers.count)")
                Text(String(localized: "Layers"))
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func newDocument(_ template: ImageEditorTemplate) {
        session.newDocument(size: template.size, name: template.name)
    }

    private func sizeSheet(title: String, apply: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 12, weight: .semibold))
            HStack(spacing: 10) {
                Text(String(localized: "Width"))
                    .font(.system(size: 11))
                    .frame(width: 44, alignment: .leading)
                TextField("", text: $sizeWidth)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Text(String(localized: "Height"))
                    .font(.system(size: 11))
                    .frame(width: 44, alignment: .leading)
                TextField("", text: $sizeHeight)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Text(verbatim: "px").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) {
                    showCanvasSize = false
                    showImageSize = false
                }
                .buttonStyle(.bordered)
                Button(String(localized: "Apply")) {
                    apply()
                    showCanvasSize = false
                    showImageSize = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: - 辅助

    private func iconButton(_ symbol: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func export(as format: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent
            + "." + format
        panel.allowedContentTypes = []
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        _ = session.export(format: format, to: url)
    }
}
