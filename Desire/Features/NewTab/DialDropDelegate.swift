import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DialDropDelegate: DropDelegate {
    let targetIndex: Int
    let store: QuickDialStore

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let str = reading as? String, let source = Int(str) else { return }
            Task { @MainActor in
                store.move(from: source, to: targetIndex)
            }
        }
        return true
    }
}
