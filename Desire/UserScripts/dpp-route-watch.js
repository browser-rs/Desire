// dpp-route-watch.js — SPA 路由变化 → 宿主重解析（desireProtocolControl）。
// 页面世界 documentStart 注入（必须早于页面脚本，才能包住 history 调用）。
// 价值：L1 锚点随 SPA 重排刷新（旧锚点会指向已移动的元素）、页面动态改写
// 声明时缓存跟进。SDK 用户另有 expose() 主动通知，此脚本对所有页面兜底。
// 风暴防护：宿主 reparseTask 250ms 防抖合并。
(function(){
  if (window.__desireRouteWatch) return;
  window.__desireRouteWatch = true;
  var send = function(){
    try { window.webkit.messageHandlers.desireProtocolControl.postMessage({ kind: "reparse" }); } catch (e) {}
  };
  var wrap = function(fn){
    return function(){ var r = fn.apply(this, arguments); send(); return r; };
  };
  try { history.pushState = wrap(history.pushState); } catch (e) {}
  try { history.replaceState = wrap(history.replaceState); } catch (e) {}
  window.addEventListener('popstate', send);
  window.addEventListener('hashchange', send);
})();
