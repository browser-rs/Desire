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

            if let sel = selection, !sel.isEmpty {
                let truncated = sel.count > 30 ? String(sel.prefix(30)) + "…" : sel
                let search = NSMenuItem(title: String(localized: "Search “\(truncated)”"), action: #selector(self.searchSelection), keyEquivalent: "")
                search.target = self
                search.representedObject = sel
                menu.addItem(.separator())
                menu.addItem(search)
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

    @objc private func searchSelection(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        onSearchText?(text)
    }

    @objc private func openLinkInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenLinkInNewTab?(url)
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
        guard let inspector = value(forKey: "_inspector") as? NSObject else { return }
        inspector.perform(Selector(("show")))
    }
}
