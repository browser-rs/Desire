#!/usr/bin/env python3
"""密码面板与地址自动填充的端到端（v0.8.80 批 1-②③）。

覆盖：密码新增/更新/同键去重、健康判定（弱/重复）、HIBP k-匿名泄露检查
（本地假端点断言只收到 5 位前缀）、地址档案多份保存/载入、页面表单填充。

前置：封闭实例（tools/launch-hermetic.sh）在前台。用法：
    python3 tests/password-autofill-e2e.py [--base http://127.0.0.1:8799]
"""
import argparse
import http.server
import json
import threading
import time
import urllib.parse
import urllib.request

PORT = 8898
checks = []
seen_paths = []


def ok(label, cond, detail=""):
    checks.append((label, bool(cond)))
    print(("✓ " if cond else "✗ ") + label + ("" if cond or not detail else f" — {detail}"))


def br(base, method, path, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def execute(base, js, index=None):
    body = {"js": js}
    if index is not None:
        body["index"] = index
    return br(base, "POST", "/execute", body).get("result")


# 假 HIBP：SHA-1("password") = 5BAA61E4... —— 返回该前缀下的已知泄露行。
RANGE_BODY = (
    "0018A45C4D1DEF81644B54AB7F969B88D65:1\r\n"
    "1E4C9B93F3F0682250B6CF8331B7EE68FD8:3303003\r\n"
    "00D4F6E8FA6EECAD2A3AA415EEC418D38EC:2\r\n"
)


class FakeHIBP(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        seen_paths.append(self.path)
        body = RANGE_BODY.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


FORM_PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>autofill-e2e</title></head>
<body>
<form>
  <input id="given" name="given-name" autocomplete="given-name">
  <input id="family" name="family-name" autocomplete="family-name">
  <input id="email" name="email" autocomplete="email">
  <input id="street" name="address-line1" autocomplete="address-line1">
  <input id="zip" name="postal-code" autocomplete="postal-code">
</form>
</body></html>"""


class FormServer(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        body = FORM_PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def open_tab(base, url):
    created = br(base, "POST", "/new-tab", {"url": url})
    index = int(created.get("index", -1))
    deadline = time.time() + 20
    while time.time() < deadline:
        state = br(base, "GET", "/state")
        tabs = state.get("tabs", [])
        if index >= 0 and len(tabs) > index and not tabs[index].get("loading"):
            return index
        time.sleep(0.25)
    return index


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
    ok("实例在前台（表单填充要浏览器端点）", state.get("isActive") is True)

    hibp = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), FakeHIBP)
    threading.Thread(target=hibp.serve_forever, daemon=True).start()
    form = http.server.ThreadingHTTPServer(("127.0.0.1", PORT + 1), FormServer)
    threading.Thread(target=form.serve_forever, daemon=True).start()
    endpoint = f"http://127.0.0.1:{PORT}"

    try:
        # ---- 密码：新增 / 同键去重 / 编辑 ----
        br(base, "POST", "/passwords/delete", {"domain": "weak-a.example"})
        br(base, "POST", "/passwords/delete", {"domain": "weak-b.example"})
        before = len(br(base, "GET", "/passwords").get("entries", []))
        r = br(base, "POST", "/passwords/add",
               {"domain": "weak-a.example", "username": "u1", "password": "password"})
        ok("密码：新增", r.get("ok") is True and r.get("updated") is False, str(r))
        r = br(base, "POST", "/passwords/add",
               {"domain": "weak-a.example", "username": "u1", "password": "password"})
        ok("密码：同站点同账号原地更新（不新增幽灵条目）", r.get("updated") is True, str(r))
        br(base, "POST", "/passwords/add",
           {"domain": "weak-b.example", "username": "u2", "password": "password"})
        entries = br(base, "GET", "/passwords").get("entries", [])
        ok("密码：列表只多了两条", len(entries) == before + 2, f"{before} → {len(entries)}")

        # ---- 健康（弱/重复，改密前测）----
        health = br(base, "POST", "/passwords/health")
        ok("健康：识别弱密码", health.get("weak", 0) >= 2, str(health)[:300])
        ok("健康：识别重复密码", health.get("duplicate", 0) >= 1, str(health)[:300])
        r = br(base, "POST", "/passwords/update",
               {"domain": "weak-a.example", "username": "u1", "newPassword": "X9#kP2$mQvL5"})
        ok("密码：编辑（改密码）", r.get("ok") is True, str(r))

        # ---- 泄露检查：只发 5 位前缀 ----
        seen_paths.clear()
        check = br(base, "POST", "/passwords/breach-check", {"endpoint": endpoint}, timeout=60)
        leaked = check.get("leaked", [])
        target = [row for row in leaked if row.get("domain") == "weak-b.example"]
        ok("泄露：命中已知弱密码并返回次数",
           bool(target) and target[0].get("count") == 3_303_003, str(check)[:300])
        ok("泄露：请求路径只有 5 位前缀",
           seen_paths and all(p.startswith("/range/") and len(p.split("/")[-1]) == 5 for p in seen_paths),
           str(seen_paths))
        ok("泄露：没有任何密码或完整哈希离开本机",
           all("1E4C9B93" not in p and "password" not in p for p in seen_paths), str(seen_paths))

        # ---- 地址档案：多份保存 / 载入 ----
        br(base, "POST", "/autofill/update",
           {"label": "Home", "givenName": "Ada", "familyName": "Lovelace",
            "email": "ada@example.com", "streetAddress": "1 Analytical Engine Way",
            "city": "London", "zipCode": "N1", "country": "UK"})
        profiles = br(base, "POST", "/autofill/save-current")
        saved_home = next((p for p in profiles.get("saved", []) if p.get("label") == "Home"), None)
        ok("档案：保存当前档案进库", saved_home is not None, str(profiles)[:300])
        br(base, "POST", "/autofill/new")
        br(base, "POST", "/autofill/update", {"label": "Work", "givenName": "Grace", "familyName": "Lovelace",
                                              "email": "grace@example.com", "streetAddress": "1 Analytical Engine Way",
                                              "city": "London", "zipCode": "N1", "country": "UK"})
        br(base, "POST", "/autofill/save-current")
        profiles = br(base, "POST", "/autofill/load", {"id": saved_home["id"]}) if saved_home else {}
        working = profiles.get("working", {})
        ok("档案：载入已保存档案", working.get("label") == "Home" and "Ada" in working.get("name", ""),
           str(working))

        # ---- 表单填充 ----
        index = open_tab(base, f"http://127.0.0.1:{PORT + 1}/form")
        fill = br(base, "POST", "/autofill/fill", {"index": index})
        time.sleep(0.6)
        values = json.loads(execute(base, """JSON.stringify({
            given: document.getElementById('given').value,
            family: document.getElementById('family').value,
            email: document.getElementById('email').value,
            street: document.getElementById('street').value,
            zip: document.getElementById('zip').value})""", index=index) or "{}")
        ok("填充：姓名/邮箱/地址/邮编都写进了空字段",
           fill.get("ok") is True and values.get("given") == "Ada"
           and values.get("family") == "Lovelace" and values.get("email") == "ada@example.com"
           and values.get("street").startswith("1 Analytical") and values.get("zip") == "N1",
           str(values))
        # 已填字段不被覆盖（只填空字段）
        br(base, "POST", "/autofill/update", {"givenName": "Changed"})
        br(base, "POST", "/autofill/fill", {"index": index})
        time.sleep(0.5)
        still = execute(base, "document.getElementById('given').value", index=index)
        ok("填充：已有值不被覆盖", still == "Ada", str(still))
        br(base, "POST", "/close-tab", {"index": index})

        # ---- 快照 ----
        snap = br(base, "GET", "/panel/snapshot?name=passwords&w=420&h=520", timeout=60)
        ok("密码面板离屏快照可拍", bool(snap.get("path")), str(snap)[:200])
    finally:
        for domain in ("weak-a.example", "weak-b.example"):
            try:
                br(base, "POST", "/passwords/delete", {"domain": domain})
            except Exception:
                pass
        try:
            br(base, "POST", "/autofill/update", {
                "label": "", "givenName": "", "familyName": "", "email": "", "phone": "",
                "organization": "", "streetAddress": "", "city": "", "state": "",
                "zipCode": "", "country": ""})
            prof = br(base, "GET", "/autofill/profiles")
            for saved in prof.get("saved", []):
                br(base, "POST", "/autofill/delete", {"id": saved["id"]})
        except Exception:
            pass
        hibp.shutdown()
        form.shutdown()

    passed = sum(1 for _, cond in checks if cond)
    print("\n密码与自动填充端到端：%d/%d 通过" % (passed, len(checks)))
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
