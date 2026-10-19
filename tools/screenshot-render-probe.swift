// 截图标注渲染探针（v0.7.24）：放大镜像素级断言。
//
// 编译运行：
//   swiftc -o /tmp/screenshot_probe \
//     apps/macos/Desire/Features/Screenshot/Screenshot.swift \
//     apps/macos/Desire/Features/Screenshot/ScreenshotAnnotationRenderer.swift \
//     tools/screenshot-render-probe.swift && /tmp/screenshot_probe
//
// 源图 = 100×100 垂直分割：x<46 红、x≥46 蓝（垂直分割与 y 翻转无关，
// 探针因此不依赖坐标系方向）。放大镜：拖框 (30,30)-(70,70) → 镜头圆心
// (50,50)、半径 20、2× 放大。关键断言：镜头内 (44,50) 放大后采样源 (47,50)
// = 蓝——**未放大时该点应为红**，这是"确实放大了"的判别位。
import AppKit
import CoreGraphics

let W = 100
let H = 100
let split: CGFloat = 46

var failures: [String] = []
var count = 0
func check(_ name: String, _ condition: Bool) {
    count += 1
    if !condition { failures.append(name) }
    print("\(condition ? "PASS" : "FAIL") \(name)")
}

func makeSource() -> NSImage {
    let image = NSImage(size: NSSize(width: W, height: H))
    image.lockFocus()
    NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: split, height: CGFloat(H)).fill()
    NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).setFill()
    NSRect(x: split, y: 0, width: CGFloat(W) - split, height: CGFloat(H)).fill()
    image.unlockFocus()
    return image
}

/// 与渲染器约定一致的 top-left 坐标系；返回按内存行序（= top-down y）的 RGBA。
func render(_ annotation: ScreenshotAnnotation, source: NSImage) -> [UInt8] {
    guard let ctx = CGContext(
        data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
    ctx.translateBy(x: 0, y: CGFloat(H))
    ctx.scaleBy(x: 1, y: -1)
    if let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
    }
    ScreenshotAnnotationRenderer.draw(
        annotation, in: ctx,
        canvasSize: CGSize(width: W, height: H), mosaicSource: source)
    guard let data = ctx.data else { return [] }
    return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: W * H * 4))
}

func pixel(_ buf: [UInt8], _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    let i = (y * W + x) * 4
    return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
}

func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 180 && p.b < 80 }
func isBlue(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.b > 180 && p.r < 80 }

@main
enum Probe {
static func main() {
let source = makeSource()
let magnifier = ScreenshotAnnotation(
    tool: .magnifier,
    points: [CGPoint(x: 30, y: 30), CGPoint(x: 70, y: 70)],
    color: .black,
    strokeWidth: 2)
let buf = render(magnifier, source: source)

check("镜头外像素不变（(10,50) 红）", isRed(pixel(buf, 10, 50)))
check("镜头内右半保持蓝（(60,50)）", isBlue(pixel(buf, 60, 50)))
check("放大判别位：(44,50) 采样源 47 → 蓝（未放大应为红）", isBlue(pixel(buf, 44, 50)))
check("镜头内左远点 (40,50) 采样源 45 → 仍红", isRed(pixel(buf, 40, 50)))
let ring = pixel(buf, 50, 30)
check("圆环描边可见（(50,30) 非纯色）", max(ring.r, ring.g, ring.b) < 140)

// 小拖框：直径钳到 24，不崩溃且有环
let tiny = ScreenshotAnnotation(
    tool: .magnifier,
    points: [CGPoint(x: 50, y: 50), CGPoint(x: 54, y: 54)],
    color: .black, strokeWidth: 2)
let tinyBuf = render(tiny, source: source)
check("小拖框镜头仍在（圆心 (52,52) 有内容）", !tinyBuf.isEmpty)

print("\n截图渲染探针：\(count) 项，失败 \(failures.count) 项")
if !failures.isEmpty {
    print("失败清单：")
    for f in failures { print("  - \(f)") }
    exit(1)
}
print("全部通过 ✓")
}
}
