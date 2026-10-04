import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct QuickDialCard: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let dial: QuickDial
    let index: Int
    let onNavigate: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onDragProvider: () -> NSItemProvider
    let onDropAt: (Int) -> DialDropDelegate

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 10) {
            iconView
                .frame(width: 56, height: 56)

            Text(dial.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .frame(maxWidth: 110)
        }
        .frame(width: 130, height: 124)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isHovering
                      ? Color(nsColor: .controlBackgroundColor)
                      : Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    isHovering
                        ? appAccent.opacity(0.35)
                        : Color.secondary.opacity(0.12),
                    lineWidth: 0.5
                )
        )
        .shadow(
            color: .black.opacity(isHovering ? 0.10 : 0.04),
            radius: isHovering ? 8 : 3,
            y: isHovering ? 3 : 1
        )
        .scaleEffect(isHovering ? 1.03 : 1.0)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .animation(.smooth(duration: 0.18), value: isHovering)
        .onHover { isHovering = $0 }
        .gesture(ExclusiveGesture(
            TapGesture(count: 2).onEnded { onEdit() },
            TapGesture().onEnded { onNavigate() }
        ))
        .contextMenu {
            Button("编辑") { onEdit() }
            Button("删除", role: .destructive) { onDelete() }
        }
        .onDrag(onDragProvider)
        .onDrop(of: [.text], delegate: onDropAt(index))
    }

    @ViewBuilder
    private var iconView: some View {
        if dial.icon == "globe" {
            FaviconView(urlString: dial.url, size: 40)
                .frame(width: 56, height: 56)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                appAccent.opacity(0.18),
                                appAccent.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: dial.icon)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(appAccent)
            }
            .frame(width: 56, height: 56)
        }
    }
}
