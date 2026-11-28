// imagepro-probe.swift —— ImagePro 回归套件的 fixture 生成器与像素探针
// （v0.8.85 批 1 第 19 件；测试工具，不参与 App 构建）
//
// 用法：
//   imagepro-probe make <path> [--w 800] [--h 600] [--depth 8|16] [--space sRGB|p3]
//                       [--pattern blocks|solid|gradient|checker] [--color RRGGBB] [--bg RRGGBB]
//   imagepro-probe read <path> [--points "x,y;x,y;..."]
//   imagepro-probe diff <a> <b> [--tol 0] [--exclude "x,y,w,h"]
//
// 坐标约定：所有 **x,y 都是图片像素、左上原点 y 向下**（与 ImagePro base 像素一致）。
// CGContext 是左下原点：内部统一 flip。采样读回统一转 8 位 sRGB RGBA 输出。
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func emit(_ dict: [String: Any], exit code: Int32 = 0) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    print(String(data: data, encoding: .utf8) ?? "{}")
    exit(code)
}

func fail(_ message: String) -> Never {
    emit(["ok": false, "error": message], exit: 1)
}

func hexColor(_ hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6 || s.count == 8, let value = UInt32(s.prefix(6), radix: 16) else { return nil }
    return (CGFloat((value >> 16) & 0xFF) / 255,
            CGFloat((value >> 8) & 0xFF) / 255,
            CGFloat(value & 0xFF) / 255)
}

func makeSpace(_ name: String) -> CGColorSpace {
    if name.lowercased() == "p3" { return CGColorSpace(name: CGColorSpace.displayP3)! }
    return CGColorSpace(name: CGColorSpace.sRGB)!
}

// 左上原点（y 向下）绘制 → CG 左下原点。
func flipRect(_ rect: CGRect, _ height: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
}

/// 在**目标色域**里显式构造颜色。注意 `CGContext.setFillColor(red:green:blue:)`
/// 填的是设备色（≈sRGB）——想造 P3 纯红这类色域外样本必须走 CGColor(colorSpace:)，
/// 否则 fixture 全是 in-gamut 色，色域判据不具判别力（2026-11-29 实测）。
func makeCGColor(_ hex: String, space: CGColorSpace) -> CGColor? {
    guard let c = hexColor(hex) else { return nil }
    return CGColor(colorSpace: space, components: [c.r, c.g, c.b, 1])
}

