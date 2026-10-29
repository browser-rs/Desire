import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
class BrowserWKWebView: WKWebView {
    /// 文件拖入（v0.8.22）：网页自己处理的拖放（上传/排序）优先——`super`
    /// 返回 true 就完全不插手；只有 WebKit 没接的才算"拖进浏览器"，交给宿主
    /// 开新标签。
    var onFilesDropped: (([URL]) -> Void)?
    /// 刚拖入的文件（短窗口）：WebKit 若试图在主框架导航到它，policy 层据此
    /// 拦截并改开新标签（只匹配这几个文件，不影响站点自己的 file:// 导航）。
    var droppedFileURLs: [URL] = []
    /// 上一次 `draggingEntered/Updated` 里 WebKit 自己是否接受了这次文件拖放
    /// （= 页面的 drop zone / file input 接得住）。只有它接受了才把 drop 交给
    /// `super`——它拒绝时硬调 `performDragOperation` 属于未定义用法。
    private var superAcceptsFileDrag = false

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let base = super.draggingEntered(sender)
        guard !Self.fileURLs(from: sender).isEmpty else {
            superAcceptsFileDrag = false
            return base
        }
        superAcceptsFileDrag = !base.isEmpty
        return base.isEmpty ? .copy : base
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let base = super.draggingUpdated(sender)
        guard !Self.fileURLs(from: sender).isEmpty else {
            superAcceptsFileDrag = false
            return base
        }
        superAcceptsFileDrag = !base.isEmpty
        return base.isEmpty ? .copy : base
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        superAcceptsFileDrag = false
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(from: sender)
        if !urls.isEmpty {
            droppedFileURLs = urls
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.droppedFileURLs = []
            }
        }
        if superAcceptsFileDrag, super.performDragOperation(sender) {
            // 网页接住了这次拖放（文件上传、拖拽排序、drop zone）。
            superAcceptsFileDrag = false
            return true
        }
        superAcceptsFileDrag = false
        if urls.isEmpty {
            // 拖 URL / 文本进页面（v0.8.23，Safari 语义）：页面自己没接住才轮到
            // 宿主——URL 开新标签，纯文本按默认引擎搜索；页面内的拖放不受影响
            //（super 接受的分支已在上面返回）。
            guard let raw = sender.draggingPasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return false
            }
            if let url = Self.webURL(from: raw) {
                onOpenLinkInNewTab?(url)
            } else {
                onSearchText?(raw)
            }
            return true
        }
        droppedFileURLs = []
        onFilesDropped?(urls)
        return true
    }

    /// 把拖入的字符串解析成 http(s) URL（裸域名补 https）；不是链接返回 nil。
    private static func webURL(from raw: String) -> URL? {
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }
        let compact = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.contains(" "), compact.contains("."), !compact.hasPrefix(".") else {
            return nil
        }
        return URL(string: "https://" + compact)
    }

    private static func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                           options: options) ?? []
        return objects.compactMap { $0 as? URL }
    }

    var onOpenLinkInNewTab: ((URL) -> Void)?
    var onSearchText: ((String) -> Void)?
    /// Opens `url` in a new tab bound to `container` (isolated cookies) —
    /// wired by ContentView to TabManager.addTab.
    var onOpenInContainer: ((URL, TabContainer) -> Void)?
    /// 所属标签页（DevToolsRecorder 的归属依据，0.7.5）——Tab.init 创建
    /// 后立刻设置；rebuildWebView 换新视图时从旧视图带过去。
    var devToolsTabID: UUID?

    /// **后台也要收得到合成点击**（v25 根因修复）：应用非活动时，AppKit
    /// 会把落在非 key 窗口上的鼠标事件当"激活点击"消费掉——`SyntheticInput`
    /// 用 `NSApp.sendEvent` 投递的真实事件因此静默消失（实测：应用后台时
    /// 拖拽/点按/下载触发 4/4 全败、前台 4/4 全过；定时/后台回合的智能体
    /// 点击在用户正用别的应用时同样会丢）。浏览器惯例 = 非活动窗口的首次
    /// 点击**既激活也投递**，这里就按这个口径放行（不抢焦点、不激活应用）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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

            // 收藏此页到摘录（v0.8.20 基础件 5）：标题+URL+（选区或页面
            // 描述）快收——与划词摘录同一去向（ExcerptStore）。
            let clipItem = NSMenuItem(
                title: String(localized: "Save Page to Excerpts"),
                action: #selector(self.savePageToExcerpts(_:)), keyEquivalent: "")
            clipItem.target = self
            clipItem.representedObject = [
                "url": url?.absoluteString ?? "",
                "content": selection ?? "",
            ]
            if menu.item(withTag: 0xBEEF) == nil {
                clipItem.tag = 0xBEEF
                menu.insertItem(clipItem, at: 0)
            }

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

    /// 收藏此页到摘录（v0.8.20 基础件 5）：representableObject 携带 url 与
    /// 选中文本（可空）；标题/正文兜底取 document.title / meta description。
    @objc private func savePageToExcerpts(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let pageURL = info["url"], !pageURL.isEmpty else { return }
        let selection = info["content"] ?? ""
        let js = """
        JSON.stringify({
          title: document.title,
          content: \(selection.isEmpty ? "null" : "JSON.stringify(\(JSString.literal(selection)))")
            || document.querySelector('meta[name=description]')?.content || ''
        })
        """
        evaluateJavaScript(js) { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
            let content = obj["content"] ?? ""
            guard !content.isEmpty else { return }
            ExcerptStore.shared.add(kind: .webSelection,
                                    title: obj["title"] ?? "",
                                    source: pageURL,
                                    content: content)
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
