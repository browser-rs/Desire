# Responsive Design Mode Enhancement — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform responsive mode from 5 Apple-only presets into a full cross-platform device debugging tool.

**Architecture:** Double-layer separation — `ResponsiveDesignStore` (global preset catalog) + `Tab.responsiveConfig: ResponsiveConfig` (per-tab state). Views read from config, store provides preset data.

**Tech Stack:** SwiftUI, WKWebView (JS injection for touch sim + media queries), URLProtocol (network throttle)

---

## Phase 1: Foundation + Presets + Device Frames + Drag + Orientation

### Task 1: Rewrite DevicePreset Model

**Files:**
- Modify: `Desire/Features/ResponsiveDesign/DevicePreset.swift`

- [ ] **Step 1: Replace entire file with enhanced model + categories + full preset list**

```swift
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
    // Phone
    .init(name: "iPhone SE", width: 375, height: 667, icon: "iphone.gen2", category: .phone),
    .init(name: "iPhone 14 Pro", width: 390, height: 844, icon: "iphone.gen3", category: .phone),
    .init(name: "iPhone 14 Pro Max", width: 430, height: 932, icon: "iphone.gen3", category: .phone),
    .init(name: "Galaxy S24", width: 360, height: 780, icon: "iphone.gen1", category: .phone),
    .init(name: "Pixel 9", width: 393, height: 852, icon: "iphone.gen1", category: .phone),
    .init(name: "Pixel 9 Pro", width: 393, height: 852, icon: "iphone.gen1", category: .phone),

    // Foldable
    .init(name: "Z Fold 6", width: 374, height: 512, icon: "flipside", category: .foldable, isFoldable: true, unfoldedSize: CGSize(width: 717, height: 512)),
    .init(name: "Z Flip 6", width: 375, height: 812, icon: "flipside", category: .foldable),
    .init(name: "Pixel Fold", width: 373, height: 556, icon: "flipside", category: .foldable, isFoldable: true, unfoldedSize: CGSize(width: 746, height: 556)),
    .init(name: "Surface Duo", width: 540, height: 720, icon: "flipside", category: .foldable),

    // Tablet
    .init(name: "iPad 10", width: 820, height: 1180, icon: "ipad.gen2", category: .tablet),
    .init(name: "iPad Pro 12.9\"", width: 1024, height: 1366, icon: "ipad.pro.gen2", category: .tablet),
    .init(name: "Galaxy Tab S9", width: 800, height: 1280, icon: "ipad.gen1", category: .tablet),
    .init(name: "Surface Pro", width: 1440, height: 960, icon: "ipad.gen1", category: .tablet),

    // Desktop
    .init(name: "HD", width: 1366, height: 768, icon: "display", category: .desktop),
    .init(name: "WXGA+", width: 1440, height: 900, icon: "display", category: .desktop),
    .init(name: "Full HD", width: 1920, height: 1080, icon: "display", category: .desktop),
    .init(name: "QHD", width: 2560, height: 1440, icon: "display", category: .desktop),

    // Watch
    .init(name: "Apple Watch 45mm", width: 396, height: 484, icon: "applewatch", category: .watch),
    .init(name: "Apple Watch 41mm", width: 352, height: 430, icon: "applewatch", category: .watch),
]
```

- [ ] **Step 2: Run build to verify**

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -5
```

---

### Task 2: Create ResponsiveConfig + ThrottlePreset

**Files:**
- Create: `Desire/Features/ResponsiveDesign/ResponsiveConfig.swift`
- Create: `Desire/Features/ResponsiveDesign/ThrottlePreset.swift`

- [ ] **Step 1: Create ThrottlePreset.swift**

```swift
import Foundation

enum ThrottlePreset: String, CaseIterable, Codable {
    case none, slow3G, fast3G, offline

