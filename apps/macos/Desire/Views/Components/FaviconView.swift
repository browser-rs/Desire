import AppKit
import SwiftUI

struct FaviconView: View {
    let urlString: String
    var size: CGFloat = 16

    @State private var image: NSImage?
    @State private var loadedDomain: String?

    private var firstLetter: String {
        guard let domain = FaviconStore.domainKey(from: urlString),
              let first = domain.first else { return "?" }
        return String(first).uppercased()
    }

    private var letterColor: Color {
        guard let domain = FaviconStore.domainKey(from: urlString) else { return .gray }
        let palette: [Color] = [
            .blue, .green, .orange, .purple, .pink, .teal, .indigo, .red, .mint, .cyan
        ]
        let hash = abs(domain.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        return palette[hash % palette.count]
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ZStack {
                    Circle()
                        .fill(letterColor.opacity(0.18))
                    Text(firstLetter)
                        .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                        .foregroundStyle(letterColor)
                }
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
