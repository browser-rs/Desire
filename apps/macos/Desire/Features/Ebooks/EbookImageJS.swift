import Foundation

/// 正文图片点击（v0.8.36）：把图片 src 与屏幕矩形交给 Swift 打开查看器。
nonisolated enum EbookImageJS {
    static func script() -> String {
        """
        (function(){
          document.addEventListener('click',function(e){
            var t=e.target;
            while(t&&t!==document){
              if(t.tagName==='IMG'){
                var src=t.getAttribute('src')||'';
                if(!src)return;
                var r=t.getBoundingClientRect();
                if(r.width<40||r.height<40)return;
                e.preventDefault();
                e.stopPropagation();
                if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.ebookImage){
                  window.webkit.messageHandlers.ebookImage.postMessage({
                    src:src,x:r.left,y:r.top,w:r.width,h:r.height
                  });
                }
                return;
              }
              t=t.parentElement;
            }
          },true);
        })();
        """
    }
}
