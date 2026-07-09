import Foundation

enum DeviceCategory: String, CaseIterable, Codable {
    case phone, foldable, tablet, desktop, watch

    var label: String {
        switch self {
        case .phone: return "Phone"
        case .foldable: return "Fold"
        case .tablet: return "Tablet"
        case .desktop: return "Desktop"
        case .watch: return "Watch"
        }
    }

    var icon: String {
        switch self {
        case .phone: return "iphone.gen3"
        case .foldable: return "flipside"
        case .tablet: return "ipad.gen2"
        case .desktop: return "display"
        case .watch: return "applewatch"
        }
    }
}

struct DevicePreset: Identifiable, Codable {
    let id: UUID
    let name: String
    let width: Int
    let height: Int
    let icon: String
    let category: DeviceCategory
    let frameAssetName: String?
    let isFoldable: Bool
    let unfoldedSize: CGSize?

    init(id: UUID = UUID(), name: String, width: Int, height: Int, icon: String, category: DeviceCategory, frameAssetName: String? = nil, isFoldable: Bool = false, unfoldedSize: CGSize? = nil) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.icon = icon
        self.category = category
        self.frameAssetName = frameAssetName
        self.isFoldable = isFoldable
        self.unfoldedSize = unfoldedSize
    }

    var displaySize: String { "\(width)×\(height)" }
}

let devicePresets: [DevicePreset] = [
    .init(name: "iPhone SE", width: 375, height: 667, icon: "iphone.gen2", category: .phone),
    .init(name: "iPhone 14 Pro", width: 390, height: 844, icon: "iphone.gen3", category: .phone),
    .init(name: "iPhone 14 Pro Max", width: 430, height: 932, icon: "iphone.gen3", category: .phone),
    .init(name: "Galaxy S24", width: 360, height: 780, icon: "iphone.gen1", category: .phone),
    .init(name: "Pixel 9", width: 393, height: 852, icon: "iphone.gen1", category: .phone),
    .init(name: "Pixel 9 Pro", width: 393, height: 852, icon: "iphone.gen1", category: .phone),

    .init(name: "Z Fold 6", width: 374, height: 512, icon: "flipside", category: .foldable, isFoldable: true, unfoldedSize: CGSize(width: 717, height: 512)),
    .init(name: "Z Flip 6", width: 375, height: 812, icon: "flipside", category: .foldable),
    .init(name: "Pixel Fold", width: 373, height: 556, icon: "flipside", category: .foldable, isFoldable: true, unfoldedSize: CGSize(width: 746, height: 556)),
    .init(name: "Surface Duo", width: 540, height: 720, icon: "flipside", category: .foldable),

    .init(name: "iPad 10", width: 820, height: 1180, icon: "ipad.gen2", category: .tablet),
    .init(name: "iPad Pro 12.9\"", width: 1024, height: 1366, icon: "ipad.pro.gen2", category: .tablet),
    .init(name: "Galaxy Tab S9", width: 800, height: 1280, icon: "ipad.gen1", category: .tablet),
    .init(name: "Surface Pro", width: 1440, height: 960, icon: "ipad.gen1", category: .tablet),

    .init(name: "HD", width: 1366, height: 768, icon: "display", category: .desktop),
    .init(name: "WXGA+", width: 1440, height: 900, icon: "display", category: .desktop),
    .init(name: "Full HD", width: 1920, height: 1080, icon: "display", category: .desktop),
    .init(name: "QHD", width: 2560, height: 1440, icon: "display", category: .desktop),

    .init(name: "Apple Watch 45mm", width: 396, height: 484, icon: "applewatch", category: .watch),
    .init(name: "Apple Watch 41mm", width: 352, height: 430, icon: "applewatch", category: .watch),
]
