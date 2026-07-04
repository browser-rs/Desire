import Foundation

struct DevicePreset: Identifiable {
    let id = UUID()
    let name: String
    let width: Int
    let height: Int
    let icon: String
}

let devicePresets: [DevicePreset] = [
    .init(name: "iPhone SE", width: 375, height: 667, icon: "iphone.gen2"),
    .init(name: "iPhone 14 Pro", width: 390, height: 844, icon: "iphone.gen3"),
    .init(name: "iPhone 14 Pro Max", width: 430, height: 932, icon: "iphone.gen3"),
    .init(name: "iPad 10", width: 820, height: 1180, icon: "ipad.gen2"),
    .init(name: "iPad Pro 12.9\"", width: 1024, height: 1366, icon: "ipad.pro.gen2"),
]
