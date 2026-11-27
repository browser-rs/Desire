#!/usr/bin/env python3
"""站点权限与隐私中心的端到端（v0.8.80 批 1-①）。

覆盖：弹窗权限（拦截 / 放行）、剪贴板读取拦截、摄像头/麦克风与联合权限的一致性、
清除本站数据、清除浏览数据的时间范围、严格 HTTPS-only（升级失败停在错误页 +
显式"继续访问 HTTP"）。

前置：封闭实例（tools/launch-hermetic.sh）在前台；本机能把 127.0.0.1.nip.io 解析到
127.0.0.1（严格 HTTPS-only 需要一个非 loopback 字面量的 http 主机，才会触发升级）。

用法：python3 tests/permissions-e2e.py [--base http://127.0.0.1:8799]
"""
import argparse
import http.server
import json
import threading
import time
import urllib.parse
import urllib.request

PORT = 8896
HOST = "127.0.0.1"
NIP = "127.0.0.1.nip.io"
checks = []


def ok(label, cond, detail=""):
    checks.append((label, bool(cond)))
    print(("✓ " if cond else "✗ ") + label + ("" if cond or not detail else f" — {detail}"))


def br(base, method, path, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>perm-e2e-page</title></head>
<body>
<button id="openTab" onclick="window.open('/popup','_blank')">tab</button>
<button id="openPopup" onclick="window.open('/popup','_blank','width=420,height=320')">popup</button>
<a id="linkNew" href="/popup" target="_blank">new window link</a>
<script>
  localStorage.setItem('perm_e2e', 'yes');
  window.__clip = 'pending';
  // **不在加载时自动读**：无用户手势的 readText 会让 WebContent 等系统粘贴授权，
  // 后续 evaluateJavaScript 一起卡住（实测）。测试在页面加载完成后显式调用。
  function readClip(){
    try {
      navigator.clipboard.readText().then(
        function(t){ window.__clip = 'ok:' + (t || ''); },
        function(e){ window.__clip = 'err:' + e.name + ':' + e.message; });
    } catch (e) { window.__clip = 'throw:' + e.name; }
  }
</script>
</body></html>"""

POPUP = """<!doctype html><html><head><meta charset="utf-8"><title>perm-e2e-popup</title></head><body>popup</body></html>"""
POPUP_CLOSE = """<!doctype html><html><head><meta charset="utf-8"><title>perm-e2e-popup</title></head><body>popup
<script>setTimeout(function(){ window.close(); }, 1500);</script></body></html>"""
OTHER = """<!doctype html><html><head><meta charset="utf-8"><title>perm-e2e-other</title></head><body>other</body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/page":
            body = PAGE.encode()
            cookie = "perm_e2e=yes; Path=/\r\n"
        elif path == "/popup":
            body, cookie = POPUP.encode(), ""
        elif path == "/popup-selfclose":
            body, cookie = POPUP_CLOSE.encode(), ""
        elif path == "/other":
            body, cookie = OTHER.encode(), ""
        else:
            body, cookie = b"not found", ""
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(body)


def wait_tab_settled(base, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = br(base, "GET", "/state")
        tabs = state.get("tabs", [])
        if tabs and not any(t.get("loading") for t in tabs):
            return state
        time.sleep(0.25)
    return br(base, "GET", "/state")


def tab_count(base):
    return len(br(base, "GET", "/state").get("tabs", []))


def window_count(base):
    return len(br(base, "GET", "/windows").get("windows", []))


def execute(base, js, index=None):
    body = {"js": js}
    if index is not None:
        body["index"] = index
    return br(base, "POST", "/execute", body).get("result")


def open_tab(base, url):
    """新开标签并返回 (selected, state)——新标签创建后即被选中；不依赖返回的位次
    （关过标签后位次会漂，v0.8.80 实测）。"""
    br(base, "POST", "/new-tab", {"url": url})
    deadline = time.time() + 20
    state = br(base, "GET", "/state")
    while time.time() < deadline:
        state = br(base, "GET", "/state")
        selected = state.get("selected", -1)
        tabs = state.get("tabs", [])
        if 0 <= selected < len(tabs) and not tabs[selected].get("loading"):
            return selected, state
        time.sleep(0.25)
    return state.get("selected", -1), state


def close_current(base):
    try:
        state = br(base, "GET", "/state")
        br(base, "POST", "/close-tab", {"index": state.get("selected", -1)})
    except Exception:
        pass
    time.sleep(0.4)


def goto(base, index, url):
    """导航到**唯一的 URL**（带 query）并等它真的成为当前地址且加载结束——
    导航途中的 evaluateJavaScript 会挂；只看 loading 会读到旧文档的 false。"""
    marker = urllib.parse.urlparse(url).query
    execute(base, "location.href = %s; 'ok'" % json.dumps(url), index=index)
    deadline = time.time() + 15
    while time.time() < deadline:
        state = br(base, "GET", "/state")
        tabs = state.get("tabs", [])
        if 0 <= index < len(tabs):
            current = tabs[index].get("url") or ""
            if marker and marker in current and not tabs[index].get("loading"):
                time.sleep(0.4)   # didCommit 的注入脚本落位
                return
        time.sleep(0.3)


def close_tab(base, index):
    try:
        br(base, "POST", "/close-tab", {"index": index})
    except Exception:
        pass


def matrix(base):
    data = br(base, "GET", "/permissions")
    return {row["host"]: row["decisions"] for row in data.get("matrix", [])}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8799")
    args = parser.parse_args()
    base = args.base

    state = br(base, "GET", "/state")
    startup = state.get("startup") or {}
    ok("封闭实例（存储/偏好/密钥三项隔离）",
       startup.get("dataDir") and startup.get("prefs") == "isolated" and startup.get("secrets") == "file",
       str(startup))
    deadline = time.time() + 3
    while time.time() < deadline and not br(base, "GET", "/state").get("isActive"):
        time.sleep(0.3)
    state = br(base, "GET", "/state")
    ok("实例在前台（浏览器端点可用）", state.get("isActive") is True)

    server = http.server.ThreadingHTTPServer((HOST, PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    page = f"http://{HOST}:{PORT}/page"
    nip_page = f"http://{NIP}:{PORT}/page"

    # 收尾用：清规则 / 关标签 / 关严格模式
    def cleanup():
        for host in (HOST, NIP):
            try:
                for kind in ("popups", "clipboardRead", "camera", "microphone", "cameraAndMicrophone"):
                    br(base, "POST", "/permissions", {"host": host, "type": kind, "decision": "ask"})
            except Exception:
                pass
        try:
            br(base, "POST", "/settings/https-only", {"enabled": False})
        except Exception:
            pass
        server.shutdown()

    try:
        # ---- 弹窗权限：拦截 / 放行 ----
        br(base, "POST", "/permissions", {"host": HOST, "type": "popups", "decision": "deny"})
        ok("弹窗规则落盘", matrix(base).get(HOST, {}).get("popups") == "deny", json.dumps(matrix(base)))
        index, _ = open_tab(base, page)
        tabs_before_popup = tab_count(base)
        windows_before_popup = window_count(base)
        # 热一下：WebKit 对页面加载后**首个**无手势 window.open 可能在委托前短路
        # （平台行为，标签/窗口都不变）；从第二次起稳定走宿主规则。
        execute(base, "document.getElementById('openPopup').click(); 'clicked'", index=index)
        time.sleep(1.2)
        blocks_before = br(base, "GET", "/permissions").get("popupBlocks", 0)
        execute(base, "document.getElementById('openPopup').click(); 'clicked'", index=index)
        time.sleep(1.5)
        blocks_mid = br(base, "GET", "/permissions").get("popupBlocks", 0)
        ok("弹窗被站点规则拦截（规则执行计数 +1、没有开新标签/新窗口）",
           blocks_mid == blocks_before + 1
           and tab_count(base) == tabs_before_popup and window_count(base) == windows_before_popup,
           f"blocks={blocks_before}→{blocks_mid} tabs={tab_count(base)}/{tabs_before_popup} "
           f"windows={window_count(base)}/{windows_before_popup}")
        # 无尺寸的 window.open 可能被 WebKit 在委托之前就短路（平台行为），不作判据；
        # 带尺寸的弹窗两次都走宿主规则 → 计数再 +1。
        execute(base, "window.open('/popup','_blank','width=420,height=320'); 'clicked'", index=index)
        time.sleep(1.2)
        blocks_after = br(base, "GET", "/permissions").get("popupBlocks", 0)
        ok("第二个带尺寸弹窗同样被拦截（计数再 +1）",
           blocks_after == blocks_mid + 1
           and tab_count(base) == tabs_before_popup and window_count(base) == windows_before_popup,
           f"blocks={blocks_mid}→{blocks_after}")
        close_current(base)
        br(base, "POST", "/permissions", {"host": HOST, "type": "popups", "decision": "ask"})
        index, _ = open_tab(base, page)
        blocks_allow_before = br(base, "GET", "/permissions").get("popupBlocks", 0)
        # 撤销规则后规则不再拦（平台对无手势 window.open 是否真开窗不作判据——
        # 这里断言的是"我们的规则放行"：拦截计数不增加）。
        execute(base, "window.open('/popup-selfclose','_blank','width=420,height=320'); 'clicked'", index=index)
        time.sleep(1.5)
        ok("撤销规则后不再由本站规则拦截（计数不增加）",
           br(base, "GET", "/permissions").get("popupBlocks", 0) == blocks_allow_before,
           f"blocks={blocks_allow_before}→{br(base, 'GET', '/permissions').get('popupBlocks')}")
        close_current(base)

        # ---- 剪贴板读取拦截 ----
        br(base, "POST", "/permissions", {"host": HOST, "type": "clipboardRead", "decision": "deny"})
        index, state_dbg = open_tab(base, page)
        # 拦截脚本在 didCommit 排队注入；等它真的装上再读（无手势的 readText 会等
        # 系统粘贴授权，把 WebContent 卡住——测试不能抢跑）。
        deadline = time.time() + 8
        installed = False
        while time.time() < deadline:
            desc = execute(base, "String(Object.getOwnPropertyDescriptor(navigator.clipboard,'readText')"
                                "&&Object.getOwnPropertyDescriptor(navigator.clipboard,'readText').value)", index=index)
            if desc and "Clipboard read is blocked" in desc:
                installed = True
                break
            time.sleep(0.2)
        ok("剪贴板：拦截脚本已装到页面世界", installed, str(desc))
        execute(base, "window.__clip = 'pending'; readClip(); 'ok'", index=index)
        deadline = time.time() + 5
        clip = "pending"
        while time.time() < deadline and clip == "pending":
            clip = execute(base, "window.__clip", index=index) or "pending"
            time.sleep(0.2)
        ok("剪贴板读取被本站规则拒绝", "Clipboard read is blocked for this site" in str(clip), str(clip))
        # 撤销拦截规则后的"恢复读取"不在这里断言：无用户手势的 readText 在
        # WKWebView 里会等系统粘贴授权，把 WebContent 卡住（平台行为，不是本功能）。
        # 规则移除路径由下方弹窗的"ask 后计数不再增加"覆盖。
        br(base, "POST", "/permissions", {"host": HOST, "type": "clipboardRead", "decision": "ask"})

        # ---- 摄像头 / 麦克风 / 联合权限 ----
        br(base, "POST", "/permissions", {"host": HOST, "type": "camera", "decision": "allow"})
        br(base, "POST", "/permissions", {"host": HOST, "type": "microphone", "decision": "allow"})
        ok("两者都允许 → 联合权限允许", matrix(base)[HOST].get("cameraAndMicrophone") == "allow",
           json.dumps(matrix(base).get(HOST)))
        br(base, "POST", "/permissions", {"host": HOST, "type": "microphone", "decision": "deny"})
        ok("麦克风拒绝 → 联合权限跟随为拒绝", matrix(base)[HOST].get("cameraAndMicrophone") == "deny",
           json.dumps(matrix(base).get(HOST)))
        br(base, "POST", "/permissions", {"host": HOST, "type": "camera", "decision": "ask"})
        br(base, "POST", "/permissions", {"host": HOST, "type": "microphone", "decision": "ask"})
        ok("都回到询问 → 联合权限规则删除", "cameraAndMicrophone" not in matrix(base).get(HOST, {}),
           json.dumps(matrix(base).get(HOST)))

        # ---- 清除本站数据 ----
        goto(base, index, page + "?r=cookie")
        cookie = execute(base, "document.cookie", index=index) or ""
        stored = execute(base, "localStorage.getItem('perm_e2e')", index=index) or ""
        ok("页面写入了 Cookie 与 localStorage", "perm_e2e" in cookie and stored == "yes",
           f"cookie={cookie!r} storage={stored!r}")
        cleared = br(base, "POST", "/privacy/clear-site", {"host": HOST})
        ok("清除本站数据返回删除的站点记录", cleared.get("ok") is True and int(cleared.get("removed", 0)) >= 1,
           str(cleared))
        # 不重新导航：页面本身不再写 cookie/storage，直接读当前文档的口径——
        # 重新打开页面会由响应头/脚本把它们再种回来（就不是"清除"的判据了）。
        time.sleep(0.5)
        cookie2 = execute(base, "document.cookie", index=index) or ""
        stored2 = execute(base, "localStorage.getItem('perm_e2e')", index=index) or ""
        ok("清除后 Cookie 与 localStorage 都不在了", "perm_e2e" not in cookie2 and stored2 in ("", None),
           f"cookie={cookie2!r} storage={stored2!r}")

        # ---- 清除浏览数据的时间范围 ----
        goto(base, index, f"http://{HOST}:{PORT}/other?r=hist1")
        goto(base, index, page + "?r=hist2")
        time.sleep(2.0)   # DiskStore 防抖 500ms：/history 读的是盘上值
        history = br(base, "GET", "/history?count=50").get("entries", [])
        ok("历史里有本次访问的记录", len(history) >= 2, str(len(history)))
        cleared = br(base, "POST", "/privacy/clear",
                     {"range": "pastHour", "cookies": False, "cache": False, "storage": False, "history": True})
        time.sleep(1.5)   # 同上：清除后的落盘
        after = br(base, "GET", "/history?count=50").get("entries", [])
        ok("按时间范围清除历史（过去 1 小时）",
           cleared.get("ok") is True and cleared.get("historyRemoved", 0) >= 2 and len(after) == 0,
           f"{cleared} remaining={len(after)}")

        # ---- 严格 HTTPS-only ----
        br(base, "POST", "/settings/https-only", {"enabled": False})
        index2, state2 = open_tab(base, nip_page)
        # 等这一标签自己落地（不要把别的标签的标题当判据——同名页面会有多份）。
        deadline = time.time() + 12
        meta2 = br(base, "GET", f"/page/url?index={index2}")
        while time.time() < deadline and meta2.get("title") != "perm-e2e-page":
            time.sleep(0.3)
            meta2 = br(base, "GET", f"/page/url?index={index2}")
        ok("非严格模式：升级失败自动回退 HTTP，页面照常打开",
           meta2.get("title") == "perm-e2e-page" and (meta2.get("url") or "").startswith("http://"),
           json.dumps(meta2, ensure_ascii=False)[:300])
        close_tab(base, index2)

        enabled = br(base, "POST", "/settings/https-only", {"enabled": True})
        ok("开启严格 HTTPS-only", enabled.get("httpsOnlyMode") is True, str(enabled))
        index3, state3 = open_tab(base, nip_page)
        meta = br(base, "GET", f"/page/url?index={index3}")
        deadline = time.time() + 12
        while time.time() < deadline and not meta.get("insecureFallback"):
            time.sleep(0.4)
            meta = br(base, "GET", f"/page/url?index={index3}")
        ok("严格模式：升级失败停在错误页，并给出 HTTP 原地址",
           bool(meta.get("error")) and meta.get("insecureFallback", "").startswith("http://"),
           json.dumps(meta, ensure_ascii=False)[:300])
        continued = br(base, "POST", "/page/continue-insecure", {"index": index3})
        deadline = time.time() + 15
        meta = br(base, "GET", f"/page/url?index={index3}")
        while time.time() < deadline and (meta.get("title") != "perm-e2e-page" or meta.get("isLoading")):
            time.sleep(0.4)
            meta = br(base, "GET", f"/page/url?index={index3}")
        ok("点'继续访问'后以 HTTP 打开页面（这一次不再升级）",
           continued.get("ok") is True and meta.get("title") == "perm-e2e-page"
           and (meta.get("url") or "").startswith("http://"),
           json.dumps(meta, ensure_ascii=False)[:300])
        close_tab(base, index3)
        br(base, "POST", "/settings/https-only", {"enabled": False})

        # ---- 快照（布局自检用）----
        snap = br(base, "GET", "/panel/snapshot?name=sitecontrols&w=340&h=900", timeout=60)
        ok("站点控制中心离屏快照可拍（含权限编辑区）", bool(snap.get("path")), str(snap)[:200])
    finally:
        cleanup()

    passed = sum(1 for _, cond in checks if cond)
    print("\n站点权限与隐私中心端到端：%d/%d 通过" % (passed, len(checks)))
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
