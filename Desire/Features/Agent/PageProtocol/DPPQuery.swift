import Foundation

/// DPP 选择器辅助（注入页面的 JS）。
///
/// WebKit 的 `querySelectorAll` 不穿透 shadow boundary，而现代 Web Components
/// 站点把关键 DOM 藏在 shadow root 里。协议选择器支持 **`>>>` 穿透语法**：
/// 按段拆分、逐段下钻 `shadowRoot`（`"app-grid >>> product-card >>> .price"`）。
///
/// 用法：生成的工具 JS 开头先拼 `DPPQuery.helperJS`（幂等，只装一次），
/// 之后用 `__desireQueryAll(sel)` / `__desireQueryOne(el, sel)` 代替
/// `document.querySelectorAll` / `el.querySelector`。
/// 无 `>>>` 的选择器走原语义（含抛错吞掉→空数组，与 querySelectorAll 一致地
/// 由调用方决定怎么处理空结果）。
enum DPPQuery {
    static let helperJS = """
    (function(){
      if (window.__desireQueryAll) return;
      function qAll(root, sel){ return Array.prototype.slice.call(root.querySelectorAll(sel)); }
      // 同源 iframe 递归收集（跨源 contentDocument 访问抛错→跳过）。
      // 跨源 frame 需要宿主 frame API（未实装）。
      function collectDocs(doc, depth){
        var docs = [doc];
        if (depth <= 0) return docs;
        var frames = doc.querySelectorAll('iframe');
        for (var i = 0; i < frames.length; i++) {
          try {
            var d = frames[i].contentDocument;
            if (d) docs = docs.concat(collectDocs(d, depth - 1));
          } catch (e) {}
        }
        return docs;
      }
      window.__desireQueryAll = function(selector){
        var docs = collectDocs(document, 2);
        if (selector.indexOf('>>>') === -1) {
          var out = [];
          for (var d = 0; d < docs.length; d++) {
            try { out = out.concat(qAll(docs[d], selector)); } catch (e) {}
          }
          return out;
        }
        var segs = selector.split('>>>').map(function(s){ return s.trim(); });
        var cur = [];
        for (var d = 0; d < docs.length; d++) {
          try { cur = cur.concat(qAll(docs[d], segs[0])); } catch (e) {}
        }
        for (var i = 1; i < segs.length; i++) {
          var next = [];
          cur.forEach(function(el){
            if (el.shadowRoot) next = next.concat(qAll(el.shadowRoot, segs[i]));
            else if (el.contentDocument) next = next.concat(qAll(el.contentDocument, segs[i]));
          });
          cur = next;
        }
        return cur;
      };
      window.__desireQueryOne = function(el, selector){
        if (selector.indexOf('>>>') === -1) {
          try { return el.querySelector(selector); } catch (e) { return null; }
        }
        var segs = selector.split('>>>').map(function(s){ return s.trim(); });
        // 前导 '>>>' = 从 el 自己的 shadowRoot 开始（字段相对 item 的写法）
        var start = 0;
        var cur;
        if (segs[0] === '') { cur = [el]; start = 1; }
        else { cur = qAll(el, segs[0]); }
        for (var i = start; i < segs.length; i++) {
          var next = [];
          cur.forEach(function(host){
            var root = i === 0 ? host : (host.shadowRoot || host.contentDocument);
            if (root) next = next.concat(qAll(root, segs[i]));
          });
          cur = next;
        }
        return cur[0] || null;
      };
    })();
    """
}
