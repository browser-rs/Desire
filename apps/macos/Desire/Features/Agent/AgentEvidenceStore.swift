import AppKit
import Combine
import Foundation
import WebKit

/// 页面感知回证（0.3.2）：click/fill 这类"动作"工具执行后自动截一张
/// 视口快照，按工具调用 id 存档——面板的工具调用列表内联展示"点完之后
/// 页面长这样"，act + evidence 成对可查。
///
/// 容量有界（最近 12 张）：回证是消费型数据，服务"刚才那一下点对了吗"
/// 的即时核对，不做长期存档。
@MainActor
final class AgentEvidenceStore: ObservableObject {
    static let shared = AgentEvidenceStore()

    /// 附加证据的工具名（v1：动作类两件套）。
    static let evidenceTools: Set<String> = ["click", "fill", "clickAt", "pressKey"]

    @Published private(set) var images: [String: NSImage] = [:]
    private var order: [String] = []
    private let cap = 12


    /// 等比缩到目标宽度以内（宽 ≤ max 时原样返回，避免无谓重绘）。
    private static func downscaled(_ image: NSImage, maxPixelWidth: CGFloat) -> NSImage {
        let rep = image.representations.first
        let pixelWidth = CGFloat(rep?.pixelsWide ?? Int(image.size.width))
        guard pixelWidth > maxPixelWidth, image.size.width > 0 else { return image }
        let scale = maxPixelWidth / pixelWidth
        let target = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let result = NSImage(size: target)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target))
        result.unlockFocus()
        return result
    }

    func attach(_ image: NSImage, for callID: String) {
        // R2-9：证据图缩到 ≤1200px 宽再存——此前存未缩放 retina 位图
        //（~20-30MB/张 ×12 = 峰值数百 MB，而展示尺寸远小于此）。
        images[callID] = Self.downscaled(image, maxPixelWidth: 1200)
        order.append(callID)
        while order.count > cap {
            let evicted = order.removeFirst()
            images.removeValue(forKey: evicted)
        }
    }

    func image(for callID: String) -> NSImage? {
        images[callID]
    }

    /// 执行完一个动作工具后自动截图（失败静默——回证是尽力而为）。
    func captureEvidence(for callID: String, in webView: WKWebView) {
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            Task { @MainActor [weak self] in
                guard let self, let image else { return }
                self.attach(image, for: callID)
            }
        }
    }
}
