import UIKit

extension UIImage {
    /// 上传前压缩：长边 ≤2048px（等比），JPEG 质量由调用方定。
    /// 手机照片原始 4032×3024 ≈ 3-5MB，压后 1-2MB（base64 膨胀 1.37x 后
    /// 仍在 remote_inbox mediumtext 与传输预算内）。
    func resizedForUpload(maxSide: CGFloat = 2048) -> UIImage {
        let side = max(size.width, size.height)
        guard side > maxSide, side > 0 else { return self }
        let scale = maxSide / side
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
