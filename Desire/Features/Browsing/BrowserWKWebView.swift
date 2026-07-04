import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
class BrowserWKWebView: WKWebView {
    var onOpenLinkInNewTab: ((URL) -> Void)?

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
            return JSON.stringify({
                imageUrl: img ? img.src : null,
                linkUrl: link ? link.href : null,
                bgImageUrl: bg && bg.startsWith('url(') ? bg.slice(4, -1).replace(/['"]/g, '') : null
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

            if let url = imageURL ?? bgImageURL {
                let save = NSMenuItem(title: "保存图片", action: #selector(self.saveImage), keyEquivalent: "")
                save.target = self
                save.representedObject = url
                menu.addItem(save)

                let copyURL = NSMenuItem(title: "复制图片地址", action: #selector(self.copyImageURL), keyEquivalent: "")
                copyURL.target = self
                copyURL.representedObject = url
                menu.addItem(copyURL)

                let copyImage = NSMenuItem(title: "复制图片", action: #selector(self.copyImage), keyEquivalent: "")
                copyImage.target = self
                copyImage.representedObject = url
                menu.addItem(copyImage)
            }

            if let url = linkURL {
                if imageURL != nil || bgImageURL != nil { menu.addItem(.separator()) }
                let open = NSMenuItem(title: "在新标签页中打开链接", action: #selector(self.openLinkInNewTab), keyEquivalent: "")
                open.target = self
                open.representedObject = url
                menu.addItem(open)

                let copyLink = NSMenuItem(title: "复制链接地址", action: #selector(self.copyLinkURL), keyEquivalent: "")
                copyLink.target = self
                copyLink.representedObject = url
                menu.addItem(copyLink)
            }
        }
    }

    @objc private func openLinkInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenLinkInNewTab?(url)
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
