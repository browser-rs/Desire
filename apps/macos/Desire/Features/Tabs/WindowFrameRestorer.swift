import AppKit
import os

/// 窗口 frame 还原（v0.8.52 批 1）：窗口挂载后按快照设置位置/尺寸。
///
/// 时序（实测 2026-11-11）：SwiftUI 建窗后要过一会儿才 attach NSWindow；
/// **多窗同时建窗时它还会在 ~1s 处自己做一次级联排列**——只设一次会被覆盖
/// 回去（E2E 实测两窗都回到默认级联位）。所以这里持有真实 NSWindow 引用
/// （由窗口标记在同一次挂载里给出，不靠 sessionKey 反查注册表），在 4 秒
/// 窗口内持续校正，一旦一致就收手（不跟用户的窗口拖动抢）。
@MainActor
enum WindowFrameRestorer {
    static func apply(window: NSWindow, sessionKey: String,
                      frame: WindowFrame?, cascade: Int = 0) {
        guard let frame else { return }
        Task { @MainActor in
            var applied = 0
            for attempt in 0..<7 {
                try? await Task.sleep(for: .milliseconds(300 + attempt * 150))
                let screens = NSScreen.screens.map { screen -> WindowFrame in
                    let visible = screen.visibleFrame
                    return WindowFrame(x: visible.origin.x, y: visible.origin.y,
                                       width: visible.size.width, height: visible.size.height)
                }
                let clamped = WindowRestoreCore.clampedFrame(
                    frame, screens: screens, cascadeIndex: cascade)
                let target = NSRect(x: clamped.x, y: clamped.y,
                                    width: clamped.width, height: clamped.height)
                let current = window.frame
                let matches = abs(current.origin.x - target.origin.x) <= 1
                    && abs(current.origin.y - target.origin.y) <= 1
                    && abs(current.size.width - target.size.width) <= 1
                    && abs(current.size.height - target.size.height) <= 1
                if matches {
                    if applied > 0 {
                        Log.tabs.info("window-restore: frame settled for \(sessionKey, privacy: .public) after \(applied, privacy: .public) apply(ies)")
                    }
                    return
                }
                window.setFrame(target, display: true)
                applied += 1
            }
            if applied > 0 {
                Log.tabs.fault("window-restore: frame for \(sessionKey, privacy: .public) kept being reset (\(applied, privacy: .public) applies)")
            }
        }
    }
}
