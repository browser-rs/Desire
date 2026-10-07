import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
class BrowserWKWebView: WKWebView {
    var onOpenLinkInNewTab: ((URL) -> Void)?
    var onSearchText: ((String) -> Void)?
    /// Opens `url` in a new tab bound to `container` (isolated cookies) —
    /// wired by ContentView to TabManager.addTab.
    var onOpenInContainer: ((URL, TabContainer) -> Void)?
    /// 所属标签页（DevToolsRecorder 的归属依据，0.7.5）——Tab.init 创建
    /// 后立刻设置；rebuildWebView 换新视图时从旧视图带过去。
    var devToolsTabID: UUID?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        let point = convert(event.locationInWindow, from: nil)
        let x = Int(point.x), y = Int(point.y)
        let js = """
        (function() {
            var el = document.elementFromPoint(\(x), \(y));
            var img = el.closest('img');
            var link = el.closest('a');
            var bg = window.getComputedStyle(el).backgroundImage;
            var sel = window.getSelection().toString().trim();
            return JSON.stringify({
                imageUrl: img ? img.src : null,
                linkUrl: link ? link.href : null,
                bgImageUrl: bg && bg.startsWith('url(') ? bg.slice(4, -1).replace(/['"]/g, '') : null,
                selection: sel.length > 0 ? sel.substring(0, 200) : null
            });
        })()
        """
        evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let json = result as? String,
                  let data = json.data(using: .utf8),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }

            let imageURL = info["imageUrl"].flatMap(URL.init)
            let linkURL = info["linkUrl"].flatMap(URL.init)
            let bgImageURL = info["bgImageUrl"].flatMap(URL.init)
            let selection = info["selection"]

            // 视频速度（0.6.5）：子菜单步进，接管值经 video-speed.js 应用到
            // 当前与未来媒体元素；对无视频页面同样可用（pre-armed）。
            let speedItem = NSMenuItem(title: String(localized: "Video Speed"), action: nil, keyEquivalent: "")
            let speedMenu = NSMenu()
            for rate in [0.5, 1.0, 1.25, 1.5, 2.0, 3.0] {
                let mi = NSMenuItem(title: String(format: "%.2gx", rate), action: #selector(self.setVideoSpeed(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = rate
                speedMenu.addItem(mi)
            }
            speedItem.submenu = speedMenu
            menu.addItem(speedItem)

            if let sel = selection, !sel.isEmpty {
                let truncated = sel.count > 30 ? String(sel.prefix(30)) + "…" : sel
                let search = NSMenuItem(title: String(localized: "Search “\(truncated)”"), action: #selector(self.searchSelection), keyEquivalent: "")
                search.target = self
                search.representedObject = sel
                menu.addItem(.separator())
                menu.addItem(search)

                // 选区 → 白板（note 块，带来源 URL；§三期）
                let board = NSMenuItem(title: String(localized: "Add to Whiteboard"), action: #selector(self.addSelectionToWhiteboard(_:)), keyEquivalent: "")
                board.target = self
                board.representedObject = sel
                menu.addItem(board)
            }

            if let url = imageURL ?? bgImageURL {
                menu.addItem(.separator())
                let save = NSMenuItem(title: String(localized: "Save Image"), action: #selector(self.saveImage), keyEquivalent: "")
                save.target = self
                save.representedObject = url
                menu.addItem(save)

                let copyURL = NSMenuItem(title: String(localized: "Copy Image URL"), action: #selector(self.copyImageURL), keyEquivalent: "")
                copyURL.target = self
                copyURL.representedObject = url
                menu.addItem(copyURL)

                let copyImage = NSMenuItem(title: String(localized: "Copy Image"), action: #selector(self.copyImage), keyEquivalent: "")
                copyImage.target = self
                copyImage.representedObject = url
                menu.addItem(copyImage)
            }

            // 插件 contextMenus 项（R2 归一后续）：按当前上下文匹配
            //（page 恒真 / link / image / selection），点击派发给所属插件的
            // background。
            let pluginMenus = PluginBackgroundRuntime.shared.contextMenus(for: self.url)
                .filter { item in
                    item.contexts.contains { ctx in
                        switch ctx {
                        case "page": return true
                        case "link": return linkURL != nil
                        case "image": return imageURL != nil || bgImageURL != nil
                        case "selection": return selection != nil
                        default: return false
                        }
                    }
                }
            if !pluginMenus.isEmpty {
                menu.addItem(.separator())
                for item in pluginMenus {
                    let mi = NSMenuItem(title: item.title, action: #selector(self.runPluginContextMenuItem(_:)), keyEquivalent: "")
                    mi.target = self
                    let payload: [String: String] = [
                        "pluginID": item.pluginID.uuidString,
                        "menuID": item.menuID,
                        "linkURL": linkURL?.absoluteString ?? "",
                        "imageURL": (imageURL ?? bgImageURL)?.absoluteString ?? "",
                        "selection": selection ?? "",
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: payload),
                       let json = String(data: data, encoding: .utf8) {
                        mi.representedObject = json
                    }
                    menu.addItem(mi)
                }
            }

            if let url = linkURL {
                if imageURL != nil || bgImageURL != nil { menu.addItem(.separator()) }
                let open = NSMenuItem(title: String(localized: "Open Link in New Tab"), action: #selector(self.openLinkInNewTab), keyEquivalent: "")
                open.target = self
                open.representedObject = url
                menu.addItem(open)

                let copyLink = NSMenuItem(title: String(localized: "Copy Link URL"), action: #selector(self.copyLinkURL), keyEquivalent: "")
                copyLink.target = self
                copyLink.representedObject = url
                menu.addItem(copyLink)

                // Open this link inside a container tab (isolated cookies).
                let containers = ContainerStore.shared.containers
                if !containers.isEmpty {
                    let containerItem = NSMenuItem(title: String(localized: "Open in Container"), action: nil, keyEquivalent: "")
                    let submenu = NSMenu()
                    for container in containers {
                        let item = NSMenuItem(
                            title: container.name,
                            action: #selector(self.openLinkInContainer(_:)),
                            keyEquivalent: ""
                        )
                        item.target = self
                        item.representedObject = "\(container.id.uuidString)|\(url.absoluteString)"
                        submenu.addItem(item)
                    }
                    containerItem.submenu = submenu
                    menu.addItem(containerItem)
                }
            }
        }
    }

    @objc private func setVideoSpeed(_ sender: NSMenuItem) {
        guard let rate = sender.representedObject as? Double else { return }
        evaluateJavaScript(
            "window.__desireVideoSpeed && window.__desireVideoSpeed.set(\(rate))",
            completionHandler: nil)
    }

    @objc private func searchSelection(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        onSearchText?(text)
    }

    /// 选区 → 白板 note 块（带来源标注），面板自动弹出。
    @objc private func addSelectionToWhiteboard(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, !text.isEmpty else { return }
        let source = "— 来自 \(url?.host ?? "网页")（\(url?.absoluteString.prefix(140) ?? "")）"
        let content = text + "\n\n" + source
        WhiteboardStore.shared.append(
            [WhiteboardBlock(type: WhiteboardBlock.Kind.note,
                             title: String(localized: "网页选区"),
                             content: String(content.prefix(2200)))],
            title: nil,
            conversationID: AgentScheduler.shared.deliveryTarget?.conversationId?.uuidString)
        WhiteboardPanel.shared.show()
    }

    @objc private func openLinkInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenLinkInNewTab?(url)
    }

    /// 插件 contextMenus 项点击 → 派发给所属插件的 background。
    @objc private func runPluginContextMenuItem(_ sender: NSMenuItem) {
        guard let json = sender.representedObject as? String,
              let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let pluginID = payload["pluginID"].flatMap(UUID.init),
              let menuID = payload["menuID"] else { return }
        PluginBackgroundRuntime.shared.contextMenuClick(
            pluginID: pluginID, menuItemID: menuID,
            pageURL: url,
            linkURL: payload["linkURL"].flatMap(URL.init),
            srcURL: payload["imageURL"].flatMap(URL.init),
            selectionText: payload["selection"])
    }

    @objc private func openLinkInContainer(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? String else { return }
        let parts = payload.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let containerID = UUID(uuidString: String(parts[0])),
              let container = ContainerStore.shared.container(for: containerID),
              let url = URL(string: String(parts[1])) else { return }
        onOpenInContainer?(url, container)
    }

    @objc private func saveImage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let task = URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data, error == nil else { return }
            DispatchQueue.main.async {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = url.lastPathComponent
                panel.allowedContentTypes = [.image]
                guard panel.runModal() == .OK, let targetURL = panel.url else { return }
                try? data.write(to: targetURL)
            }
        }
        task.resume()
    }

    @objc private func copyImageURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func copyImage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
        }
        task.resume()
    }

    @objc private func copyLinkURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func requestInspector() {
        // KVC 防护（CONC-4）：`value(forKey: "_inspector")` 是私有键，某版 macOS
        // 一旦移除即抛 NSUnknownKeyException 直接 abort（2026-09-20 崩溃同型；
        // ObjC 异常穿 async 帧还会把主 actor 变僵尸）。responds(to:) 先探——
        // 私有属性有合成 getter，键消失时这里安全返回 false。
        let inspectorKey = Selector(("_inspector"))
        guard responds(to: inspectorKey),
              let inspector = value(forKey: "_inspector") as? NSObject else { return }
        let show = Selector(("show"))
        if inspector.responds(to: show) {
            inspector.perform(show)
        }
    }
}
