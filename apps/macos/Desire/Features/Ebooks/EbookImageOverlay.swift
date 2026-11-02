import AppKit
import SwiftUI

/// 正文图片查看器（v0.8.36）：缩放/平移/双击复位，Esc 或点背景关闭。
struct EbookImageOverlay: View {
    let image: NSImage
    let onClose: () -> Void

    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.86)
                    .ignoresSafeArea()
                    .onTapGesture { onClose() }
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width * 0.92,
                           height: geometry.size.height * 0.92)
                    .scaleEffect(zoom)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                zoom = min(max(lastZoom * value, 1), 6)
                            }
                            .onEnded { _ in
                                lastZoom = zoom
                            })
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height)
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            })
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            zoom = 1
                            lastZoom = 1
                            offset = .zero
                            lastOffset = .zero
                        }
                    }
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            onClose()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(Circle().fill(.black.opacity(0.45)))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(16)
            }
        }
        .onExitCommand { onClose() }
    }
}
