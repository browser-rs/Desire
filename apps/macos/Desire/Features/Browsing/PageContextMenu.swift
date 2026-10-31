import AppKit
import Foundation

/// 右键增强宿主菜单（v0.8.31 批次一）：注入脚本拦下图片/链接/选区的原生
/// 菜单并上报目标，这里组 NSMenu 在鼠标处弹出。
/// - 图片：用 Desire 编辑（下载进图片编辑器）/ 反向搜索四引擎 / 新标签打开 / 复制地址
/// - 链接：复制为 Markdown / 新标签打开 / 复制链接地址
/// - 选区：复制为 Markdown（[选区](页面地址)）
@MainActor
enum PageContextMenu {

    struct Info {
        var imageUrl: String
        var linkUrl: String
        var linkText: String
        var selection: String
        var screenX: Double
        var screenY: Double
        var pageUrl: String

        var hasImage: Bool { !imageUrl.isEmpty }
        var hasLink: Bool { !linkUrl.isEmpty }
        var hasSelection: Bool { !selection.isEmpty }
    }

    /// 反向搜索引擎（名称 + 上传 URL 模板，%@ = 转义后的图片地址）。
    static let reverseEngines: [(String, String)] = [
        ("Google Lens", "https://lens.google.com/uploadbyurl?url=%@"),
        ("Bing Visual", "https://www.bing.com/images/search?q=imgurl:%@&view=detailv2&iss=sbi"),
        ("Yandex", "https://yandex.com/images/search?rpt=imageview&url=%@"),
        ("SauceNAO", "https://saucenao.com/search.php?url=%@"),
    ]

    // MARK: - 弹出

    static func show(_ info: Info) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if info.hasImage {
            menu.addItem(item(String(localized: "Edit with Desire"), action: {
                editImage(urlString: info.imageUrl, pageURLString: info.pageUrl)
            }))
            let search = NSMenu(title: String(localized: "Reverse Search"))
            for (name, template) in reverseEngines {
                search.addItem(item(name) {
                    openInNewTab(template.replacingOccurrences(
                        of: "%@",
                        with: URL(string: info.imageUrl)?.absoluteString
                            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))
                })
            }
            let searchItem = NSMenuItem(title: String(localized: "Reverse Search"), action: nil, keyEquivalent: "")
            searchItem.submenu = search
            menu.addItem(searchItem)
            menu.addItem(.separator())
            menu.addItem(item(String(localized: "Open Image in New Tab")) {
                openInNewTab(info.imageUrl)
            })
            menu.addItem(item(String(localized: "Copy Image Address")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(info.imageUrl, forType: .string)
            })
        } else if info.hasLink {
            menu.addItem(item(String(localized: "Copy Link as Markdown")) {
                let text = info.linkText.isEmpty
                    ? (URL(string: info.linkUrl)?.host ?? info.linkUrl)
                    : info.linkText
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("[\(text)](\(info.linkUrl))", forType: .string)
            })
            menu.addItem(item(String(localized: "Open Link in New Tab")) {
                openInNewTab(info.linkUrl)
            })
            menu.addItem(item(String(localized: "Copy Link Address")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(info.linkUrl, forType: .string)
            })
        } else if info.hasSelection {
            menu.addItem(item(String(localized: "Copy Selection as Markdown")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    "[\(info.selection)](\(info.pageUrl))", forType: .string)
            })
        } else {
            return
        }

        menu.popUp(positioning: nil, at: NSPoint(x: info.screenX, y: info.screenY), in: nil)
    }

    private static func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: #selector(MenuTarget.run(_:)), keyEquivalent: "")
        menuItem.target = MenuTarget.shared
        menuItem.representedObject = action
        menuItem.isEnabled = true
        return menuItem
    }

    /// NSMenuItem action 蹩脚桥：representedObject 挂闭包，单 target 统一执行。
    final class MenuTarget: NSObject {
        static let shared = MenuTarget()
        @objc func run(_ sender: NSMenuItem) {
            (sender.representedObject as? (() -> Void))?()
        }
    }

    // MARK: - 动作

    private static func openInNewTab(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        TabSessionCoordinator.shared.activeTabManager?.addTab(url: url.absoluteString)
    }

    /// 图片下载进图片编辑器：带页面 referer（防盗链站点），落临时目录。
    private static func editImage(urlString: String, pageURLString: String) {
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        if let page = URL(string: pageURLString) {
            request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
            request.setValue(page.host ?? "", forHTTPHeaderField: "Origin")
        }
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data, let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode), !data.isEmpty else {
                DispatchQueue.main.async { toast(String(localized: "Could not download this image")) }
                return
            }
            let ext = inferExtension(data: data, response: response)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("desire-edit-\(UUID().uuidString).\(ext)")
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                DispatchQueue.main.async { toast(error.localizedDescription) }
                return
            }
            DispatchQueue.main.async {
                guard let manager = TabSessionCoordinator.shared.activeTabManager,
                      let tab = manager.selectedTab else { return }
                tab.browser.imageEditorURL = destination
                tab.browser.imageEditorFileName = url.lastPathComponent.isEmpty
                    ? destination.lastPathComponent : url.lastPathComponent
                RecentLocalFiles.record(url: destination)
            }
        }.resume()
    }

    private nonisolated static func inferExtension(data: Data, response: URLResponse?) -> String {
        if let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") {
            if mime.contains("png") { return "png" }
            if mime.contains("webp") { return "webp" }
            if mime.contains("gif") { return "gif" }
        }
        if data.starts(with: Data([0x89, 0x50, 0x4E, 0x47])) { return "png" }
        if data.starts(with: Data([0xFF, 0xD8])) { return "jpg" }
        if data.starts(with: Data([0x47, 0x49, 0x46])) { return "gif" }
        if data.count > 12, data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 { return "webp" }
        return "png"
    }

    /// 失败提示：悬浮球 toast 是既有的全局瞬态通道（AgentBallPanel.actionToast）。
    private static func toast(_ message: String) {
        Task { @MainActor in
            AgentBallPanel.shared.flashToast(message)
        }
    }
}
