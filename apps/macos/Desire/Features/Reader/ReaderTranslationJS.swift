import Foundation

/// 阅读模式整页译文注入（v0.8.43）：把译文作为块内 `<span>` 追加到已打
/// `data-desire-para` 标记的段落（标记由 `ReaderParagraphJS.tagScript` 负责，
/// 逐段朗读共用同一条），译文成块显示在原段之后。全部 `evaluateJavaScript`
/// 直调，不注册 message handler。
nonisolated enum ReaderTranslationJS {

    private struct Payload: Encodable {
        let block: Int
        let text: String
    }

    static func payload(_ translations: [Int: String]) -> String {
        let items = translations.sorted { $0.key < $1.key }
            .map { Payload(block: $0.key, text: $0.value) }
        guard let data = try? JSONEncoder().encode(items),
              var json = String(data: data, encoding: .utf8) else { return "[]" }
        json = json.replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return json
    }

    /// 注入/回填译文（增量安全：已存在的译文 span 先移除再插）。
    static func applyScript(payload: String) -> String {
        """
        (function(list){
          if (!document.getElementById('desire-translation-style')) {
            var style = document.createElement('style');
            style.id = 'desire-translation-style';
            style.textContent = '.desire-translation{display:block;margin-top:0.35em;'
              + 'opacity:0.82;font-size:0.92em;border-top:1px solid rgba(128,128,128,0.25);'
              + 'padding-top:0.25em;}'
              + '.desire-translation-hidden .desire-translation{display:none;}';
            (document.head || document.documentElement).appendChild(style);
          }
          if (document.body) { document.body.classList.remove('desire-translation-hidden'); }
          for (var i = 0; i < list.length; i++) {
            var el = document.querySelector('[data-desire-para="' + list[i].block + '"]');
            if (!el) { continue; }
            var old = el.querySelector('.desire-translation');
            if (old) { old.remove(); }
            var span = document.createElement('span');
            span.className = 'desire-translation';
            span.setAttribute('data-desire-translation', String(list[i].block));
            span.textContent = list[i].text;
            el.appendChild(span);
          }
        })(\(payload));
        """
    }

    /// 只切可见性（缓存保留，再次显示零开销）。
    static func hiddenScript(_ hidden: Bool) -> String {
        """
        (function(){
          if (document.body) {
            document.body.classList.toggle('desire-translation-hidden', \(hidden ? "true" : "false"));
          }
        })();
        """
    }

    static let removeScript = """
    (function(){
      document.querySelectorAll('.desire-translation').forEach(function(el){ el.remove(); });
    })();
    """
}
