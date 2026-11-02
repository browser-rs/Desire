import Foundation

/// 整章译文注入（v0.8.36）：给正文块编号，把译文作为块内 `<span>` 追加，
/// 让分页把原文 + 译文当作同一块处理；偏移类功能（高亮/朗读）跳过译文节点。
nonisolated enum EbookTranslationJS {

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

    static func script() -> String {
        """
        (function(){
          window.__desireTranslations = [];
          function configRoot(){return document.getElementById('desire-flow')||document.body;}
          function blockText(el){
            var clone=el.cloneNode(true);
            var old=clone.querySelectorAll('.desire-translation');
            for(var i=0;i<old.length;i++){old[i].remove();}
            return (clone.innerText||clone.textContent||'').trim();
          }
          function blocksIn(root){
            var out=[];
            if(!root)return out;
            var nodes=root.querySelectorAll('p, h1, h2, h3, h4, li');
            for(var i=0;i<nodes.length;i++){
              var el=nodes[i];
              if(el.closest('.desire-translation'))continue;
              if(el.closest('pre'))continue;
              if(el.tagName==='LI'&&el.querySelector('p'))continue;
              var text=blockText(el);
              if(!text)continue;
              out.push({el:el,text:text});
            }
            return out;
          }
          function tag(root){
            var list=blocksIn(root);
            for(var i=0;i<list.length;i++){
              list[i].el.setAttribute('data-desire-block',String(i));
            }
            return list;
          }
          function removeTranslations(root){
            if(!root)return;
            var old=root.querySelectorAll('.desire-translation');
            for(var i=0;i<old.length;i++){
              if(old[i].parentNode)old[i].parentNode.removeChild(old[i]);
            }
          }
          function applyTo(root){
            if(!root)return;
            removeTranslations(root);
            var list=tag(root);
            var byId={};
            for(var i=0;i<list.length;i++){byId[i]=list[i].el;}
            var data=window.__desireTranslations||[];
            for(var j=0;j<data.length;j++){
              var item=data[j];
              var el=byId[item.block];
              if(!el)continue;
              var span=document.createElement('span');
              span.className='desire-translation';
              span.setAttribute('data-desire-translation',String(item.block));
              span.textContent=item.text;
              el.appendChild(span);
            }
          }
          window.__desireBlocks=function(){
            var list=tag(configRoot());
            return JSON.stringify(list.map(function(item,index){
              return {id:index,text:item.text};
            }));
          };
          window.__desireSetTranslations=function(list){
            window.__desireTranslations=list||[];
            if(window.__desireMeasurePages){window.__desireMeasurePages();}
            else{applyTo(configRoot());}
          };
          window.__desireClearTranslations=function(){
            window.__desireTranslations=[];
            if(window.__desireMeasurePages){window.__desireMeasurePages();}
            else{removeTranslations(configRoot());}
          };
          window.__desireApplyTranslationsTo=function(root){applyTo(root);};
          window.__desireHasTranslations=function(){
            return (window.__desireTranslations||[]).length>0;
          };
        })();
        """
    }
}
