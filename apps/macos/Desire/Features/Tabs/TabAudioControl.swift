import Foundation
import WebKit

/// 站点静音（0.6.3，2026-10-10 二版重写劫持语义）：documentStart 注入
/// （page world——须与页面同世界才能拦住站点自己的 set），运行时开关
/// 经 `evaluateJavaScript` 调 `__desireSetForceMuted`。
///
/// v1 的教训（本次 tab 声音指示失效的根因）：getter 写成"未初始化就返回
/// muted=true/volume=0"——普通标签 `__desireForceMuted` 是 undefined，于是
/// 所有站点的所有媒体元素读出来都是"已静音零音量"：① audio-state.js 的
/// `el.volume > 0` 永远不成立 → tab 声音图标/静音按钮永不出现；② 所有站点
/// 被骗（YouTube 播放器音量 UI 等）；③ 只骗读取不动真实属性，实际并不静音。
///
/// v2 语义：**默认全透传**（原生 get/set 原样放行，检测脚本与站点都读到
/// 真值）；只有 `__desireForceMuted === true` 时 getter 才说谎、setter 才吞，
/// 且 `__desireSetForceMuted(true)` 会把原生 muted 真设为 true（记下原值，
/// 解除时还原）——强制与解除都是真操作。
enum TabAudioControl {
    /// 静音劫持脚本：native 描述符先存后劫持；`__desireForceMuted` 三态
    /// （undefined=从未介入 → 全透传 / true=强制静音 / false=曾介入已解除）。
    static let hijackSource = """
    (function () {
      if (window.__desireMuteHook) return;
      window.__desireMuteHook = true;
      var descMuted = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'muted');
      var descVolume = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'volume');
      Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
        get() { return this.__desireForceMuted === true ? true : descMuted.get.call(this); },
        set(v) {
          if (this.__desireForceMuted === true) { this.__desireStoreMuted = v; }
          else { descMuted.set.call(this, v); }
        }
      });
      Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
        get() { return this.__desireForceMuted === true ? 0 : descVolume.get.call(this); },
        set(v) {
          if (this.__desireForceMuted === true) { this.__desireStoreVolume = v; }
          else { descVolume.set.call(this, v); }
        }
      });
      // 真实静音：动原生属性（v1 只骗读取，实际没静音）；解除时还原原值。
      window.__desireSetForceMuted = function (muted) {
        document.querySelectorAll('video, audio').forEach(function (m) {
          if (muted) {
            if (m.__desireNativeMuted === undefined) m.__desireNativeMuted = descMuted.get.call(m);
            if (m.__desireNativeVolume === undefined) m.__desireNativeVolume = descVolume.get.call(m);
            m.__desireForceMuted = true;
            descMuted.set.call(m, true);
          } else {
            m.__desireForceMuted = false;
            if (m.__desireNativeMuted !== undefined) descMuted.set.call(m, m.__desireNativeMuted);
            if (m.__desireNativeVolume !== undefined) descVolume.set.call(m, m.__desireNativeVolume);
          }
        });
      };
      // 迟到的媒体元素：强制开启期间新插入的 video/audio 补真实静音。
      var apply = function () {
        if (window.__desireForceMutedState === true) window.__desireSetForceMuted(true);
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
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript(js, in: nil, in: .page) { _ in
                cont.resume()
            }
        }
    }
}
