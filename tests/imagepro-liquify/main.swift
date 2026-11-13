import AppKit

MainActor.assumeIsolated {

func makeImage(w: Int, h: Int, fill: (Int, Int, UnsafeMutablePointer<UInt8>, Int) -> Void) -> CGImage {
    let bytesPerRow = 4 * w
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * h)
    for y in 0..<h {
        for x in 0..<w {
            fill(x, y, buf + y * bytesPerRow + x * 4, bytesPerRow)
        }
    }
    let provider = CGDataProvider(dataInfo: nil, data: buf, size: bytesPerRow * h,
                                  releaseData: { _, p, _ in p.deallocate() })!
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

func pixel(_ image: CGImage, x: Int, y: Int) -> UInt8 {
    let bytesPerRow = 4 * image.width
    guard let data = image.dataProvider?.data,
          let ptr = CFDataGetBytePtr(data) else { return 255 }
    return ptr[y * bytesPerRow + x * 4]
}

func boundary(_ image: CGImage, y: Int) -> Int? {
    for x in 0..<200 where pixel(image, x: x, y: y) > 127 { return x }
    return nil
}

var checks = 0
var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    checks += 1
    if !cond { failures += 1 }
    print((cond ? "PASS " : "FAIL ") + name + (cond ? "" : " — " + detail))
}

let base = makeImage(w: 200, h: 200) { x, _, p, _ in
    let v: UInt8 = x < 100 ? 0 : 255
    p[0] = v; p[1] = v; p[2] = v; p[3] = 255
}
let baseBoundary = boundary(base, y: 100)

let pushed = try! LiquifyBrush.warp(base, center: CGPoint(x: 100, y: 100),
                                    radius: 40, mode: .push,
                                    delta: CGPoint(x: 20, y: 0))!
let pushedBoundary = boundary(pushed, y: 100)
check("push: boundary moved right", pushedBoundary != nil && baseBoundary != nil
      && pushedBoundary! > baseBoundary!,
      "base=\(String(describing: baseBoundary)) pushed=\(String(describing: pushedBoundary))")

let expanded = try! LiquifyBrush.warp(base, center: CGPoint(x: 100, y: 100),
                                      radius: 40, mode: .expand, delta: .zero)!
let expandedBoundary = boundary(expanded, y: 100)
check("expand: boundary moved left (black grew)", expandedBoundary != nil
      && baseBoundary != nil && expandedBoundary! < baseBoundary!,
      "base=\(String(describing: baseBoundary)) expanded=\(String(describing: expandedBoundary))")

let pinched = try! LiquifyBrush.warp(base, center: CGPoint(x: 60, y: 100),
                                     radius: 50, mode: .pinch, delta: .zero)!
let pinchedBoundary = boundary(pinched, y: 100)
check("pinch: white pulled into black (boundary left)", pinchedBoundary != nil
      && baseBoundary != nil && pinchedBoundary! < baseBoundary!,
      "base=\(String(describing: baseBoundary)) pinched=\(String(describing: pinchedBoundary))")

print("\nRESULT \(checks - failures)/\(checks)")
exit(failures == 0 ? 0 : 1)

}
