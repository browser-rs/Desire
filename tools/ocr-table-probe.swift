// OCR 表格链路探针（v0.7.24）：渲染一张真表格图 → Vision 识别（真 boxes）
// → OCRTableDetector 重建 Markdown。走完整链路（不只是合成 boxes）。
//
// 编译运行：
//   swiftc -o /tmp/ocr_table_probe \
//     apps/macos/Desire/Features/Screenshot/OCRTableDetector.swift \
//     apps/macos/Desire/Features/Screenshot/VisionOCRService.swift \
//     tools/ocr-table-probe.swift && /tmp/ocr_table_probe
import AppKit
import Foundation
import Vision

@main
enum Probe {
    static func main() async {
        var failures: [String] = []
        var count = 0
        func check(_ name: String, _ ok: Bool) {
            count += 1
            if !ok { failures.append(name) }
            print("\(ok ? "PASS" : "FAIL") \(name)")
        }

        // 渲染 600×220 的 3×3 表格图：表头 + 两行，列间距大（OCR 会按单元返回观察）。
        let image = NSImage(size: NSSize(width: 600, height: 220))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 600, height: 220).fill()
        let rows: [[String]] = [["姓名", "城市", "年龄"], ["小明", "北京", "28"], ["小红", "上海", "31"]]
        let font = NSFont.systemFont(ofSize: 26)
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.enumerated() {
                let x = 40.0 + Double(c) * 190.0
                let y = 160.0 - Double(r) * 60.0
                (cell as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font])
            }
        }
        image.unlockFocus()

        do {
            let result = try await VisionOCRService.recognize(image: image)
            check("OCR 识别出行", result.lines.count >= 6)
            check("boxes 与 lines 对齐", result.boxes.count == result.lines.count)
            let markdown = OCRTableDetector.markdownTable(from: VisionOCRService.tableLines(from: result))
            check("重建出 Markdown 表格", markdown != nil)
            if let markdown {
                print(markdown)
                check("含表头单元", markdown.contains("姓名") && markdown.contains("城市"))
                check("含数据单元", markdown.contains("北京") && markdown.contains("上海"))
                check("列分隔正确（3 列）",
                      markdown.components(separatedBy: "\n").allSatisfy {
                          $0.components(separatedBy: "|").count == 5
                      })
            }
        } catch {
            check("OCR 链路（\(error.localizedDescription)）", false)
        }

        print("\nOCR 表格链路探针：\(count) 项，失败 \(failures.count) 项")
        if !failures.isEmpty {
            for f in failures { print("  - \(f)") }
            exit(1)
        }
        print("全部通过 ✓")
    }
}
