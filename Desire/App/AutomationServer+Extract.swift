import Foundation
import WebKit

/// Structured extraction (0.1.11): page tables/lists as JSON or CSV.
/// Deterministic selector mode; the AI-guided mode is the in-app agent
/// combining executeJs + writeFile. Kept in an extension of AutomationServer
/// so the route table and its helpers live together.
extension AutomationServer {

    // MARK: Network interception (0.1.13)

    static func interceptRules() -> [String: Any] {
        ["rules": InterceptStore.shared.rules.map { r -> [String: Any] in
            ["id": r.id.uuidString, "urlFilter": r.urlFilter, "kind": r.kind.rawValue,
             "payload": r.payload ?? "", "enabled": r.isEnabled]
        }]
    }

    static func addInterceptRule(urlFilter: String, kind: String, payload: String?) -> [String: Any] {
        guard let ruleKind = InterceptRule.Kind(rawValue: kind) else {
            return ["error": "kind must be block | redirect"]
        }
        guard let rule = InterceptStore.shared.add(urlFilter: urlFilter, kind: ruleKind, payload: payload) else {
            return ["error": ruleKind == .redirect ? "redirect needs payload url" : "invalid urlFilter"]
        }
        return ["ok": true, "id": rule.id.uuidString]
    }

    static func removeInterceptRule(id: String) -> [String: Any] {
        guard let uuid = UUID(uuidString: id) else { return ["error": "bad id"] }
        InterceptStore.shared.remove(id: uuid)
        return ["ok": true]
    }

    static func clearInterceptRules() -> [String: Any] {
        InterceptStore.shared.clear()
        return ["ok": true]
    }

    /// 0.1.14 — rule recording: turn observed network requests into block
    /// rules. `patternSubstring` filters URLs; count caps the result.
    static func recordInterceptRules(patternSubstring: String, limit: Int) -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let requests = app.devToolsStore.networkRequests
        let matched = requests
            .compactMap { $0.url.isEmpty ? nil : URL(string: $0.url) }
            .filter { url in
                guard !url.absoluteString.contains("127.0.0.1:8877"),
                      !url.absoluteString.contains("127.0.0.1:8799") else { return false }
                return url.absoluteString.lowercased().contains(patternSubstring.lowercased())
            }
        var added = 0
        var skipped = 0
        for url in matched.prefix(max(1, limit)) {
            let filter = "*\(url.host ?? url.absoluteString)*"
            if InterceptStore.shared.rules.contains(where: { $0.urlFilter == filter }) {
                skipped += 1
                continue
            }
            InterceptStore.shared.add(urlFilter: filter, kind: .block, payload: nil)
            added += 1
        }
        return ["ok": true, "observed": requests.count, "matched": matched.count,
                "added": added, "skippedDuplicates": skipped]
    }

    static func extract(kind: String, selector: String?, format: String, index: Int?) async throws -> [String: Any] {
        guard let tab = shared.resolveIndex(index) else { return ["error": "no such tab"] }
        let js: String
        switch kind {
        case "list": js = Self.extractListJS(selector: selector)
        case "table", "tables": js = Self.extractTablesJS(selector: selector)
        default: return ["error": "kind must be table | list"]
        }
        let raw: String = await withCheckedContinuation { continuation in
            tab.browser.webView.evaluateJavaScript(js) { result, _ in
                continuation.resume(returning: (result as? String) ?? "{}")
            }
        }
        guard let data = raw.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ["error": "extraction failed"]
        }
        if format == "csv" {
            guard let tables = payload["tables"] as? [[String: Any]], !tables.isEmpty else {
                return ["error": "no tables for csv"]
            }
            return ["format": "csv", "csv": Self.csv(fromTables: tables)]
        }
        return payload
    }

    /// All `<table>`s as {headers, rows}; a selector narrows to one table
    /// (must match a `<table>`); rows capped at 1000 per table, 20 tables.
    static func extractTablesJS(selector: String?) -> String {
        let scope: String
        if let selector {
            let escaped = selector
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            scope = "var scope = document.querySelector('\(escaped)'); if (!scope) return JSON.stringify({count: 0, tables: [], note: 'selector not found'});"
        } else {
            scope = "var scope = document;"
        }
        return """
        (function() {
          \(scope)
          var tables = (scope.tagName === 'TABLE' ? [scope] : Array.from(scope.querySelectorAll('table')));
          var out = tables.slice(0, 20).map(function(t, ti) {
            var headers = Array.from(t.querySelectorAll('thead th, thead td')).map(function(c) { return c.innerText.trim(); });
            var bodyRows = t.querySelectorAll('tbody tr').length ? Array.from(t.querySelectorAll('tbody tr')) : Array.from(t.querySelectorAll('tr'));
            var rows = bodyRows.slice(0, 1000).map(function(tr) {
              return Array.from(tr.querySelectorAll('th,td')).map(function(c) { return c.innerText.trim(); });
            });
            if (headers.length) rows = rows.filter(function(r) { return !(r.length === headers.length && r.every(function(c, i) { return c === headers[i]; })); });
            return { table: ti + 1, headers: headers.length ? headers : (rows[0] || []).map(function(_, i) { return 'col' + (i + 1); }), rows: rows, truncated: bodyRows.length > 1000 };
          });
          return JSON.stringify({count: out.length, tables: out});
        })()
        """
    }

    /// List items as {text, href} — a selector picks the item elements;
    /// default is all ul/ol li. Capped at 1000.
    static func extractListJS(selector: String?) -> String {
        let listSelector: String
        if let selector {
            let escaped = selector
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            listSelector = "var els = document.querySelectorAll('\(escaped)');"
        } else {
            listSelector = "var els = document.querySelectorAll('ul li, ol li');"
        }
        return """
        (function() {
          \(listSelector)
          var items = Array.from(els).slice(0, 1000).map(function(el) {
            var a = el.querySelector('a[href]');
            return { text: (el.innerText || el.textContent || '').trim().substring(0, 500), href: a ? a.href : null };
          }).filter(function(it) { return it.text.length > 0; });
          return JSON.stringify({count: items.length, items: items, truncated: els.length > 1000});
        })()
        """
    }

    private static func csv(fromTables tables: [[String: Any]]) -> String {
        var out: [String] = []
        for (i, table) in tables.enumerated() {
            let headers = table["headers"] as? [String] ?? []
            let rows = table["rows"] as? [[String]] ?? []
            if tables.count > 1 { out.append("# table \(i + 1)") }
            if !headers.isEmpty { out.append(csvLine(headers)) }
            rows.forEach { out.append(csvLine($0)) }
        }
        return out.joined(separator: "\n")
    }

    private static func csvLine(_ fields: [String]) -> String {
        fields.map { field in
            if field.contains(",") || field.contains("\"") || field.contains("\n") {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }.joined(separator: ",")
    }
}
