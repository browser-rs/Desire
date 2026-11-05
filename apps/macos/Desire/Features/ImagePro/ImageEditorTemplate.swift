import CoreGraphics
import Foundation

/// 画布/新建文档模板（迭代 5）：视频封面、社媒、海报常用尺寸。
nonisolated struct ImageEditorTemplate: Identifiable, Equatable {
    let id: String
    let name: String
    let width: Int
    let height: Int

    var size: CGSize { CGSize(width: width, height: height) }

    static let all: [ImageEditorTemplate] = [
        .init(id: "youtube", name: "YouTube 1280×720", width: 1280, height: 720),
        .init(id: "shorts", name: "Shorts / Reels 1080×1920", width: 1080, height: 1920),
        .init(id: "square", name: "Square 1080×1080", width: 1080, height: 1080),
        .init(id: "x", name: "X / Twitter 1600×900", width: 1600, height: 900),
        .init(id: "wechat", name: "WeChat 900×383", width: 900, height: 383),
        .init(id: "a4", name: "A4 300dpi 2480×3508", width: 2480, height: 3508),
        .init(id: "a3", name: "A3 300dpi 3508×4961", width: 3508, height: 4961),
        .init(id: "fullhd", name: "Full HD 1920×1080", width: 1920, height: 1080),
    ]
}
