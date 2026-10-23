/* Desire 产品页匿名归因（v0.8.3）
 *
 * 只发送：事件名、UTM 标签、页面路径。不发送 IP/Cookie/UA/设备标识；
 * 不写 Cookie，不使用第三方脚本。
 *
 * 关闭方式：localStorage.setItem("desire_growth_optout", "1")
 * 或浏览器 Do Not Track。端点可用 window.DESIRE_GROWTH_ENDPOINT 覆盖。
 */
(function () {
  'use strict';
  var ENDPOINT = (window.DESIRE_GROWTH_ENDPOINT || 'https://api.mankong.icu/v9/growth/event');
  try {
    if (localStorage.getItem('desire_growth_optout') === '1') return;
  } catch (e) {}
  var dnt = navigator.doNotTrack || window.doNotTrack || navigator.msDoNotTrack;
  if (dnt === '1' || dnt === 'yes') return;
  if (location.protocol !== 'http:' && location.protocol !== 'https:') return;
  if (typeof fetch !== 'function') return;

  var params = new URLSearchParams(location.search);
  var base = {
    source: params.get('utm_source') || '',
    medium: params.get('utm_medium') || '',
    campaign: params.get('utm_campaign') || '',
    content: params.get('utm_content') || ''
  };
  var lastDownloadAt = 0;

  function send(event) {
    try {
      var body = {
        event: event,
        source: base.source,
        medium: base.medium,
        campaign: base.campaign,
        content: base.content,
        path: location.pathname,
        app_version: ''
      };
      fetch(ENDPOINT, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        mode: 'cors',
        credentials: 'omit',
        keepalive: true
      }).catch(function () {});
    } catch (e) {}
  }

  send('page_view');

  document.addEventListener('click', function (e) {
    var target = e.target;
    if (!target || !target.closest) return;
    var link = target.closest('[data-growth-download], a[href*="github.com/browser-rs/Desire/releases"]');
    if (!link) return;
    var now = Date.now();
    if (now - lastDownloadAt < 5000) return; // 双击/连点去抖
    lastDownloadAt = now;
    send('download_click');
  }, true);
})();
