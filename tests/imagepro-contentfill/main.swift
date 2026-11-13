import AppKit
import CoreGraphics
import CoreImage
import Foundation

MainActor.assumeIsolated {

func makeImage(w: Int, h: Int, fill: (Int, Int, UnsafeMutablePointer<UInt8>, Int) -> Void) -> CGImage {
    let bytesPerRow = 4 * w
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * h)
    for y in 0..<h {
        for x in 0..<w { fill(x, y, buf + y * bytesPerRow + x * 4, bytesPerRow) }
    }
    let provider = CGDataProvider(dataInfo: nil, data: buf, size: bytesPerRow * h,
                                  releaseData: { _, p, _ in p.deallocate() })!
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}
func px(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    guard let data = image.dataProvider?.data,
          let ptr = CFDataGetBytePtr(data) else { return (-1, -1, -1) }
    let bpr = CFDataGetLength(data) / image.height
    let i = y * bpr + x * 4
    return (Int(ptr[i]), Int(ptr[i+1]), Int(ptr[i+2]))
}

var checks = 0
var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    checks += 1
    if !cond { failures += 1 }
    print((cond ? "PASS " : "FAIL ") + name + (cond ? "" : " — " + detail))
}

let w = 64, h = 64
let base = makeImage(w: w, h: h) { x, y, p, _ in
    p[0] = 10; p[1] = UInt8(60 + y * 2); p[2] = UInt8(min(255, 160 + y)); p[3] = 255
}
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 20, y: 24, width: 24, height: 16))
let basePixels = ctx.makeImage()!

let mask = makeImage(w: w, h: h) { x, y, p, _ in
    let inside = x >= 16 && x < 48 && y >= 24 && y < 48
    let v: UInt8 = inside ? 255 : 0
    p[0] = v; p[1] = v; p[2] = v; p[3] = 255
}

let filled = ImageEditorRaster.contentFill(
    basePixels, bounds: CGRect(x: 16, y: 24, width: 32, height: 24),
    mask: mask, sourceOrigin: CGPoint(x: 16, y: 0))!

let center = px(filled, 32, 32)
check("contentfill：选区内水印被背景替换", center.0 < 120 && center.2 > 80,
      "center RGB=\(center)")
let outside = px(filled, 56, 8)
let outsideBase = px(basePixels, 56, 8)
check("contentfill：选区外像素不动", abs(outside.0 - outsideBase.0) <= 3
      && abs(outside.1 - outsideBase.1) <= 3 && abs(outside.2 - outsideBase.2) <= 3,
      "outside=\(outside) base=\(outsideBase)")
let edgeIn = px(filled, 17, 36)
let edgeOut = px(filled, 14, 36)
check("contentfill：边缘过渡平滑（跳变 < 90）",
      abs(edgeIn.1 - edgeOut.1) < 90, "in=\(edgeIn) out=\(edgeOut)")

let filledDown = ImageEditorRaster.contentFill(
    basePixels, bounds: CGRect(x: 16, y: 24, width: 32, height: 24),
    mask: mask, sourceOrigin: CGPoint(x: 16, y: 40))!
let centerDown = px(filledDown, 32, 32)
check("contentfill：显式源区生效（下方源区更亮）", centerDown.1 >= center.1 - 12,
      "up g=\(center.1) down g=\(centerDown.1)")

print("\nRESULT \(checks - failures)/\(checks)")
exit(failures == 0 ? 0 : 1)

}
