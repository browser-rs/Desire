import SwiftUI

/// 图层面板 2.0（迭代 4）：缩略图、拖拽排序、向下合并、拼合、锁定、重命名。
struct ImageEditorLayersPanel: View {
    @ObservedObject private var session: ImageEditorSession
    @ObservedObject private var document: ImageEditorDocument
    @Environment(\.appAccent) private var appAccent

    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var showStyle = false
    @State private var renamingGroupID: UUID?

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
                iconButton("folder.badge.plus", help: String(localized: "Group from active layer")) {
                    document.createGroup(name: "Group")
                }
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
                // 图层组头（v0.8.54 批 3）：按组 id 聚合，每组一个头行（折叠/可见/重命名）。
                ForEach(document.groups.values.sorted { $0.id.uuidString < $1.id.uuidString }) { group in
                    groupRow(group)
                        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(Array(document.layers.reversed())) { layer in
                    // 折叠组内的成员层不显示（组头代表整组）。
                    if let gid = layer.groupID,
                       document.groups[gid]?.isCollapsed == true {
                        EmptyView()
                    } else {
                        row(layer)
                            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
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
                            set: { document.setLayerOpacity(active.id, opacity: Double($0),
                                                            record: false) }
                        ), in: 0...1, onEditingChanged: { editing in
                            // 拖动开始 = 一步历史（此前 opacity 完全不可撤销）；
                            // 拖动中的连续帧只改值，不灌历史。
                            if editing { document.beginContinuousEdit("Opacity Layer") }
                        })
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
                            document.setLayerStyle(layer.id, style: s, record: false) }),
                       in: 0...40, onEditingChanged: { if $0 { document.beginContinuousEdit("Layer Style") } })
                        .controlSize(.mini)
                    Slider(value: Binding(
                        get: { CGFloat(style.shadowOffsetY) },
                        set: { var s = style; s.shadowOffsetY = Double($0)
                            document.setLayerStyle(layer.id, style: s, record: false) }),
                       in: 0...30, onEditingChanged: { if $0 { document.beginContinuousEdit("Layer Style") } })
                        .controlSize(.mini)
                }
                HStack(spacing: 6) {
                    Text(String(localized: "Stroke")).font(.system(size: 10))
                        .foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    Slider(value: Binding(
                        get: { CGFloat(style.strokeWidth) },
                        set: { var s = style; s.strokeWidth = Double($0)
                            document.setLayerStyle(layer.id, style: s, record: false) }),
                       in: 0...20, onEditingChanged: { if $0 { document.beginContinuousEdit("Layer Style") } })
                        .controlSize(.mini)
                }
                HStack(spacing: 6) {
                    Text(String(localized: "Glow")).font(.system(size: 10))
                        .foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                    Slider(value: Binding(
                        get: { CGFloat(style.glowRadius) },
                        set: { var s = style; s.glowRadius = Double($0)
                            document.setLayerStyle(layer.id, style: s, record: false) }),
                       in: 0...40, onEditingChanged: { if $0 { document.beginContinuousEdit("Layer Style") } })
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

    private var horizontalFlipTitle: String { String(localized: "Flip Layer Horizontal") }
    private var verticalFlipTitle: String { String(localized: "Flip Layer Vertical") }

    @ViewBuilder
    private func groupRow(_ group: ImageEditorDocument.LayerGroup) -> some View {
        HStack(spacing: 6) {
            Button {
                document.toggleGroupCollapsed(group.id)
            } label: {
                Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            Button {
                document.setGroupVisible(group.id, visible: !group.isVisible)
            } label: {
                Image(systemName: group.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(group.isVisible ? AnyShapeStyle(.secondary)
                                                     : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            Text(group.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 2)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
        .contextMenu {
            Button(String(localized: "Ungroup")) { document.dissolveGroup(group.id) }
            Button(String(localized: "Rename Group")) {
                renamingGroupID = group.id
                renameText = group.name
            }
            Divider()
            Button(String(localized: "Delete Group"), role: .destructive) {
                document.dissolveGroup(group.id)
            }
        }
        if renamingGroupID == group.id {
            TextField("", text: $renameText) { _ in renamingGroupID = nil }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
        }
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
            if layer.hasMask {
                Image(systemName: "theatermasks")
                    .font(.system(size: 8))
                    .foregroundStyle(appAccent.opacity(0.7))
                    .help(String(localized: "Has mask"))
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
            Button(horizontalFlipTitle) {
                document.selectLayer(layer.id)
                document.flipActiveLayer(horizontal: true)
            }
            Button(verticalFlipTitle) {
                document.selectLayer(layer.id)
                document.flipActiveLayer(horizontal: false)
            }
            Divider()
            Menu(String(localized: "Move to Group")) {
                ForEach(document.groups.values.sorted { $0.name < $1.name }) { group in
                    Button(group.name) {
                        document.selectLayer(layer.id)
                        document.addToGroup(layer.id, groupID: group.id)
                    }
                }
                Divider()
                Button(String(localized: "Remove from Group")) {
                    document.selectLayer(layer.id)
                    document.removeFromGroup(layer.id)
                }
            }
            Divider()
            // 图层蒙版（v0.8.54 批 2）：添加/移除/反转。
            if layer.hasMask {
                Button(String(localized: "Invert Mask")) {
                    document.selectLayer(layer.id)
                    document.invertMask()
                }
                Button(String(localized: "Remove Mask")) {
                    document.selectLayer(layer.id)
                    document.removeMask()
                }
            } else {
                Button(String(localized: "Add Mask")) {
                    document.selectLayer(layer.id)
                    document.addMask()
                }
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
