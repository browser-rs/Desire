import CoreGraphics
import Foundation

enum ResponsiveOrientation: String, CaseIterable, Codable {
    case portrait, landscape
}

struct ResponsiveConfig: Codable {
    var isEnabled = false
    var selectedPresetID: UUID?
    var customWidth: Int = 375
    var customHeight: Int = 667
    var orientation: ResponsiveOrientation = .portrait
    var showRulers = false
    var showMediaQueryInspector = false
    var networkThrottle: ThrottlePreset = .none
    var pixelRatio: Double = 2.0
    var touchSimulationEnabled = false

    var effectiveSize: CGSize {
        if let id = selectedPresetID, let preset = devicePresets.first(where: { $0.id == id }) {
            return orientation == .portrait
                ? CGSize(width: preset.width, height: preset.height)
                : CGSize(width: preset.height, height: preset.width)
        }
        let w = CGFloat(customWidth)
        let h = CGFloat(customHeight)
        return orientation == .portrait ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
    }
}
