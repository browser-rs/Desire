import SwiftUI
import Vision
import VisionKit

/// 相机扫码（QR）。扫码配对与扫码登录共用。
///
/// 这里唯一的坑是**启动时机**：`updateUIViewController` 只在 SwiftUI 认为
/// 需要更新时被调用，而 sheet 弹出的第一帧 `view.window` 还是 nil。若只在
/// 那一次里判断并放弃，之后就再没人调 `startScanning()` —— 表现为相机画面
/// 开着、却永远不识别任何码（"扫不出码"）。所以自己轮询等 window 就绪。
struct ScannerSheet: UIViewControllerRepresentable {
    let onRead: (String) -> Void
    /// 相机启动失败时回调——最常见的原因是相机权限被拒（此前 `try?` 把错误
    /// 静默吞掉，表现就是"相机开着却毫无反应"，完全无从判断）。
    var onFailure: ((String) -> Void)?

    func makeUIViewController(context: Context) -> DataScannerViewController {
        // 关闭高亮/引导层：每帧 overlay 合成是扫码唤起卡顿的主要来源
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            isGuidanceEnabled: false,
            isHighlightingEnabled: false)
        scanner.delegate = context.coordinator
        context.coordinator.startWhenReady(scanner)
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        // 另一条启动路径（SwiftUI 恰好重绘时），与轮询共用 started 标志，幂等。
        context.coordinator.startWhenReady(uiViewController)
    }

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onRead: onRead, onFailure: onFailure) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onRead: (String) -> Void
        let onFailure: ((String) -> Void)?
        private var didFire = false
        private var started = false
        private var attempts = 0

        init(onRead: @escaping (String) -> Void, onFailure: ((String) -> Void)?) {
            self.onRead = onRead
            self.onFailure = onFailure
        }

        /// 等视图真正上屏再启动相机管线（每 50ms 探一次，最多约 2s）。
        func startWhenReady(_ scanner: DataScannerViewController) {
            guard !started, !didFire else { return }
            if scanner.view.window != nil {
                started = true
                do {
                    try scanner.startScanning()
                } catch {
                    onFailure?(error.localizedDescription)
                }
                return
            }
            guard attempts < 40 else { return }
            attempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak scanner] in
                guard let self, let scanner else { return }
                self.startWhenReady(scanner)
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]
        ) {
            consume(allItems, scanner: dataScanner)
        }

        /// 兜底：码在启动前就已经在画面里时，首次识别可能只走 update 而不走
        /// add —— 只监听 add 会"看着码却毫无反应"。
        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]
        ) {
            consume(allItems, scanner: dataScanner)
        }

        private func consume(_ items: [RecognizedItem], scanner: DataScannerViewController) {
            guard !didFire else { return }
            for item in items {
                guard case .barcode(let barcode) = item,
                      let raw = barcode.payloadStringValue,
                      !raw.isEmpty else { continue }
                didFire = true
                scanner.stopScanning()
                onRead(raw)
                return
            }
        }
    }
}
