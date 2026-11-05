import SwiftUI

/// 图层面板 2.0（迭代 4）：缩略图、拖拽排序、向下合并、拼合、锁定、重命名。
struct ImageEditorLayersPanel: View {
    @ObservedObject private var session: ImageEditorSession
    @ObservedObject private var document: ImageEditorDocument
    @Environment(\.appAccent) private var appAccent

    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var showStyle = false

    init(session: ImageEditorSession) {
        _session = ObservedObject(wrappedValue: session)
        _document = ObservedObject(wrappedValue: session.document)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                iconButton("plus.square", help: String(localized: "New Layer")) {
                    document.addLayer()
                }
                iconButton("plus.square.on.square", help: String(localized: "Duplicate Layer")) {
                    document.duplicateActiveLayer()
                }
                iconButton("trash", help: String(localized: "Delete Layer")) {
                    document.deleteActiveLayer()
                }
                .disabled(document.layers.count <= 1)
                Spacer(minLength: 2)
                iconButton("arrow.triangle.merge", help: String(localized: "Merge Down")) {
                    document.mergeDown()
                }
                .disabled(!canMergeDown)
                iconButton("square.3.layers.3d.down.right",
                           help: String(localized: "Flatten")) {
                    document.flattenLayers()
                }
                .disabled(document.layers.count <= 1)
                Button {
                    showStyle.toggle()
                } label: {
                    Image(systemName: "fx")
                        .font(.system(size: 11))
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle((document.activeLayer?.style?.isActive ?? false)
                                 ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
                .help(String(localized: "Layer Style"))
                .popover(isPresented: $showStyle, arrowEdge: .bottom) {
                    styleEditor
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()

            List {
                ForEach(Array(document.layers.reversed())) { layer in
                    row(layer)
                        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove(perform: moveLayers)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 30)

            Divider()
            if let active = document.activeLayer {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text(String(localized: "Opacity"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { CGFloat(active.opacity) },
                            set: { document.setLayerOpacity(active.id, opacity: Double($0)) }
                        ), in: 0...1)
                        .controlSize(.mini)
                        Text(verbatim: "\(Int(active.opacity * 100))%")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, alignment: .trailing)
                    }
                    HStack(spacing: 8) {
                        Text(String(localized: "Blend"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { active.blend },
                            set: { document.setLayerBlend(active.id, blend: $0) }
                        )) {
                            ForEach(ImageEditorBlend.allCases, id: \.rawValue) { blend in
                                Text(blend.localizedTitle).tag(blend)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .sheet(item: Binding(
            get: { renamingID.flatMap { id in document.layers.first { $0.id == id } } },
            set: { if $0 == nil { renamingID = nil } }
        )) { layer in
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "Rename Layer"))
                    .font(.system(size: 12, weight: .semibold))
                TextField("", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit { commitRename(layer.id) }
                HStack {
                    Spacer()
                    Button(String(localized: "Cancel")) { renamingID = nil }
                        .buttonStyle(.bordered)
                    Button(String(localized: "Rename")) { commitRename(layer.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var styleEditor: some View {
        if let layer = document.activeLayer {
            let style = layer.style ?? ImageLayerStyle()
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Layer Style"))
                    .font(.system(size: 11, weight: .semibold))
                Toggle(String(localized: "Drop Shadow"), isOn: Binding(
                    get: { style.shadowEnabled },
                    set: { var s = style; s.shadowEnabled = $0
                        document.setLayerStyle(layer.id, style: s) }))
                    .toggleStyle(.checkbox)
                Toggle(String(localized: "Stroke"), isOn: Binding(
                    get: { style.strokeEnabled },
                    set: { var s = style; s.strokeEnabled = $0
                        document.setLayerStyle(layer.id, style: s) }))
                    .toggleStyle(.checkbox)
                Toggle(String(localized: "Glow"), isOn: Binding(
                    get: { style.glowEnabled },
                    set: { var s = style; s.glowEnabled = $0
                        document.setLayerStyle(layer.id, style: s) }))
                    .toggleStyle(.checkbox)
                HStack(spacing: 6) {
                    Text(String(localized: "Shadow")).font(.system(size: 10))
                        .foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    Slider(value: Binding(
                        get: { CGFloat(style.shadowRadius) },
                        set: { var s = style; s.shadowRadius = Double($0)
                            document.setLayerStyle(layer.id, style: s) }), in: 0...40)
                        .controlSize(.mini)
                    Slider(value: Binding(
                        get: { CGFloat(style.shadowOffsetY) },
                        set: { var s = style; s.shadowOffsetY = Double($0)
                            document.setLayerStyle(layer.id, style: s) }), in: 0...30)
                        .controlSize(.mini)
                }
                HStack(spacing: 6) {
                    Text(String(localized: "Stroke")).font(.system(size: 10))
                        .foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    Slider(value: Binding(
                        get: { CGFloat(style.strokeWidth) },
                        set: { var s = style; s.strokeWidth = Double($0)
                            document.setLayerStyle(layer.id, style: s) }), in: 0...20)
                        .controlSize(.mini)
                }
                HStack(spacing: 6) {
                    Text(String(localized: "Glow")).font(.system(size: 10))
                        .foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    Slider(value: Binding(
                        get: { CGFloat(style.glowRadius) },
                        set: { var s = style; s.glowRadius = Double($0)
                            document.setLayerStyle(layer.id, style: s) }), in: 0...40)
                        .controlSize(.mini)
                }
            }
            .padding(12)
            .frame(width: 240)
        }
    }

    private var canMergeDown: Bool {
        guard let index = document.layers.firstIndex(where: { $0.id == document.activeLayerID })
        else { return false }
        return index > 0
    }

    private func moveLayers(from source: IndexSet, to destination: Int) {
        var order = Array(document.layers.reversed())
        order.move(fromOffsets: source, toOffset: destination)
        document.reorderLayers(Array(order.reversed()))
    }

    private func commitRename(_ id: UUID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { document.renameLayer(id, name: trimmed) }
        renamingID = nil
    }

    private func row(_ layer: ImageEditorLayer) -> some View {
        let isActive = layer.id == document.activeLayerID
        return HStack(spacing: 7) {
            Button {
                document.setLayerVisible(layer.id, visible: !layer.isVisible)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(layer.isVisible ? AnyShapeStyle(.secondary)
                                                     : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Show / Hide"))

            thumbnail(for: layer)

            Text(layer.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(isActive ? AnyShapeStyle(appAccent) : AnyShapeStyle(.primary))
            Spacer(minLength: 2)
            if layer.isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            if layer.blend != .normal {
                Text(layer.blend.localizedTitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if layer.opacity < 0.999 {
                Text(verbatim: "\(Int(layer.opacity * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(isActive ? AnyShapeStyle(appAccent.opacity(0.12))
                           : AnyShapeStyle(Color.clear)))
        .contentShape(Rectangle())
        .onTapGesture { document.selectLayer(layer.id) }
        .contextMenu {
            Button(String(localized: "Rename")) {
                renameText = layer.name
                renamingID = layer.id
            }
            Button(layer.isLocked ? String(localized: "Unlock Layer")
                                  : String(localized: "Lock Layer")) {
                document.setLayerLocked(layer.id, locked: !layer.isLocked)
            }
            Button(String(localized: "Duplicate Layer")) {
                document.selectLayer(layer.id)
                document.duplicateActiveLayer()
            }
            Button(String(localized: "Merge Down")) {
                document.selectLayer(layer.id)
                document.mergeDown()
            }
            Divider()
            Button(String(localized: "Delete Layer")) {
                document.selectLayer(layer.id)
                document.deleteActiveLayer()
            }
            .disabled(document.layers.count <= 1)
        }
    }

    @ViewBuilder
    private func thumbnail(for layer: ImageEditorLayer) -> some View {
        if let cg = document.thumbnail(for: layer.id) {
            Image(decorative: cg, scale: 1)
                .resizable()
                .interpolation(.low)
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 24)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 34, height: 24)
        }
    }

    private func iconButton(_ symbol: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
