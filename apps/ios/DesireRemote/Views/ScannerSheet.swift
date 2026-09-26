import SwiftUI
import Vision
import VisionKit

struct ScannerSheet: UIViewControllerRepresentable {
    let onRead: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        // DataScannerViewController 不可继承（非 open），启动扫描放这里
        if !context.coordinator.started {
            context.coordinator.started = true
            try? uiViewController.startScanning()
        }
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
                    onRead(raw)
                    return
                }
            }
        }
    }
}

// MARK: - Markdown 渲染（MarkdownUI，主题照 IrsClawApp MarkdownTextView）

