import Foundation

/// 内置页面路由（v0.8.27）：`desire://tools[/<tool>]` 在标签内渲染工具集合。
/// 地址栏、桥 `/navigate` `/new-tab`、系统 open URL 与菜单命令共用这一处解析。
@MainActor
enum InternalPages {
    struct Destination: Equatable {
        var urlString: String
        var toolID: String?
    }

    /// 解析内置 URL；非内置页面返回 nil（调用方继续走正常导航）。
    static func parse(_ raw: String?) -> Destination? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "desire",
              url.host?.lowercased() == "tools" else { return nil }
        let tool = url.pathComponents.dropFirst().first?.lowercased()
        let canonical = "desire://tools" + (tool.map { "/\($0)" } ?? "")
        return Destination(urlString: canonical, toolID: tool)
    }

    /// 在标签内打开工具页（关闭其它查看器状态）。
    static func open(_ destination: Destination, in tab: Tab) {
        tab.browser.closeAllViewers()
        tab.isOnNewTabPage = false
        tab.isOnToolsPage = true
        tab.toolsPageSelection = destination.toolID
        tab.urlString = destination.urlString
        let title = String(localized: "Toolbox")
        tab.displayTitle = title
        tab.browser.pageTitle = title
    }

    static func close(in tab: Tab) {
        tab.isOnToolsPage = false
        tab.toolsPageSelection = nil
    }
}

extension BrowserState {
    /// 关闭所有"查看器/阅读模式"覆盖层（工具页与普通导航前调用）。
    func closeAllViewers() {
        pdfViewerURL = nil
        pdfViewerSourceKey = nil
        pdfViewerReturnURL = nil
        mediaViewerURL = nil
        spreadsheetViewerURL = nil
        imageEditorURL = nil
        archiveViewerURL = nil
        documentViewerURL = nil
        jsonViewerURL = nil
        presentationViewerURL = nil
        isReadingMode = false
        isReaderLoading = false
        isPDFLoading = false
    }
}
