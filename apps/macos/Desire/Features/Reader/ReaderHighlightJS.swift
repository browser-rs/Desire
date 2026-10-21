import Foundation

/// 阅读视图里的高亮脚本（v0.7.29）。全部通过 `evaluateJavaScript` 调用，
/// 不额外注册 message handler。
nonisolated enum ReaderHighlightJS {
    /// 返回选中文本 + 前后文（JSON 字符串；无选区返回空串）。
    static let selectedAnchor = """
    (function(){
      var sel = window.getSelection();
      if (!sel || sel.isCollapsed || sel.rangeCount === 0) { return ""; }
      var quote = sel.toString();
      if (!quote || !quote.trim()) { return ""; }
      var body = document.body ? (document.body.innerText || "") : "";
      var idx = body.indexOf(quote);
      var prefix = "", suffix = "";
      if (idx >= 0) {
        prefix = body.slice(Math.max(0, idx - 40), idx);
        suffix = body.slice(idx + quote.length, idx + quote.length + 40);
      }
      return JSON.stringify({quote: quote.trim(), prefix: prefix, suffix: suffix});
    })();
    """

    /// 清除旧 mark 后按 quote/prefix/suffix 重新包裹；返回成功条数。
    static func applyScript(highlightsJSON: String) -> String {
        """
        (function(list){
          function clear() {
            document.querySelectorAll('mark[data-desire-highlight]').forEach(function(m){
              var t = document.createTextNode(m.textContent);
              m.parentNode.replaceChild(t, m);
            });
            if (document.body) { document.body.normalize(); }
          }
          function textNodes() {
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
            var out = [], node;
            while ((node = walker.nextNode())) {
              if (node.nodeValue && node.parentElement
                  && !/^(SCRIPT|STYLE)$/.test(node.parentElement.tagName)) {
                out.push(node);
              }
            }
            return out;
          }
          function wrapOne(item) {
            var nodes = textNodes();
            var full = nodes.map(function(n){ return n.nodeValue; }).join('');
            var start = -1;
            if (item.prefix || item.suffix) {
              var withCtx = item.prefix + item.quote + item.suffix;
              var idx = full.indexOf(withCtx);
              if (idx >= 0) { start = idx + item.prefix.length; }
            }
            if (start < 0 && item.prefix) {
              var p = full.indexOf(item.prefix + item.quote);
              if (p >= 0) { start = p + item.prefix.length; }
            }
            if (start < 0) { start = full.indexOf(item.quote); }
            if (start < 0) { return false; }
            var end = start + item.quote.length;
            var offset = 0, startNode = null, startOff = 0, endNode = null, endOff = 0;
            for (var i = 0; i < nodes.length; i++) {
              var len = nodes[i].nodeValue.length;
              if (!startNode && start >= offset && start <= offset + len) {
                startNode = nodes[i]; startOff = start - offset;
              }
              if (!endNode && end >= offset && end <= offset + len) {
                endNode = nodes[i]; endOff = end - offset;
              }
              offset += len;
            }
            if (!startNode || !endNode) { return false; }
            try {
              var range = document.createRange();
              range.setStart(startNode, startOff);
              range.setEnd(endNode, endOff);
              var mark = document.createElement('mark');
              mark.setAttribute('data-desire-highlight', item.id);
              mark.style.backgroundColor = item.color;
              mark.style.color = 'inherit';
              mark.style.borderRadius = '2px';
              var fragment = range.extractContents();
              mark.appendChild(fragment);
              range.insertNode(mark);
              return true;
            } catch (e) {
              return false;
            }
          }
          clear();
          var applied = 0;
          for (var i = 0; i < list.length; i++) {
            if (wrapOne(list[i])) { applied++; }
          }
          return applied;
        })(\(highlightsJSON));
        """
    }

    static func scrollScript(idJSON: String) -> String {
        """
        (function(){
          var mark = document.querySelector('mark[data-desire-highlight="' + \(idJSON) + '"]');
          if (mark) { mark.scrollIntoView({block:'center'}); return true; }
          return false;
        })();
        """
    }
}
