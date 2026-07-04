import AppKit
import SwiftUI

struct FaviconView: View {
    let urlString: String
    var size: CGFloat = 16

    @State private var image: NSImage?
    @State private var loadedDomain: String?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: FaviconStore.domainKey(from: urlString)) {
            let key = FaviconStore.domainKey(from: urlString)
            guard loadedDomain != key else { return }
            loadedDomain = key
            if key == nil {
                image = nil
                return
            }
            let loaded = await FaviconStore.shared.favicon(for: urlString)
            if loadedDomain == key {
                image = loaded
            }
        }
    }
}
