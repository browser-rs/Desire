import SwiftUI

/// 图层面板（迭代 2 · v0.8.42）：列表 + 可见性/不透明度/混合模式/移动/删除。
struct ImageLayersPanel: View {
    @ObservedObject private var store = ImageLayerStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent: Color
    @State private var expandedBlendFor: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "Layers"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    _ = store.addLayer()
                } label: {
                    Label(String(localized: "New Layer"), systemImage: "plus")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!store.canAdd)
                Button(String(localized: "Close")) { dismiss() }
                    .buttonStyle(.borderless)
            }
            Text(String(localized: "Bottom → top render order. Flatten happens on save/export; layers stay editable."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(store.stack.enumerated().reversed()), id: \.element.id) { index, layer in
                        row(index: index, layer: layer)
                        if index < store.stack.count - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 340, height: 460)
    }

    private func row(index: Int, layer: ImageLayer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    store.setVisible(layer.id, !layer.isVisible)
                } label: {
                    Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(layer.isVisible ? AnyShapeStyle(appAccent)
                                                         : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 1) {
                    Text(layer.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Text("\(Int(layer.opacity * 100))% · \(layer.blendMode.displayName)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if index > 0 {
                    Button {
                        store.move(layer.id, up: true)
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9))
                    .disabled(index == 1 && !store.stack.indices.contains(2))
                    Button {
                        store.move(layer.id, up: false)
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 9))
                    .disabled(index == store.stack.count - 1)
                    if index != 0 {
                        Button {
                            store.remove(layer.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 9))
                    }
                } else {
                    Text(String(localized: "Background"))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            if expandedBlendFor == layer.id, index > 0 {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { layer.opacity },
                        set: { store.setOpacity(layer.id, $0)
                        }), in: 0...1)
                        .controlSize(.small)
                    Menu {
                        ForEach(ImageLayerBlendMode.allCases, id: \.self) { mode in
                            Button(mode.displayName) {
                                store.setBlendMode(layer.id, mode)
                            }
                        }
                    } label: {
                        Text(layer.blendMode.displayName)
                            .font(.system(size: 9.5))
                    }
                    .frame(width: 90)
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                expandedBlendFor = expandedBlendFor == layer.id ? nil : layer.id
            }
        }
    }
}