    var label: String {
        switch self {
        case .none: return "No Throttling"
        case .slow3G: return "Slow 3G"
        case .fast3G: return "Fast 3G"
        case .offline: return "Offline"
        }
    }
}
```

- [ ] **Step 2: Create ResponsiveConfig.swift**

```swift
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
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -5
```

---

### Task 3: Create ResponsiveDesignStore

**Files:**
- Create: `Desire/Features/ResponsiveDesign/ResponsiveDesignStore.swift`

- [ ] **Step 1: Write ResponsiveDesignStore.swift**

```swift
import Combine
import Foundation

@MainActor
class ResponsiveDesignStore: ObservableObject {
    @Published var allPresets: [DevicePreset] = devicePresets
    @Published var customPresets: [DevicePreset] = []

    private let saveKey = "desire.responsiveCustomPresets"

    init() {
        loadCustomPresets()
    }

    func presets(for category: DeviceCategory) -> [DevicePreset] {
        allPresets.filter { $0.category == category }
    }

    func devicePreset(for id: UUID) -> DevicePreset? {
        allPresets.first { $0.id == id }
    }

    func saveCustomPreset(_ preset: DevicePreset) {
        customPresets.append(preset)
        persistCustomPresets()
    }

    func deleteCustomPreset(_ preset: DevicePreset) {
        customPresets.removeAll { $0.id == preset.id }
        persistCustomPresets()
    }

    private func loadCustomPresets() {
        guard let data = UserDefaults.standard.data(forKey: saveKey),
              let presets = try? JSONDecoder().decode([DevicePreset].self, from: data) else { return }
        customPresets = presets
    }