func drawPattern(_ ctx: CGContext, w: CGFloat, h: CGFloat, space: CGColorSpace,
                 pattern: String, color: String, bg: String) {
    ctx.setFillColor(makeCGColor(bg, space: space) ?? CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    switch pattern.lowercased() {
    case "solid":
        ctx.setFillColor(makeCGColor(color, space: space) ?? CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    case "gradient":
        let colors = [CGColor(colorSpace: space, components: [0, 0, 0, 1])!,
                      CGColor(colorSpace: space, components: [1, 1, 1, 1])!] as CFArray
        let gradient = CGGradient(colorsSpace: space,
                                  colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: h / 2),
                               end: CGPoint(x: w, y: h / 2), options: [])
    case "checker":
        let cell: CGFloat = 20
        var row = 0
        var y: CGFloat = 0
        while y < h {
            var col = 0
            var x: CGFloat = 0
            while x < w {
                let dark = (row + col) % 2 == 0
                let g: CGFloat = dark ? 0.15 : 0.85
                ctx.setFillColor(CGColor(colorSpace: space, components: [g, g, g, 1])!)
                ctx.fill(flipRect(CGRect(x: x, y: y, width: cell, height: cell), h))
                x += cell
                col += 1
            }
            y += cell
            row += 1
        }
    default: // blocks：四色块（左上红 / 右上绿 / 左下蓝 / 右下灰），各 200×150
        let blocks: [(CGRect, String)] = [
            (CGRect(x: 100, y: 100, width: 200, height: 150), "#FF0000"),
            (CGRect(x: 500, y: 100, width: 200, height: 150), "#00FF00"),
            (CGRect(x: 100, y: 400, width: 200, height: 150), "#0000FF"),
            (CGRect(x: 500, y: 400, width: 200, height: 150), "#808080"),
        ]
        for (rect, hex) in blocks {
            guard let cg = makeCGColor(hex, space: space) else { continue }
            ctx.setFillColor(cg)
            ctx.fill(flipRect(rect, h))
        }
    }
}

func loadImage(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
        return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// 把任意位图绘进 8 位 RGBA（默认 sRGB；--space p3 时在 P3 里比——广色域
/// 裁剪只有在目标空间与原空间一致时才看得见）。
func rgba8(_ image: CGImage, spaceName: String = "sRGB") -> (data: Data, width: Int, height: Int)? {
    let w = image.width, h = image.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4,
                              space: makeSpace(spaceName),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let base = ctx.data else { return nil }
    return (Data(bytes: base, count: w * h * 4), w, h)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("usage: imagepro-probe make|read|diff ...")
}

func option(_ name: String, _ fallback: String? = nil) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
    return args[i + 1]
}

func positionals() -> [String] {
    var out: [String] = []
    var skipNext = false
    for (i, a) in args.enumerated() {
        if skipNext { skipNext = false; continue }
        if a.hasPrefix("--") { skipNext = true; continue }
        if i == 0 { continue }
        out.append(a)
    }
    return out
}

switch command {
case "make":
    guard let path = positionals().first else { fail("make needs <path>") }
    let w = Int(option("--w", "800")!) ?? 800
    let h = Int(option("--h", "600")!) ?? 600
    let depth = Int(option("--depth", "8")!) ?? 8
    let space = makeSpace(option("--space", "sRGB")!)
    let pattern = option("--pattern", "blocks")!
    let color = option("--color", "#808080")!
    let bg = option("--bg", "#FFFFFF")!
    guard let ctx = CGContext(data: nil, width: w, height: h,
                              bitsPerComponent: depth == 16 ? 16 : 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("context creation failed") }
    drawPattern(ctx, w: CGFloat(w), h: CGFloat(h), space: space, pattern: pattern, color: color, bg: bg)
    guard let image = ctx.makeImage() else { fail("makeImage failed") }
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil)
    else { fail("destination creation failed") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("write failed") }
    emit(["ok": true, "path": path, "w": w, "h": h, "depth": depth,
          "space": option("--space", "sRGB")!, "pattern": pattern])

case "read":
    guard let path = positionals().first, let image = loadImage(path) else {
        fail("cannot read image")
    }
    var result: [String: Any] = [
        "ok": true, "w": image.width, "h": image.height,
        "bpc": image.bitsPerComponent,
        "bpp": image.bitsPerPixel,
        "cs": image.colorSpace.map { String(describing: $0.name ?? "unnamed" as CFString) } ?? "nil",
        "hasProfile": image.colorSpace != nil,
    ]
    if let points = option("--points"), let data = rgba8(image, spaceName: option("--space", "sRGB")!) {
        var samples: [[String: Any]] = []
        for pair in points.split(separator: ";") {
            let parts = pair.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count >= 2 else { continue }
            let (x, y) = (parts[0], parts[1])
            guard x >= 0, y >= 0, x < data.width, y < data.height else {
                samples.append(["x": x, "y": y, "error": "out of bounds"]); continue
            }
            let offset = (y * data.width + x) * 4
            let bytes = [UInt8](data.data[offset..<(offset + 4)])
            samples.append(["x": x, "y": y, "rgba": bytes.map { Int($0) }])
        }
        result["samples"] = samples
    }
    emit(result)

case "bbox":
    // 蒙版包围盒（灰度高=选中；阈值默认 128）。坐标 = 图片像素。
    guard let path = positionals().first, let image = loadImage(path) else {
        fail("cannot read image")
    }
    let threshold = Int(option("--threshold", "128")!) ?? 128
    guard let data = rgba8(image) else { fail("decode failed") }
    let bytes = [UInt8](data.data)
    var minX = data.width, minY = data.height, maxX = -1, maxY = -1
    for y in 0..<data.height {
        for x in 0..<data.width {
            let offset = (y * data.width + x) * 4
            if Int(bytes[offset]) > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    if maxX < 0 {
        emit(["ok": true, "empty": true, "w": 0, "h": 0])
    }
    emit(["ok": true, "empty": false, "x": minX, "y": minY,
          "w": maxX - minX + 1, "h": maxY - minY + 1])

case "diff":
    let positional = positionals()
    guard positional.count >= 2, let a = loadImage(positional[0]), let b = loadImage(positional[1]) else {
        fail("diff needs <a> <b>")
    }
    let tol = Int(option("--tol", "0")!) ?? 0
    let spaceName = option("--space", "sRGB")!
    var exclude: CGRect?
    if let raw = option("--exclude") {
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 4 {
            exclude = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        }
    }
    guard let da = rgba8(a, spaceName: spaceName), let db = rgba8(b, spaceName: spaceName) else {
        fail("decode failed")
    }
    guard da.width == db.width, da.height == db.height else {
        fail("size mismatch: \(da.width)x\(da.height) vs \(db.width)x\(db.height)")
    }
    var diffCount = 0
    var excludedDiff = 0
    let pa = [UInt8](da.data), pb = [UInt8](db.data)
    for y in 0..<da.height {
        for x in 0..<da.width {
            let offset = (y * da.width + x) * 4
            var different = false
            for c in 0..<4 where abs(Int(pa[offset + c]) - Int(pb[offset + c])) > tol {
                different = true
                break
            }
            guard different else { continue }
            if let e = exclude, e.contains(CGPoint(x: x, y: y)) {
                excludedDiff += 1
            } else {
                diffCount += 1
            }
        }
    }
    emit(["ok": true, "w": da.width, "h": da.height,
          "diff": diffCount, "excludedDiff": excludedDiff])

default:
    fail("unknown command \(command)")
}
