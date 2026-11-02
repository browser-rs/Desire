import Foundation

/// 逐词朗读高亮（v0.8.36）：朗读文本与 DOM 文本节点来自同一套 walker，
/// `willSpeakRange` 的偏移可直接落到正文；译文节点不参与。
nonisolated enum EbookSpeechJS {

    static func script() -> String {
        """
        (function(){
          function contentRoot(){return document.getElementById('desire-flow')||document.body;}
          function textNodes(){
            var r=contentRoot();
            if(!r)return [];
            var walker=document.createTreeWalker(r,NodeFilter.SHOW_TEXT,null);
            var out=[],n;
            while(n=walker.nextNode()){
              var p=n.parentElement;
              if(p&&(p.tagName==='SCRIPT'||p.tagName==='STYLE'))continue;
              if(p&&p.closest&&p.closest('.desire-translation'))continue;
              out.push(n);
            }
            return out;
          }
          function speechModel(){
            var nodes=textNodes(),parts=[],map=[],cursor=0;
            for(var i=0;i<nodes.length;i++){
              var t=nodes[i].nodeValue||'';
              if(!t)continue;
              if(parts.length){parts.push(' ');cursor+=1;}
              map.push({node:nodes[i],start:cursor,end:cursor+t.length});
              parts.push(t);cursor+=t.length;
            }
            return {text:parts.join(''),map:map};
          }
          function clearMarks(){
            var marks=document.querySelectorAll('mark.desire-speech');
            for(var i=0;i<marks.length;i++){
              var m=marks[i],p=m.parentNode;
              if(p)p.replaceChild(document.createTextNode(m.textContent),m);
            }
            var r=contentRoot();
            if(r&&r.normalize)r.normalize();
          }
          function wrap(node,a,b){
            if(a<0||b<=a)return null;
            try{
              var range=document.createRange();
              range.setStart(node,a);
              range.setEnd(node,b);
              var mark=document.createElement('mark');
              mark.className='desire-speech';
              range.surroundContents(mark);
              return mark;
            }catch(e){return null;}
          }
          window.__desireSpeechText=function(){return speechModel().text;};
          window.__desireSpeechHighlight=function(start,end){
            clearMarks();
            var m=speechModel(),first=null;
            for(var i=0;i<m.map.length;i++){
              var item=m.map[i];
              var len=item.node.nodeValue?item.node.nodeValue.length:0;
              var a=Math.max(start-item.start,0),b=Math.min(end-item.start,len);
              if(a<b){
                var mark=wrap(item.node,a,b);
                if(mark&&!first)first=mark;
              }
            }
            if(!first)return;
            if(window.__desireGoToPage){
              var flow=document.getElementById('desire-flow');
              var page=first.closest?first.closest('.desire-page'):null;
              if(page&&flow){
                var pages=Array.prototype.slice.call(flow.children);
                var idx=pages.indexOf(page);
                if(idx>=0)window.__desireGoToPage(idx,false);
              }
            }else if(first.scrollIntoView){
              first.scrollIntoView({block:'center'});
            }
          };
          window.__desireClearSpeechHighlight=clearMarks;
        })();
        """
    }
}