    private func persistCustomPresets() {
        guard let data = try? JSONEncoder().encode(customPresets) else { return }
        UserDefaults.standard.set(data, forKey: saveKey)
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -5
```

---

### Task 4: Migrate Tab to Use ResponsiveConfig

**Files:**
- Modify: `Desire/Features/Tabs/TabManager.swift`
- Modify: `Desire/Views/ContentView.swift`
- Modify: `Desire/Features/AI/BrowserToolProvider.swift`

- [ ] **Step 1: Add `ResponsiveConfig` to Tab, keep old properties as computed**

In `TabManager.swift`, after `@Published var isSuspended = false`, replace:
```swift
@Published var isResponsiveMode = false
@Published var responsiveSize = CGSize(width: 375, height: 667)
```
with:
```swift
@Published var responsiveConfig = ResponsiveConfig()
```

At line 516 in BrowserToolProvider.swift, change `tab.isResponsiveMode.toggle()` to:
```swift
tab.responsiveConfig.isEnabled.toggle()
```

At line 521 in BrowserToolProvider.swift, change the size assignment to:
```swift
tab.responsiveConfig.customWidth = preset.width
tab.responsiveConfig.customHeight = preset.height
```

In ContentView.swift, replace all references:
- `tab.isResponsiveMode` → `tab.responsiveConfig.isEnabled`
- `tab.responsiveSize` → `tab.responsiveConfig.effectiveSize`

Specifically in ContentView.swift around lines 286-291 (the responsive web view frame):
```swift
let responsiveW: CGFloat? = tab.responsiveConfig.isEnabled ? min(tab.responsiveConfig.effectiveSize.width, geo.size.width - 40) : nil
let responsiveH: CGFloat? = tab.responsiveConfig.isEnabled ? min(tab.responsiveConfig.effectiveSize.height, geo.size.height - 40) : nil
makeWebView(for: tab)
    .frame(width: responsiveW, height: responsiveH)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -5
```

---

### Task 5: Enhance ResponsiveDesignBar with Categories + More Presets + Orientation

**Files:**
- Rewrite: `Desire/Features/ResponsiveDesign/ResponsiveDesignBar.swift`

- [ ] **Step 1: Rewrite ResponsiveDesignBar**

```swift
import SwiftUI

struct ResponsiveDesignBar: View {
    @Binding var config: ResponsiveConfig
    let responsiveStore: ResponsiveDesignStore
    @State private var selectedCategory: DeviceCategory = .phone
    @State private var customW = 375
    @State private var customH = 667

    var body: some View {
        HStack(spacing: 8) {
            // Exit button
            Button("← Exit") {
                config.isEnabled = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accentColor)

            Divider().frame(height: 16)

            // Category pills
            ForEach(DeviceCategory.allCases, id: \.self) { cat in
                Button {
                    selectedCategory = cat
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: cat.icon)
                            .font(.system(size: 10))
                        Text(cat.label)
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(selectedCategory == cat ? Color.accentColor.opacity(0.15) : .clear)
                    )
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 16)

            // Device presets for selected category
            let presets = responsiveStore.presets(for: selectedCategory)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(presets) { preset in
                        Button {
                            config.selectedPresetID = preset.id
                            customW = preset.width
                            customH = preset.height
                        } label: {
                            Text(preset.name)
                                .font(.system(size: 11))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: .radiusButton)
                                        .fill(config.selectedPresetID == preset.id ? Color.accentColor.opacity(0.15) : .clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: 200)

            Divider().frame(height: 16)

            // Orientation toggle
            Button {
                config.orientation = config.orientation == .portrait ? .landscape : .portrait
            } label: {
                Image(systemName: config.orientation == .portrait ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Toggle Orientation")

            Divider().frame(height: 16)

            // Custom size fields
            HStack(spacing: 4) {
                TextField("W", value: $customW, format: .number)
                    .textFieldStyle(.plain)
                    .frame(width: 40)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 11))
                Text("×").font(.caption).foregroundStyle(.tertiary)
                TextField("H", value: $customH, format: .number)
                    .textFieldStyle(.plain)
                    .frame(width: 40)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 11))
            }
            .onChange(of: customW) { _, v in
                config.selectedPresetID = nil
                config.customWidth = max(200, v)
            }
            .onChange(of: customH) { _, v in
                config.selectedPresetID = nil
                config.customHeight = max(200, v)
            }

            Text("\(Int(config.effectiveSize.width))×\(Int(config.effectiveSize.height))")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            // Action toggles
            Button {
                config.showRulers.toggle()
            } label: {
                Label("Rulers", systemImage: "ruler")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(config.showRulers ? Color.accentColor : .secondary)

            Button {
                config.touchSimulationEnabled.toggle()
            } label: {
                Label("Touch", systemImage: "hand.point.up")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(config.touchSimulationEnabled ? Color.accentColor : .secondary)

            Button {
                config.showMediaQueryInspector.toggle()
            } label: {
                Label("Media Q", systemImage: "list.bullet.rectangle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(config.showMediaQueryInspector ? Color.accentColor : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear {
            let s = config.effectiveSize
            customW = Int(s.width)
            customH = Int(s.height)
        }
    }
}
```

- [ ] **Step 2: Update ContentView.swift to use new ResponsiveDesignBar**

Replace the current ResponsiveDesignBar usage in ContentView.swift. The current code shows the bar when `tab.isResponsiveMode` is true. Change to use `tab.responsiveConfig.isEnabled` and pass the binding + store:

```swift
if tab.responsiveConfig.isEnabled {
    ResponsiveDesignBar(
        config: $tab.responsiveConfig,
        responsiveStore: responsiveDesignStore
    )
}
```

Add `@StateObject private var responsiveDesignStore = ResponsiveDesignStore()` to ContentView.

- [ ] **Step 3: Build**

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -5
```

---

### Task 6: Create DeviceFrameOverlay

**Files:**
- Create: `Desire/Features/ResponsiveDesign/DeviceFrameOverlay.swift`

- [ ] **Step 1: Write DeviceFrameOverlay.swift (visual only, no gestures)**

```swift
import SwiftUI

struct DeviceFrameOverlay: View {
    let config: ResponsiveConfig
    let viewportSize: CGSize

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let id = config.selectedPresetID,
               let preset = devicePresets.first(where: { $0.id == id }) {
                switch preset.category {
                case .phone:
                    PhoneBezel()
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        .frame(width: viewportSize.width, height: viewportSize.height)
                case .watch:
                    RoundedRectangle(cornerRadius: viewportSize.width / 2)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        .frame(width: viewportSize.width, height: viewportSize.height)
                default:
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        .frame(width: viewportSize.width, height: viewportSize.height)
                }
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    .frame(width: viewportSize.width, height: viewportSize.height)
            }

            Text("\(Int(config.effectiveSize.width))×\(Int(config.effectiveSize.height))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, -18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct PhoneBezel: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.08)
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -5
```

---

### Task 7: Wire DeviceFrameOverlay and Drag Handles into ContentView

**Files:**
- Modify: `Desire/Features/ResponsiveDesign/DeviceFrameOverlay.swift` (clean up)
- Modify: `Desire/Views/ContentView.swift`

- [ ] **Step 1: Write the final DeviceFrameOverlay (clean, separate handle layer)**

```swift
import SwiftUI

struct DeviceFrameOverlay: View {
    let config: ResponsiveConfig
    let viewportSize: CGSize

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let id = config.selectedPresetID,
               let preset = devicePresets.first(where: { $0.id == id }) {
                switch preset.category {
                case .phone:
                    PhoneBezel()
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        .frame(width: viewportSize.width, height: viewportSize.height)
                case .watch:
                    RoundedRectangle(cornerRadius: viewportSize.width / 2)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        .frame(width: viewportSize.width, height: viewportSize.height)
                default:
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        .frame(width: viewportSize.width, height: viewportSize.height)
                }
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    .frame(width: viewportSize.width, height: viewportSize.height)
            }

            Text("\(Int(config.effectiveSize.width))×\(Int(config.effectiveSize.height))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, -18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct PhoneBezel: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.08)
    }
}
```

- [ ] **Step 2: Create DragHandleOverlay.swift (gestures live here, not masked)**

```swift
import SwiftUI

struct DragHandleOverlay: View {
    @Binding var config: ResponsiveConfig
    let viewportSize: CGSize

    private let cornerSize: CGFloat = 10
    private let edgeLength: CGFloat = 24
    private let edgeThickness: CGFloat = 4

    @State private var dragStartW: Int = 0
    @State private var dragStartH: Int = 0

    var body: some View {
        let w = viewportSize.width
        let h = viewportSize.height

        ZStack {
            // Bottom-right corner handle (primary resize)
            ResizeCornerHandle()
                .fill(Color.accentColor)
                .frame(width: cornerSize + 4, height: cornerSize + 4)
                .position(x: w, y: h)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if dragStartW == 0 {
                                dragStartW = config.customWidth
                                dragStartH = config.customHeight
                            }
                            config.selectedPresetID = nil
                            config.customWidth = max(200, dragStartW + Int(value.translation.width))
                            config.customHeight = max(200, dragStartH + Int(value.translation.height))
                        }
                        .onEnded { _ in
                            dragStartW = 0
                            dragStartH = 0
                        }
                )

            // Right edge handle
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor.opacity(0.3))
                .frame(width: edgeThickness, height: edgeLength)
                .position(x: w, y: h / 2)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if dragStartW == 0 {
                                dragStartW = config.customWidth
                            }
                            config.selectedPresetID = nil
                            config.customWidth = max(200, dragStartW + Int(value.translation.width))
                        }
                        .onEnded { _ in
                            dragStartW = 0
                        }
                )

            // Bottom edge handle
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor.opacity(0.3))
                .frame(width: edgeLength, height: edgeThickness)
                .position(x: w / 2, y: h)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if dragStartH == 0 {
                                dragStartH = config.customHeight
                            }
                            config.selectedPresetID = nil
                            config.customHeight = max(200, dragStartH + Int(value.translation.height))
                        }
                        .onEnded { _ in
                            dragStartH = 0
                        }
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ResizeCornerHandle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.minY + 4))
        p.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.maxY - 4))
        p.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 4))
        p.close()
        return p
    }
}
```

- [ ] **Step 3: Add overlays to ContentView**

Around the web view section in ContentView (where the current responsive frame is applied), add:

```swift
// In the if/else block where responsive mode is active:
let effectiveSize = tab.responsiveConfig.effectiveSize
makeWebView(for: tab)
    .frame(width: responsiveW, height: responsiveH)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay {
        if tab.responsiveConfig.isEnabled {
            DeviceFrameOverlay(config: tab.responsiveConfig, viewportSize: effectiveSize)
        }
    }
    .overlay {
        if tab.responsiveConfig.isEnabled {
            DragHandleOverlay(config: $tab.responsiveConfig, viewportSize: effectiveSize)
        }
    }
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -5
```

---

## Phase 2: View Helpers

### Task 8: Create RulerOverlay

**Files:**
- Create: `Desire/Features/ResponsiveDesign/RulerOverlay.swift`

- [ ] **Step 1: Write RulerOverlay.swift**

```swift
import SwiftUI

struct RulerOverlay: View {
    let viewportSize: CGSize

    var body: some View {
        VStack(spacing: 0) {
            // Top ruler
            RulerView(length: viewportSize.width, orientation: .horizontal)
                .frame(height: 16)
            Spacer()
        }
        .overlay(alignment: .leading) {
            RulerView(length: viewportSize.height, orientation: .vertical)
                .frame(width: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct RulerView: View {
    let length: CGFloat
    let orientation: Axis

    private let tickInterval: CGFloat = 50

    var body: some View {
        Canvas { context, size in
            let total = orientation == .horizontal ? size.width : size.height
            let majorInterval = tickInterval
            let tickCount = Int(total / majorInterval)

            for i in 0...tickCount {
                let pos = CGFloat(i) * majorInterval
                if orientation == .horizontal {
                    context.stroke(
                        Path { p in
                            p.move(to: CGPoint(x: pos, y: 0))
                            p.addLine(to: CGPoint(x: pos, y: i % 2 == 0 ? 12 : 6))
                        },
                        with: .color(.tertiary),
                        lineWidth: 0.5
                    )
                    if i % 2 == 0 {
                        context.draw(
                            Text("\(i * 50)").font(.system(size: 7)).foregroundColor(.tertiary),
                            at: CGPoint(x: pos + 2, y: 14)
                        )
                    }
                } else {
                    context.stroke(
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: pos))
                            p.addLine(to: CGPoint(x: i % 2 == 0 ? 12 : 6, y: pos))
                        },
                        with: .color(.tertiary),
                        lineWidth: 0.5
                    )
                    if i % 2 == 0 {
                        context.draw(
                            Text("\(i * 50)").font(.system(size: 7)).foregroundColor(.tertiary),
                            at: CGPoint(x: 14, y: pos + 2)
                        )
                    }
                }
            }
        }
        .frame(
            width: orientation == .horizontal ? length : 16,
            height: orientation == .horizontal ? 16 : length
        )
    }
}
```

- [ ] **Step 2: Wire into ContentView**

Add overlay conditionally in the web view section:
```swift
.overlay {
    if tab.responsiveConfig.isEnabled && tab.responsiveConfig.showRulers {
        RulerOverlay(viewportSize: effectiveSize)
    }
}
```

- [ ] **Step 3: Build**

---

### Task 9: Add Touch Simulation JS Injection

**Files:**
- Create: `Desire/Features/ResponsiveDesign/TouchSimulation.swift`
- Modify: `Desire/Views/ContentView.swift`

- [ ] **Step 1: Write TouchSimulation.swift**

```swift
import WebKit

enum TouchSimulation {
    static let css = "* { cursor: crosshair !important; touch-action: none; -webkit-touch-callout: none; user-select: none; }"

    static let js = """
    (function() {
        if (window._desireTouchSimActive) return;
        window._desireTouchSimActive = true;

        function createRipple(x, y) {
            const dot = document.createElement('div');
            dot.style.cssText = 'position:fixed;pointer-events:none;z-index:99999;width:40px;height:40px;border-radius:50%;background:rgba(0,122,255,0.3);border:2px solid rgba(0,122,255,0.6);transform:translate(-50%,-50%);left:'+x+'px;top:'+y+'px;animation:desireRipple 0.6s ease-out forwards;';
            document.body.appendChild(dot);
            setTimeout(() => dot.remove(), 600);
        }

        // Inject animation keyframes
        const style = document.createElement('style');
        style.textContent = '@keyframes desireRipple { 0% { transform: translate(-50%,-50%) scale(0.5); opacity:1; } 100% { transform: translate(-50%,-50%) scale(1.5); opacity:0; } }';
        document.head.appendChild(style);

        document.addEventListener('mousedown', e => {
            const touch = new Touch({ identifier: Date.now(), target: e.target, clientX: e.clientX, clientY: e.clientY });
            const event = new TouchEvent('touchstart', { cancelable: true, bubbles: true, touches: [touch], targetTouches: [touch], changedTouches: [touch] });
            e.target.dispatchEvent(event);
            createRipple(e.clientX, e.clientY);
        }, true);

        document.addEventListener('mousemove', e => {
            if (e.buttons === 0) return;
            const touch = new Touch({ identifier: Date.now(), target: e.target, clientX: e.clientX, clientY: e.clientY });
            const event = new TouchEvent('touchmove', { cancelable: true, bubbles: true, touches: [touch], targetTouches: [touch], changedTouches: [touch] });
            e.target.dispatchEvent(event);
        }, true);

        document.addEventListener('mouseup', e => {
            const touch = new Touch({ identifier: Date.now(), target: e.target, clientX: e.clientX, clientY: e.clientY });
            const event = new TouchEvent('touchend', { cancelable: true, bubbles: true, touches: [], targetTouches: [], changedTouches: [touch] });
            e.target.dispatchEvent(event);
        }, true);
    })();
    """

    static let revertJS = """
    window._desireTouchSimActive = false;
    """

    static func apply(to webView: WKWebView) {
        let cssInject = "var s = document.createElement('style'); s.textContent = '\(css)'; document.head.appendChild(s);"
        webView.evaluateJavaScript(cssInject, completionHandler: nil)
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    static func remove(from webView: WKWebView) {
        webView.evaluateJavaScript(revertJS, completionHandler: nil)
    }
}
```

- [ ] **Step 2: Wire into ContentView**

Observe `tab.responsiveConfig.touchSimulationEnabled` and apply/remove JS:

```swift
.onChange(of: tab.responsiveConfig.touchSimulationEnabled) { _, enabled in
    if enabled {
        TouchSimulation.apply(to: tab.browser.webView)
    } else {
        TouchSimulation.remove(from: tab.browser.webView)
    }
}
```

- [ ] **Step 3: Build**

---

### Task 10: Add Viewport Screenshot

**Files:**
- Modify: `Desire/Features/ResponsiveDesign/ResponsiveDesignBar.swift`
- Modify: `Desire/Views/ContentView.swift`

- [ ] **Step 1: Add screenshot action to bar (add callback)**

Add a `onScreenshot: () -> Void` closure to ResponsiveDesignBar.

- [ ] **Step 2: Implement screenshot logic in ContentView**

Use WKWebView `takeSnapshot`:
```swift
func captureViewportScreenshot(for tab: Tab) {
    let config = WKSnapshotConfiguration()
    config.rect = CGRect(origin: .zero, size: tab.responsiveConfig.effectiveSize)
    tab.browser.webView.takeSnapshot(with: config) { image, error in
        guard let image else { return }
        // Save to Downloads or clipboard
    }
}
```

- [ ] **Step 3: Build**

---

## Phase 3: Developer Tools

### Task 11: Create MediaQueryInspector

**Files:**
- Create: `Desire/Features/ResponsiveDesign/MediaQueryInspector.swift`
- Modify: `Desire/Views/ContentView.swift`

- [ ] **Step 1: Write MediaQueryInspector.swift**

```swift
import SwiftUI
import WebKit

struct MediaQueryInspector: View {
    let queries: [MediaQueryItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Media Queries")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            Divider()

            if queries.isEmpty {
                Text("No media queries found")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(10)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(queries) { item in
                        HStack {
                            Circle()
                                .fill(item.isActive ? Color.green : Color.gray.opacity(0.4))
                                .frame(width: 6, height: 6)
                            Text(item.query)
                                .font(.system(size: 10))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
        }
        .frame(width: 220)
        .background(.bar)
        .cornerRadius(6)
    }
}

struct MediaQueryItem: Identifiable {
    let id = UUID()
    let query: String
    let isActive: Bool
}

// JS to extract media queries
let mediaQueryExtractorJS = """
(function() {
    const rules = [];
    try {
        for (const sheet of document.styleSheets) {
            try {
                for (const rule of sheet.cssRules) {
                    if (rule.media && rule.media.mediaText) {
                        rules.push({
                            query: rule.media.mediaText,
                            active: window.matchMedia(rule.media.mediaText).matches
                        });
                    }
                }
            } catch(e) {}
        }
    } catch(e) {}
    return rules;
})();
"""
```

- [ ] **Step 2: Wire into ContentView with JS evaluation**

Observe `config.showMediaQueryInspector` and fetch media queries:
```swift
@State private var mediaQueries: [MediaQueryItem] = []

// When inspector opens:
tab.browser.webView.evaluateJavaScript(mediaQueryExtractorJS) { result, error in
    if let rules = result as? [[String: Any]] {
        mediaQueries = rules.map { MediaQueryItem(query: $0["query"] as? String ?? "", isActive: $0["active"] as? Bool ?? false) }
    }
}
```

- [ ] **Step 3: Build**

---

### Task 12: Network Throttling Simulation

**Files:**
- Create: `Desire/Features/ResponsiveDesign/NetworkThrottleURLProtocol.swift`
- Modify: `Desire/Views/ContentView.swift`

- [ ] **Step 1: Write NetworkThrottleURLProtocol**

```swift
import WebKit

class NetworkThrottleURLProtocol: URLProtocol {
    static var throttlePreset: ThrottlePreset = .none

    override class func canInit(with request: URLRequest) -> Bool {
        throttlePreset != .none
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let preset = Self.throttlePreset
        switch preset {
        case .none:
            // Should not reach here
            forwardRequest()
        case .slow3G:
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                self.forwardRequest()
            }
        case .fast3G:
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                self.forwardRequest()
            }
        case .offline:
            let error = NSError(domain: "DesireNetwork", code: -1009, userInfo: [NSLocalizedDescriptionKey: "Simulated offline mode"])
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func forwardRequest() {
        // In production, this would use a real URLSession to forward.
        // For now, just pass through.
        let error = NSError(domain: "DesireNetwork", code: -1, userInfo: [NSLocalizedDescriptionKey: "Throttle passthrough"])
        client?.urlProtocol(self, didFailWithError: error)
    }
}
```

- [ ] **Step 2: Register protocol in App setup**

Register `NetworkThrottleURLProtocol` in WKWebView configuration when throttle is active. Since WKWebView uses its own URL loading system, URLProtocol registration has limited effect. A simpler approach: show a visual indicator that throttling is "simulated" and advise real device testing.

For now, implement as a visual-only indicator:
```swift
// In ContentView, when throttle changes:
.showThrottleBanner(tab.responsiveConfig.networkThrottle)
```

- [ ] **Step 3: Build**

---

## Build & Verify

- [ ] **Final: Full build**

```bash
xcodebuild -project Desire.xcodeproj -scheme Desire build 2>&1 | tail -10
```
