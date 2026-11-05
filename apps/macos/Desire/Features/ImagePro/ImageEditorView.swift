import AppKit
import SwiftUI

/// ImagePro 编辑器主界面（v0.8.46 重写）：顶栏 / 工具选项 / 工具轨 / 画布 /
/// 检查器（图层·历史·调整）/ 状态栏。所有编辑动作走 ImageEditorDocument。
struct ImageEditorView: View {
    let fileURL: URL
    let fileName: String
    var onBack: () -> Void

    @StateObject private var session: ImageEditorSession
    @State private var inspector: Inspector?
    @State private var exportFormat = "png"
    @State private var showAI = false
    @State private var aiPrompt = ""
    @Environment(\.appAccent) private var appAccent

    enum Inspector: String, CaseIterable {
        case layers, history, adjustments
        var symbol: String {
            switch self {
            case .layers: return "square.3.layers.3d"
            case .history: return "clock.arrow.circlepath"
            case .adjustments: return "slider.horizontal.3"
            }
        }
        var title: String {
            switch self {
            case .layers: return String(localized: "Layers")
            case .history: return String(localized: "History")
            case .adjustments: return String(localized: "Adjustments")
            }
        }
    }

    init(fileURL: URL, fileName: String, onBack: @escaping () -> Void) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.onBack = onBack
        _session = StateObject(wrappedValue: ImageEditorSession(fileURL: fileURL,
                                                                name: fileName))
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
            HStack(spacing: 6) {
                ForEach(["Crop to 1:1", "Brighten", "Black & White", "Add text"], id: \.self) { item in
                    Button(item) {
                        aiPrompt = item
                        sendAIPrompt()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                Spacer()
                Button(String(localized: "Send")) { sendAIPrompt() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(aiPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
    }

    private func sendAIPrompt() {
        let prompt = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard let target = AgentScheduler.shared.deliveryTarget else {
            session.flash(String(localized: "Open the Agent panel first"))
            return
        }
        let context = """
        当前打开的图片编辑器：\(session.fileURL.path)（\(Int(session.canvasSize.width))×\(Int(session.canvasSize.height)) 像素）。        请按我的要求编辑：\(prompt)。使用 editImage 工具执行，坐标一律用图片像素，完成后简要说明改了什么。
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
                case .text:
                    optionSlider(String(localized: "Font Size"), value: $session.fontSize,
                                 range: 8...160, width: 120)
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
                case .move:
                    Text(String(localized: "Drag to move the active layer"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
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
        session.export(format: format, to: url)
    }
}
