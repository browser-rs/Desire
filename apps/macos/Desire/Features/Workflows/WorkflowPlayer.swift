import Foundation
import WebKit

/// 工作流回放器（v0.7.29）：**不调用模型**，按步骤在给定 webview 里执行
/// 点击/输入/选择/导航，并逐步收集成败。敏感值只存在于本次运行的内存里。
@MainActor
enum WorkflowPlayer {
    struct StepResult {
        let index: Int
        let kind: Workflow.Step.Kind
        let ok: Bool
        let message: String
    }

    struct RunResult {
        let ok: Bool
        let results: [StepResult]
    }

    static func run(_ workflow: Workflow, values: [UUID: String],
                    in webView: WKWebView) async -> RunResult {
        let steps = WorkflowLogic.stepsForReplay(workflow, values: values)
        // 从录制起点开始（第一步本身就是 navigate 时由它负责）。
        if steps.first?.kind != .navigate,
           let start = URL(string: workflow.startURL),
           webView.url?.absoluteString != workflow.startURL {
            webView.load(URLRequest(url: start))
            _ = await waitForLoad(webView)
        }
        var results: [StepResult] = []
        for (index, step) in steps.enumerated() {
            let (ok, message) = await perform(step, index: index, in: webView)
            results.append(StepResult(index: index, kind: step.kind, ok: ok, message: message))
            if !ok { break }
            try? await Task.sleep(for: .milliseconds(120))
        }
        let runResult = RunResult(ok: results.allSatisfy(\.ok) && results.count == steps.count,
                                  results: results)
        // 审计（v0.8.1）：工作流回放不可撤销，但必须留一条记录。
        AgentActionStore.shared.record(
            tool: "runWorkflow",
            kind: .workflowRun,
            summary: "Workflow \"\(workflow.name)\" on \(workflow.host): \(runResult.ok ? "ok" : "failed")",
            host: workflow.host)
        return runResult
    }

    // MARK: - 单步

    private static func perform(_ step: Workflow.Step, index: Int,
                                in webView: WKWebView) async -> (Bool, String) {
        switch step.kind {
        case .navigate:
            guard let raw = step.url, let url = URL(string: raw) else { return (false, "invalid URL") }
            if webView.url?.absoluteString == raw { return (true, "already there") }
            webView.load(URLRequest(url: url))
            let loaded = await waitForLoad(webView)
            return loaded ? (true, "navigated") : (false, "navigation timed out")
        case .waitFor:
            let found = await waitForElement(webView, selectors: step.selectors, timeout: 10)
            return found ? (true, "appeared") : (false, "element did not appear")
        case .click, .input, .select, .key:
            let script = script(for: step)
            do {
                let value = try await webView.evaluateJavaScript(script)
                let text = (value as? String) ?? "\(value ?? "")"
                return text.hasPrefix("ok") ? (true, text) : (false, text)
            } catch {
                return (false, "JS error: \(error.localizedDescription)")
            }
        }
    }

    /// 生成步骤脚本：候选选择器按顺序尝试；`text:` 走可见文本匹配。
    private static func script(for step: Workflow.Step) -> String {
        let selectors = jsLiteral(step.selectors)
        let value = jsLiteral(step.value ?? "")
        switch step.kind {
        case .click:
            return """
            (function(){
              var sels = \(selectors);
              function pick() {
                for (var i=0;i<sels.length;i++) {
                  var s = sels[i];
                  if (s.indexOf('text:') === 0) {
                    var needle = s.slice(5).trim();
                    var nodes = document.querySelectorAll('a,button,[role=button],input[type=submit],[type=button]');
                    for (var j=0;j<nodes.length;j++) {
                      var t = (nodes[j].innerText || nodes[j].textContent || '').replace(/\\s+/g,' ').trim();
                      if (t === needle || (t && t.indexOf(needle) >= 0)) { return nodes[j]; }
                    }
                  } else {
                    try { var el = document.querySelector(s); if (el) { return el; } } catch(e) {}
                  }
                }
                return null;
              }
              var el = pick();
              if (!el) { return 'not found'; }
              el.scrollIntoView({block:'center'});
              try { el.click(); } catch(e) { return 'click failed: ' + e; }
              return 'ok';
            })();
            """
        case .input, .select:
            return """
            (function(){
              var sels = \(selectors);
              var v = \(value);
              function pick() {
                for (var i=0;i<sels.length;i++) {
                  if (sels[i].indexOf('text:') === 0) { continue; }
                  try { var el = document.querySelector(sels[i]); if (el) { return el; } } catch(e) {}
                }
                return null;
              }
              var el = pick();
              if (!el) { return 'not found'; }
              el.scrollIntoView({block:'center'});
              el.focus();
              var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype
                        : (el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype);
              try {
                var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
                setter.call(el, v);
              } catch(e) { el.value = v; }
              el.dispatchEvent(new Event('input', {bubbles:true}));
              el.dispatchEvent(new Event('change', {bubbles:true}));
              return 'ok';
            })();
            """
        case .key:
            return """
            (function(){
              var sels = \(selectors);
              function pick() {
                for (var i=0;i<sels.length;i++) {
                  if (sels[i].indexOf('text:') === 0) { continue; }
                  try { var el = document.querySelector(sels[i]); if (el) { return el; } } catch(e) {}
                }
                return null;
              }
              var el = pick() || document.activeElement || document.body;
              var ev = new KeyboardEvent('keydown', {key: \(value), bubbles:true});
              el.dispatchEvent(ev);
              el.dispatchEvent(new KeyboardEvent('keyup', {key: \(value), bubbles:true}));
              return 'ok';
            })();
            """
        case .navigate, .waitFor:
            return "ok"
        }
    }

    /// JSON 编码成 JS 字面量（选择器数组/字符串；避免手拼引号）。
    /// **不要用 JSONSerialization**：裸 String 作顶层对象会抛
    /// NSInvalidArgumentException，ObjC 异常穿进 async 帧会让主 actor 僵尸化。
    private static func jsLiteral(_ value: String) -> String {
        encodeLiteral(value)
    }

    private static func jsLiteral(_ value: [String]) -> String {
        encodeLiteral(value)
    }

    private static func encodeLiteral<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    private static func waitForLoad(_ webView: WKWebView, timeout: TimeInterval = 20) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        // 给导航一点起步时间（load 刚调用时 isLoading 可能还是 false）。
        try? await Task.sleep(for: .milliseconds(300))
        while Date() < end {
            let ready = (try? await webView.evaluateJavaScript("document.readyState")) as? String
            if !webView.isLoading, ready == "complete" { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private static func waitForElement(_ webView: WKWebView, selectors: [String],
                                       timeout: TimeInterval) async -> Bool {
        let sels = jsLiteral(selectors)
        let check = """
        (function(){
          var sels = \(sels);
          for (var i=0;i<sels.length;i++) {
            if (sels[i].indexOf('text:') === 0) { continue; }
            try { if (document.querySelector(sels[i])) { return true; } } catch(e) {}
          }
          return false;
        })();
        """
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if (try? await webView.evaluateJavaScript(check)) as? Bool == true { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }
}
