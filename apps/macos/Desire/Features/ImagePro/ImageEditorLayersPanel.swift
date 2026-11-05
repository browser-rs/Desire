import SwiftUI

/// 图层面板（v0.8.46 重写）：可见性 / 选中 / 透明度 / 混合模式 / 增删序。
struct ImageEditorLayersPanel: View {
    @ObservedObject private var session: ImageEditorSession
    @ObservedObject private var document: ImageEditorDocument
    @Environment(\.appAccent) private var appAccent

    init(session: ImageEditorSession) {
        _session = ObservedObject(wrappedValue: session)
        _document = ObservedObject(wrappedValue: session.document)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
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
                Spacer()
                iconButton("chevron.up", help: String(localized: "Raise Layer")) {
                    document.moveActiveLayer(up: true)
                }
                iconButton("chevron.down", help: String(localized: "Lower Layer")) {
                    document.moveActiveLayer(up: false)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(document.layers.reversed()) { layer in
                        row(layer)
                    }
                }
                .padding(6)
            }

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
    }

    private func row(_ layer: ImageEditorLayer) -> some View {
        let isActive = layer.id == document.activeLayerID
        return HStack(spacing: 8) {
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

            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 28, height: 22)
                .overlay(Image(systemName: "photo")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary))

            Text(layer.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(isActive ? AnyShapeStyle(appAccent) : AnyShapeStyle(.primary))
            Spacer(minLength: 4)
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
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(isActive ? AnyShapeStyle(appAccent.opacity(0.12))
                           : AnyShapeStyle(Color.clear)))
        .contentShape(Rectangle())
        .onTapGesture { document.selectLayer(layer.id) }
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
