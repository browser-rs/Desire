//
//  ScreenshotOverlay.swift
//  Desire
//
//  Created by mankong on 2026/7/5.
//

import AppKit
import Combine
import SwiftUI

@MainActor
struct ScreenshotToolbar: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var model: ScreenshotToolbarModel

    let onToolChange: (ScreenshotTool) -> Void
    let onColorChange: (ScreenshotColor) -> Void
    let onStrokeWidthChange: (CGFloat) -> Void
    let onFontSizeChange: (CGFloat) -> Void
    let onFillToggle: () -> Void
    let onPickColor: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onRedraw: () -> Void
    let onSave: () -> Void
    let onCopy: () -> Void
    let onCancel: () -> Void

    private struct ToolItem: Hashable {
        let tool: ScreenshotTool
        let icon: String
        let help: LocalizedStringKey

        func hash(into hasher: inout Hasher) { hasher.combine(tool) }
        static func == (lhs: ToolItem, rhs: ToolItem) -> Bool { lhs.tool == rhs.tool }
    }

    private let tools: [ToolItem] = [
        .init(tool: .select,     icon: "cursorarrow",          help: "Select"),
        .init(tool: .rectangle,  icon: "rectangle",            help: "Rectangle"),
        .init(tool: .ellipse,    icon: "circle",               help: "Ellipse"),
        .init(tool: .arrow,      icon: "arrow.up.right",       help: "Arrow"),
        .init(tool: .brush,      icon: "pencil",               help: "Brush"),
        .init(tool: .mosaic,     icon: "square.grid.3x3",      help: "Mosaic"),
        .init(tool: .text,       icon: "textformat",           help: "Text"),
        .init(tool: .number,     icon: "number.circle",        help: "Number")
    ]

    /// Stroke width presets (points): thin / medium / thick.
    private let strokeOptions: [(width: CGFloat, iconSize: CGFloat, help: LocalizedStringKey)] = [
        (2, 6,  "Thin"),
        (4, 10, "Medium"),
        (6, 14, "Thick")
    ]

    /// Font size presets (points): small / medium / large.
    private let fontSizeOptions: [(size: CGFloat, iconSize: CGFloat, help: LocalizedStringKey)] = [
        (12, 10, "Small"),
        (16, 13, "Medium"),
        (22, 16, "Large")
    ]

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(tools, id: \.self) { item in
                    toolButton(item)
                }
                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 2)
                actionButton(icon: "arrow.uturn.backward", help: "Undo", action: onUndo, enabled: model.canUndo)
                actionButton(icon: "arrow.uturn.forward", help: "Redo", action: onRedo, enabled: model.canRedo)
                actionButton(icon: "crop", help: "Redraw", action: onRedraw, enabled: true)
                actionButton(icon: "xmark", help: "Cancel", action: onCancel, enabled: true)
                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 2)
                actionButton(icon: "square.and.arrow.down", help: "Save", action: onSave, enabled: true)
                actionButton(icon: "doc.on.doc", help: "Copy", action: onCopy, enabled: true)
            }
            HStack(spacing: 4) {
                ForEach(ScreenshotColor.palette, id: \.self) { color in
                    colorSwatch(color)
                }
                customColorSwatch
                if let extras = contextControls {
                    Divider()
                        .frame(height: 18)
                        .padding(.horizontal, 2)
                    extras
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
    }

    /// Context-dependent second-row controls based on the active tool.
    private var contextControls: AnyView? {
        switch model.activeTool {
        case .rectangle, .ellipse:
            return AnyView(
                HStack(spacing: 4) {
                    fillToggleButton()
                    ForEach(strokeOptions, id: \.width) { opt in
                        strokeButton(width: opt.width, iconSize: opt.iconSize, help: opt.help)
                    }
                }
            )
        case .arrow, .brush, .mosaic:
            return AnyView(
                HStack(spacing: 4) {
                    ForEach(strokeOptions, id: \.width) { opt in
                        strokeButton(width: opt.width, iconSize: opt.iconSize, help: opt.help)
                    }
                }
            )
        case .text:
            return AnyView(
                HStack(spacing: 4) {
                    ForEach(fontSizeOptions, id: \.size) { opt in
                        fontSizeButton(size: opt.size, iconSize: opt.iconSize, help: opt.help)
                    }
                }
            )
        default:
            return nil
        }
    }

    private func toolButton(_ item: ToolItem) -> some View {
        Button(action: { onToolChange(item.tool) }) {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(model.activeTool == item.tool ? appAccent.opacity(0.25) : Color.clear)
                )
                .foregroundStyle(model.activeTool == item.tool ? appAccent : .primary)
        }
        .buttonStyle(.plain)
        .help(item.help)
    }

    private func actionButton(icon: String, help: LocalizedStringKey, action: @escaping () -> Void, enabled: Bool) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 22)
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private func colorSwatch(_ color: ScreenshotColor) -> some View {
        Button(action: { onColorChange(color) }) {
            Circle()
                .fill(Color(red: color.r, green: color.g, blue: color.b, opacity: color.a))
                .frame(width: 16, height: 16)
                .overlay(
                    Circle()
                        .stroke(isActiveColor(color) ? appAccent : Color(nsColor: .separatorColor), lineWidth: isActiveColor(color) ? 2 : 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(color == .black ? "Black" : (color == .white ? "White" : helpForPalette(color)))
    }

    /// Custom-color swatch: a rainbow ring that opens the system color picker.
    /// When a custom color is active, the inner disc shows the picked color.
    private var customColorSwatch: some View {
        Button(action: onPickColor) {
            ZStack {
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [.red, .yellow, .green, .blue, .purple, .red],
                            center: .center
                        ),
                        lineWidth: 2
                    )
                    .frame(width: 16, height: 16)
                if let custom = model.customColor {
                    Circle()
                        .fill(Color(red: custom.r, green: custom.g, blue: custom.b, opacity: custom.a))
                        .frame(width: 10, height: 10)
                }
            }
            .frame(width: 16, height: 16)
            .overlay(
                Circle()
                    .stroke(model.customColor != nil ? appAccent : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Pick color…")
    }

    private func fillToggleButton() -> some View {
        let isOn = model.fillEnabled
        return Button(action: onFillToggle) {
            Image(systemName: isOn ? "rectangle.fill" : "rectangle")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn ? appAccent.opacity(0.25) : Color.clear)
                )
                .foregroundStyle(isOn ? appAccent : .primary)
        }
        .buttonStyle(.plain)
        .help(isOn ? "Filled" : "Outlined")
    }

    private func strokeButton(width: CGFloat, iconSize: CGFloat, help: LocalizedStringKey) -> some View {
        Button(action: { onStrokeWidthChange(width) }) {
            Image(systemName: "circle.fill")
                .font(.system(size: iconSize))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(model.strokeWidth == width ? appAccent.opacity(0.25) : Color.clear)
                )
                .foregroundStyle(model.strokeWidth == width ? appAccent : .primary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func fontSizeButton(size: CGFloat, iconSize: CGFloat, help: LocalizedStringKey) -> some View {
        Button(action: { onFontSizeChange(size) }) {
            Image(systemName: "textformat")
                .font(.system(size: iconSize))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(model.fontSize == size ? appAccent.opacity(0.25) : Color.clear)
                )
                .foregroundStyle(model.fontSize == size ? appAccent : .primary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func isActiveColor(_ color: ScreenshotColor) -> Bool {
        // A palette color is "active" only when there's no custom color override
        // (i.e. customColor is nil) and it equals model.activeColor.
        model.customColor == nil && model.activeColor == color
    }

    private func helpForPalette(_ color: ScreenshotColor) -> LocalizedStringKey {
        switch color {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        default: return ""
        }
    }
}

