import Foundation
import WebKit

/// 站点静音（0.6.3）：documentStart 注入 `HTMLMediaElement.muted/volume`
/// 劫持（page world——须与页面同世界才能拦住站点自己的 set），运行时开关
/// 经 `evaluateJavaScript` 调 `__desireSetForceMuted`。
///
/// 可行性 spike（/tmp/mute_spike，2026-10-05）：加载后注入 page world，
/// 劫持 getter 后站点 `muted=false` 读回 1（强制）、解除后读回 0（round-trip ✓）。
/// 已知局限（诚实口径，写进设置帮助）：Shadow DOM 深处的播放器若**在受保护的
/// 闭包里持有元素引用**，defineProperty 对原型生效、元素属性读取仍走 getter——
/// 理论覆盖；真正可能漏的是跨 frame（forMainFrameOnly: false 已覆盖子框架）。
enum TabAudioControl {
    /// 静音劫持脚本：getter/setter 分层存储，`__desireForceMuted === false`
    /// 表示"不强制"（放行站点自己的 muted 值）。
    static let hijackSource = """
    (function () {
      if (window.__desireMuteHook) return;
      window.__desireMuteHook = true;
      Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
        get() { return this.__desireForceMuted === false ? (this.__desireStoreMuted ?? false) : true; },
        set(v) { this.__desireStoreMuted = v; }
      });
      Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
        get() { return this.__desireForceMuted === false ? (this.__desireStoreVolume ?? 1) : 0; },
        set(v) { this.__desireStoreVolume = v; }
      });
      window.__desireSetForceMuted = function (muted) {
        document.querySelectorAll('video, audio').forEach(function (m) {
          m.__desireForceMuted = muted;
        });
      };
      // 迟到的媒体元素：MutationObserver 兜底补标（强制开启期间新插入的 video/audio）
      var apply = function () {
        if (window.__desireForceMutedState !== true) return;
        document.querySelectorAll('video, audio').forEach(function (m) {
          m.__desireForceMuted = true;
        });
      };
      new MutationObserver(apply).observe(document.documentElement, { childList: true, subtree: true });
      document.addEventListener('DOMContentLoaded', apply);
    })();
    """

    static func userScript() -> WKUserScript {
        WKUserScript(source: hijackSource, injectionTime: .atDocumentStart,
                     forMainFrameOnly: false, in: .page)
    }

    /// 运行时开关（对已打开的页面）：设置状态变量并即时应用。
    static func apply(_ muted: Bool, to webView: WKWebView) async {
        let js = """
        (function () {
          window.__desireForceMutedState = \(muted);
          if (!window.__desireSetForceMuted) {
            // documentStart 注入因任何原因缺席（极端时序）——就地补装
            \(hijackSource)
          }
          window.__desireSetForceMuted(\(muted));
          return 'ok';
        })();
        """
        _ = try? await webView.evaluateJavaScript(js, in: nil, in: .page)
    }
}
