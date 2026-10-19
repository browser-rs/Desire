#!/usr/bin/env python3
"""DPP 收尾三 fixture 探针（v0.7.24）：跨源 iframe / shadow 表单 / 登录墙。

前置：应用以 --automation 跑（桥 127.0.0.1:8799）。
- 跨源 iframe：主源 8892 页面嵌 8893 的声明子页——view 声明在子框架里，
  抽取必须**逐帧路由**进子框架拿数据（0.7 切片二的能力回归）。
- shadow 表单：open shadow root 内的行，选择器走 `>>>` 下钻。
- 登录墙：0 条目 + 可见密码框 + 登录词 → 结果里必须有可行动指引。

用法：python3 tools/dpp-finish-probe.py
"""
import json
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BRIDGE = "http://127.0.0.1:8799"

MAIN_HTML = """<!doctype html><html><head><meta charset="utf-8"><title>dpp finish main</title></head>
<body><h1>main</h1>
<iframe src="http://127.0.0.1:8893/child.html" width="500" height="300"></iframe>
</body></html>"""

CHILD_HTML = """<!doctype html><html><head><meta charset="utf-8"><title>child</title>
<script type="application/x-desire+json">
{"protocol":"desire/1","page":{"type":"list"},
 "views":{"frameitems":{"item":".fi","fields":{"text":"@text"}}}}
</script></head>
<body><div class="fi">frame-item-1</div><div class="fi">frame-item-2</div></body></html>"""

SHADOW_HTML = """<!doctype html><html><head><meta charset="utf-8"><title>shadow</title>
<script type="application/x-desire+json">
{"protocol":"desire/1",
 "views":{"shadowrows":{"item":"shadow-host >>> .row","fields":{"val":"@text"}}}}
</script></head>
<body><shadow-host></shadow-host>
<script>
var host = document.querySelector('shadow-host');
var root = host.attachShadow({mode:'open'});
root.innerHTML = '<div class="row">shadow-ok</div><div class="row">shadow-two</div>';
</script></body></html>"""

LOGIN_HTML = """<!doctype html><html><head><meta charset="utf-8"><title>login wall</title>
<script type="application/x-desire+json">
{"protocol":"desire/1",
 "views":{"members":{"item":".member-row","fields":{"name":"@text"}}}}
</script></head>
<body>
<h1>请登录</h1>
<p>登录后查看会员列表</p>
<form><input type="text" name="user"><input type="password" name="pass" style="width:200px;height:24px">
<button>登录</button></form>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    pages = {}

    def do_GET(self):
        path = self.path.split("?")[0]
        html = self.pages.get(path)
        if html is None:
            self.send_response(404)
            self.end_headers()
            return
        body = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def bridge(method, path, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BRIDGE + path, data=data, method=method,
        headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def main():
    results = []

    def check(name, cond, detail=""):
        results.append((name, bool(cond)))
        print(("PASS" if cond else "FAIL"), name, ("| " + str(detail)[:200]) if detail and not cond else "")

    main_server = ThreadingHTTPServer(("127.0.0.1", 8892), type("H", (Handler,), {
        "pages": {"/main.html": MAIN_HTML, "/shadow.html": SHADOW_HTML, "/login.html": LOGIN_HTML}}))
    child_server = ThreadingHTTPServer(("127.0.0.1", 8893), type("H", (Handler,), {
        "pages": {"/child.html": CHILD_HTML}}))
    threading.Thread(target=main_server.serve_forever, daemon=True).start()
    threading.Thread(target=child_server.serve_forever, daemon=True).start()

    def open_and_extract(url, view, tries=12):
        bridge("POST", "/new-tab", {"url": url})
        for _ in range(tries):
            time.sleep(1.2)
            try:
                r = bridge("GET", f"/page/extract?view={view}")
            except Exception:
                continue
            text = json.dumps(r, ensure_ascii=False)
            if "No DPP protocol" in text or "no such view" in text.lower() or "unknown" in text.lower():
                continue
            if "Extracted" in text or "items" in text:
                return r, text
        return None, text if 'text' in dir() else ""

    # 1) 跨源 iframe：view 声明在 8893 子框架，抽取逐帧路由
    _, text = open_and_extract("http://127.0.0.1:8892/main.html", "frameitems")
    check("跨源 iframe：逐帧抽取到子框架数据",
          "frame-item-1" in text and "frame-item-2" in text, text)
    # 关掉刚开的标签
    st = bridge("GET", "/state")
    for i, t in enumerate(st.get("tabs", [])):
        if "8892/main.html" in json.dumps(t):
            bridge("POST", "/close-tab", {"index": i})
            break

    # 2) shadow 表单：`>>>` 下钻 open shadow root
    _, text = open_and_extract("http://127.0.0.1:8892/shadow.html", "shadowrows")
    check("shadow：>>> 选择器抽到 shadow 内数据",
          "shadow-ok" in text and "shadow-two" in text, text)
    st = bridge("GET", "/state")
    for i, t in enumerate(st.get("tabs", [])):
        if "8892/shadow.html" in json.dumps(t):
            bridge("POST", "/close-tab", {"index": i})
            break

    # 3) 登录墙：0 条目 + 密码框 + 登录词 → 行动指引
    _, text = open_and_extract("http://127.0.0.1:8892/login.html", "members")
    check("登录墙：0 条目给出可行动指引",
          "login wall" in text and "log in" in text, text)
    st = bridge("GET", "/state")
    for i, t in enumerate(st.get("tabs", [])):
        if "8892/login.html" in json.dumps(t):
            bridge("POST", "/close-tab", {"index": i})
            break

    main_server.shutdown()
    child_server.shutdown()
    bad = [n for n, c in results if not c]
    print(("ALL PASS" if not bad else "FAILED: " + ", ".join(bad)), f"({len(results) - len(bad)}/{len(results)})")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
