import Foundation
import WebKit

/// 列表 → 表格采集器（v0.8.2）：在离屏 webview 里按选择器确定性抓行，
/// 翻页/滚动可选，去重后写 CSV。不逐行调模型；产物进 Jobs 并给回执。
@MainActor
enum DatasetCollector {
    struct Result {
        let ok: Bool
        let rowCount: Int
        let pageCount: Int
        let path: String?
        let errors: [String]
        let jobID: UUID
    }

    static func collect(_ spec: DatasetSpec, fileName: String? = nil) async -> Result {
        let jobID = JobStore.shared.start(
            title: "Collect table: \(URL(string: spec.startURL)?.host ?? spec.startURL)",
            kind: .dataset,
            detail: "\(spec.fields.count) field(s) · \(spec.pagination.rawValue)",
            source: "operations")
        guard let start = URL(string: spec.startURL) else {
            JobStore.shared.finish(jobID, state: .failed, error: "invalid start URL")
            return Result(ok: false, rowCount: 0, pageCount: 0, path: nil,
                          errors: ["invalid start URL"], jobID: jobID)
        }
        guard !spec.fields.isEmpty, !spec.rowSelector.isEmpty else {
            JobStore.shared.finish(jobID, state: .failed,
                                   error: "row selector and fields are required")
            return Result(ok: false, rowCount: 0, pageCount: 0, path: nil,
                          errors: ["missing selector/fields"], jobID: jobID)
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = BrowserState._desktopSafariUA

        var rows: [[String: String]] = []
        var errors: [String] = []
        var pages = 0
        var lastCount = 0

        for page in 1...spec.maxPages {
            if page == 1 {
                webView.load(URLRequest(url: start))
                guard await waitReady(webView) else {
                    errors.append("page 1: did not finish loading")
                    break
                }
            } else {
                switch spec.pagination {
                case .none:
                    break
                case .urlTemplate:
                    guard let next = DatasetSpec.pageURL(spec.urlTemplate, page: page),
                          let url = URL(string: next) else {
                        errors.append("page \(page): urlTemplate missing {page}")
                        break
                    }
                    webView.load(URLRequest(url: url))
                    guard await waitReady(webView) else {
                        errors.append("page \(page): did not finish loading")
                        break
                    }
                case .nextButton:
                    guard let selector = spec.nextSelector, !selector.isEmpty else {
                        errors.append("page \(page): nextSelector missing")
                        break
                    }
                    let clicked = await clickNext(webView, selector: selector)
                    guard clicked else { break }
                    _ = await waitReady(webView, timeout: 12)
                case .scroll:
                    _ = await scrollToBottom(webView)
                    try? await Task.sleep(for: .milliseconds(900))
                }
            }
            if page > 1, spec.pagination == .none { break }

            let pageRows = await extract(webView, spec: spec)
            if pageRows.isEmpty { break }
            pages += 1
            rows += pageRows
            JobStore.shared.update(jobID, detail: "page \(pages) · \(rows.count) row(s)",
                                   progress: Double(min(rows.count, spec.maxRows)) / Double(spec.maxRows))
            if rows.count >= spec.maxRows { break }
            if spec.pagination == .scroll, pageRows.count == lastCount { break }
            lastCount = pageRows.count
        }

        let deduped = DatasetSpec.dedupe(rows, key: spec.dedupeKey)
        let capped = Array(deduped.prefix(spec.maxRows))
        guard !capped.isEmpty else {
            JobStore.shared.finish(jobID, state: .failed,
                                   error: errors.isEmpty ? "no rows matched the selectors" : errors.joined(separator: "; "))
            return Result(ok: false, rowCount: 0, pageCount: pages, path: nil,
                          errors: errors.isEmpty ? ["no rows matched"] : errors,
                          jobID: jobID)
        }
        let csv = DatasetSpec.csv(rows: capped, fields: spec.fields)
        let folder = FileManager.default.urls(for: .downloadsDirectory,
                                              in: .userDomainMask)[0]
        let base = (fileName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "dataset-\(stamp())"
        let name = base.lowercased().hasSuffix(".csv") ? base : base + ".csv"
        let target = FilePathing.uniqueURL(in: folder, for: name)
        do {
            try csv.write(to: target, atomically: true, encoding: .utf8)
        } catch {
            JobStore.shared.finish(jobID, state: .failed,
                                   error: "write failed: \(error.localizedDescription)")
            return Result(ok: false, rowCount: capped.count, pageCount: pages,
                          path: nil, errors: errors + ["write failed"], jobID: jobID)
        }
        let receipt = "Collected \(capped.count) row(s) from \(pages) page(s)"
            + (errors.isEmpty ? "" : " · \(errors.count) issue(s)")
        JobStore.shared.finish(jobID, state: .done, receipt: receipt,
                               artifactURL: target.path)
        return Result(ok: true, rowCount: capped.count, pageCount: pages,
                      path: target.path, errors: errors, jobID: jobID)
    }

    // MARK: - JS

    private static func extract(_ webView: WKWebView,
                                spec: DatasetSpec) async -> [[String: String]] {
        let rowLiteral = JSString.literal(spec.rowSelector)
        let fieldsLiteral: String = {
            let payload = spec.fields.map { ["key": $0.key, "selector": $0.selector] }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let text = String(data: data, encoding: .utf8) else { return "[]" }
            return text
        }()
        let script = """
        (function(){
          var out = [];
          var fields = \(fieldsLiteral);
          var nodes;
          try { nodes = document.querySelectorAll(\(rowLiteral)); }
          catch (e) { return JSON.stringify({rows: [], error: String(e)}); }
          for (var i = 0; i < nodes.length; i++) {
            var n = nodes[i];
            var row = {};
            for (var j = 0; j < fields.length; j++) {
              var f = fields[j];
              var el = null;
              try { el = n.querySelector(f.selector); } catch (e) {}
              row[f.key] = el ? ((el.innerText || el.textContent || '').trim()) : '';
            }
            out.push(row);
          }
          return JSON.stringify({rows: out});
        })();
        """
        let value = try? await webView.evaluateJavaScript(script)
        guard let raw = value as? String,
              let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = parsed["rows"] as? [[String: Any]] else {
            return []
        }
        return rows.map { row in
            row.reduce(into: [String: String]()) { result, pair in
                result[pair.key] = (pair.value as? String) ?? "\(pair.value)"
            }
        }
    }

    private static func clickNext(_ webView: WKWebView, selector: String) async -> Bool {
        let script = """
        (function(){
          var el = null;
          try { el = document.querySelector(\(JSString.literal(selector))); } catch (e) {}
          if (!el) { return false; }
          el.scrollIntoView({block: 'center'});
          try { el.click(); } catch (e) { return false; }
          return true;
        })();
        """
        let value = try? await webView.evaluateJavaScript(script)
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
    }

    private static func scrollToBottom(_ webView: WKWebView) async -> Int {
        let value = try? await webView.evaluateJavaScript(
            "window.scrollTo(0, document.body.scrollHeight); document.querySelectorAll('*').length;")
        return (value as? NSNumber)?.intValue ?? 0
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    private static func waitReady(_ webView: WKWebView,
                                  timeout: TimeInterval = 20) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(300))
        while Date() < end {
            let ready = (try? await webView.evaluateJavaScript("document.readyState")) as? String
            if !webView.isLoading, ready == "complete" { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }
}
