import Combine
import Foundation

/// 下载 popover 的独立展示状态（v0.7.30）。
///
/// 此前绑在 `AppState.showDownloadsPanel`（@Published）上——每次打开/关闭都会
/// 让整个 ContentView（含 WKWebView representable）重绘，用户实测"下载窗口
/// 弹出卡顿"。收成独立单例后只有 Toolbar/下载按钮观察它；桥 `/panel` 与
/// `.showDownloads` 命令也走这里。
@MainActor
final class DownloadsPresentation: ObservableObject {
    static let shared = DownloadsPresentation()

    @Published var isPresented = false

    private init() {}
}
