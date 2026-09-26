import SwiftUI
import Vision
import VisionKit

struct ScannerSheet: UIViewControllerRepresentable {
    let onRead: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        // 关闭高亮/引导层：每帧 overlay 合成是扫码唤起卡顿的主要来源
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            isGuidanceEnabled: false,
            isHighlightingEnabled: false)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        // 等 view 真正上屏（挂到 window）再启动摄像头管线——sheet 弹出
        // 的第一帧就 start 会把管线启动压在主线程上，造成唤起卡顿；
        // 上屏前的启动失败（try 静默）也由这里的下次调用重试兜底。
        guard !context.coordinator.started, uiViewController.view.window != nil else { return }
        context.coordinator.started = true
        try? uiViewController.startScanning()
    }

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onRead: onRead) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onRead: (String) -> Void
        private var didFire = false
        fileprivate var started = false
        init(onRead: @escaping (String) -> Void) { self.onRead = onRead }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !didFire else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let raw = barcode.payloadStringValue,
                   !raw.isEmpty {
                    didFire = true
                    dataScanner.stopScanning()
                    onRead(raw)
                    return
                }
            }
        }
    }
}

// MARK: - Markdown 渲染（MarkdownUI，主题照 IrsClawApp MarkdownTextView）

