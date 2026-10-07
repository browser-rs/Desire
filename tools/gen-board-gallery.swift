import Foundation

// 白板模板 Gallery 生成器（0.7.1 社区分享）：把 WhiteboardTemplates 的五个
// 内置模板写成为 .board 文件（带 schema 版本），供产品页 Gallery 页静态分发。
// **单一真相 = WhiteboardTemplates.swift**——模板改了重跑本脚本再部署页面。
// 运行（仓库根）：
//   swiftc tools/gen-board-gallery.swift \
//     apps/macos/Desire/Features/Whiteboard/WhiteboardSpec.swift \
//     apps/macos/Desire/Features/Whiteboard/WhiteboardTemplates.swift \
//     -o /tmp/genboard && /tmp/genboard
@main
enum GalleryGen {
    static func main() {
        let outDir = "website/gallery/boards"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        var manifestLines: [String] = []
        for template in WhiteboardTemplates.builtIn {
            var spec = WhiteboardSpec(title: template.name, blocks: template.blocks)
            spec.schemaVersion = WhiteboardSpec.boardSchemaVersion
            let data = try! JSONEncoder().encode(spec.shareable)
            let path = "\(outDir)/\(template.id).board"
            try! data.write(to: URL(fileURLWithPath: path))
            let types = Dictionary(grouping: template.blocks, by: \.type)
                .map { "\($0.key)×\($0.value.count)" }
                .sorted()
                .joined(separator: " ")
            manifestLines.append("- \(template.id).board | \(template.name) | \(types)")
            print("written: \(path) (\(data.count) bytes) — \(template.name) [\(types)]")
        }
        print("\nmanifest（Gallery 页引用）：\n" + manifestLines.joined(separator: "\n"))
    }
}
