import Foundation

/// 书内高亮注入脚本（v0.8.35）。锚点用章节内文本偏移（UTF-16），
/// quote 只在偏移缺失/失效时兜底；每次分页重建后由分页脚本重新调用。
nonisolated enum EbookHighlightJS {

    private struct Payload: Encodable {
        let id: String
        let start: Int
        let end: Int
        let quote: String
        let bg: String
    }

    /// 当前章高亮 → JS 可嵌入的 JSON 数组字面量。
    static func payload(_ highlights: [EbookHighlight]) -> String {
        let items = highlights.map { highlight in
            Payload(id: highlight.id.uuidString.lowercased(),
                    start: highlight.startOffset,
                    end: highlight.endOffset,
                    quote: highlight.quote,
                    bg: highlight.color.backgroundCSS)
        }
        guard let data = try? JSONEncoder().encode(items),
              var json = String(data: data, encoding: .utf8) else { return "[]" }
        json = json.replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return json
    }

    /// 注入到阅读 HTML 的脚本体（调用方负责包 `<script>`）。
    static func script(_ highlights: [EbookHighlight]) -> String {
        """
        (function(){
          window.__desireHighlightData = \(payload(highlights));
          function root(){
            return document.getElementById('desire-flow') || document.body;
          }
          function textNodes(){
            var r=root();
            if(!r)return [];
            var walker=document.createTreeWalker(r,NodeFilter.SHOW_TEXT,null);
            var out=[],n;
            while(n=walker.nextNode()){
              var p=n.parentElement;
              if(p&&(p.tagName==='SCRIPT'||p.tagName==='STYLE'))continue;
              out.push(n);
            }
            return out;
          }
          function clearMarks(){
            var marks=document.querySelectorAll('mark[data-ebook-highlight]');
            for(var i=0;i<marks.length;i++){
              var m=marks[i],parent=m.parentNode;
              if(!parent)continue;
              parent.replaceChild(document.createTextNode(m.textContent),m);
            }
            var r=root();
            if(r&&r.normalize)r.normalize();
          }
          function wrapSpan(node,start,end,id,bg){
            if(start<0||end<=start||end>(node.nodeValue?node.nodeValue.length:0))return false;
            try{
              var range=document.createRange();
              range.setStart(node,start);
              range.setEnd(node,end);
              var mark=document.createElement('mark');
              mark.setAttribute('data-ebook-highlight',id);
              mark.style.background=bg;
              mark.style.color='inherit';
              mark.style.borderRadius='2px';
              range.surroundContents(mark);
              return true;
            }catch(e){return false;}
          }
          function wrapOffsets(h){
            var s=h.start,e=h.end;
            if(!(s>=0&&e>s))return false;
            var nodes=textNodes(),acc=0,any=false;
            for(var i=0;i<nodes.length;i++){
              var n=nodes[i],len=n.nodeValue?n.nodeValue.length:0;
              if(s<acc+len&&e>acc){
                var a=Math.max(s-acc,0),b=Math.min(e-acc,len);
                if(a<b&&wrapSpan(n,a,b,h.id,h.bg))any=true;
              }
              acc+=len;
            }
            return any;
          }
          function wrapQuote(h){
            var q=h.quote||'';
            if(!q)return false;
            var nodes=textNodes(),full='';
            for(var i=0;i<nodes.length;i++)full+=nodes[i].nodeValue||'';
            var idx=full.indexOf(q);
            if(idx<0)return false;
            return wrapOffsets({id:h.id,bg:h.bg,start:idx,end:idx+q.length});
          }
          window.__desireSelectionOffsets=function(range){
            var r=root();
            if(!r||!range||!r.contains(range.startContainer)||!r.contains(range.endContainer))return null;
            var nodes=textNodes(),acc=0,s=-1,e=-1;
            for(var i=0;i<nodes.length;i++){
              var n=nodes[i],len=n.nodeValue?n.nodeValue.length:0;
              if(s<0&&n===range.startContainer)s=acc+range.startOffset;
              if(e<0&&n===range.endContainer)e=acc+range.endOffset;
              acc+=len;
            }
            if(s<0||e<0||e<=s)return null;
            return {s:s,e:e};
          };
          window.__desireApplyHighlights=function(){
            clearMarks();
            var list=window.__desireHighlightData||[];
            for(var i=0;i<list.length;i++){
              var h=list[i];
              if(!wrapOffsets(h))wrapQuote(h);
            }
          };
          window.__desireSetHighlights=function(list){
            window.__desireHighlightData=list||[];
            window.__desireApplyHighlights();
          };
          window.__desireRevealHighlight=function(id){
            var m=document.querySelector('mark[data-ebook-highlight="'+id+'"]');
            if(!m)return false;
            if(window.__desireGoToPage){
              var flow=document.getElementById('desire-flow');
              var page=m.closest?m.closest('.desire-page'):null;
              if(page&&flow){
                var pages=Array.prototype.slice.call(flow.children);
                var idx=pages.indexOf(page);
                if(idx>=0)window.__desireGoToPage(idx,false);
              }
            }else if(m.scrollIntoView){
              m.scrollIntoView({block:'center'});
            }
            m.classList.add('desire-highlight-flash');
            setTimeout(function(){m.classList.remove('desire-highlight-flash');},1600);
            return true;
          };
          document.addEventListener('click',function(e){
            var t=e.target;
            while(t&&t!==document){
              if(t.tagName==='MARK'&&t.getAttribute('data-ebook-highlight')){
                var id=t.getAttribute('data-ebook-highlight');
                if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.ebookHighlight){
                  window.webkit.messageHandlers.ebookHighlight.postMessage({id:id});
                }
                return;
              }
              t=t.parentElement;
            }
          });
          function ready(){window.__desireApplyHighlights();}
          if(document.readyState==='loading'){
            document.addEventListener('DOMContentLoaded',ready);
            window.addEventListener('load',ready);
          }else{
            setTimeout(ready,0);
          }
        })();
        """
    }
}
