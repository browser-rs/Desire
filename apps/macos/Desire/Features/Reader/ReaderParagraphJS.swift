import Foundation

/// 逐段朗读的段落脚本（v0.8.43）。与高亮脚本同一模式：`evaluateJavaScript`
/// 直调，不注册 message handler。段落索引 = 打标记时的 DOM 顺序，
/// 朗读段落与页面元素因此一一对应（plainText 拆行做不到这点）。
nonisolated enum ReaderParagraphJS {
    /// 给正文块元素按 DOM 顺序打 `data-desire-para` 标记（重打前清旧标记），
    /// 返回段落文本 JSON 数组。含块级子元素的容器（嵌套列表/引用块）跳过，
    /// 由子块自己成段，避免外层 innerText 把内层文本重复一遍。
    /// 顺带注入当前段落高亮的样式（黄色淡底，与主题明暗都兼容）。
    static let tagScript = """
    (function(){
      var selector = 'p,h1,h2,h3,h4,h5,h6,li,blockquote,pre,figcaption';
      if (!document.getElementById('desire-para-style')) {
        var style = document.createElement('style');
        style.id = 'desire-para-style';
        style.textContent = '.desire-para-active{background:rgba(255,204,0,0.24);border-radius:4px;}';
        (document.head || document.documentElement).appendChild(style);
      }
      document.querySelectorAll('[data-desire-para]').forEach(function(el){
        el.removeAttribute('data-desire-para');
        el.classList.remove('desire-para-active');
      });
      var blocks = Array.prototype.slice.call(document.body.querySelectorAll(selector));
      var texts = [];
      blocks.forEach(function(el){
        if (el.querySelector(selector)) { return; }
        var text = (el.innerText || '').replace(/\\s+/g, ' ').trim();
        if (!text) { return; }
        el.setAttribute('data-desire-para', String(texts.length));
        texts.push(text);
      });
      return JSON.stringify(texts);
    })();
    """

    /// 高亮指定段落并滚动到视口中央（朗读跟随）。
    /// 朗读中途改字号/主题会重建 webview，旧标记丢失——此脚本静默无操作，
    /// 语音继续，不中断。
    static func scrollScript(index: Int) -> String {
        """
        (function(){
          document.querySelectorAll('.desire-para-active').forEach(function(el){
            el.classList.remove('desire-para-active');
          });
          var el = document.querySelector('[data-desire-para="\(index)"]');
          if (!el) { return; }
          el.classList.add('desire-para-active');
          el.scrollIntoView({behavior: 'smooth', block: 'center'});
        })();
        """
    }
}
