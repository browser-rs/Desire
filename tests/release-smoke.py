#!/usr/bin/env python3
"""发版冒烟（约 2 分钟）：只跑**本版改动相关**的关键路径。

背景（2026-10-21 用户明确）：tests/execution-e2e.py 是 190 项、约 15 分钟的
全量回归，多数用例与单次迭代无关；**不要每版全量跑**。发版矩阵：
  - 每次：tests/run.sh（纯逻辑，40 秒）+ 本脚本；
  - 本版特性：按 CHANGELOG 验收项用桥/快照逐条探针；
  - 全量 execution-e2e.py：仅当改动核心浏览/Agent 回合循环/会话恢复，
    或每 3 个版本/里程碑跑一次。

本脚本覆盖 v0.7.28 涉及的用户可见链路：
  /state 就绪、阅读模式提取与 baseURL、备份导出/预览/按域合并、
  诊断包（OSLog + 崩溃摘要）、收件箱、预算快照。

前置：应用以 --automation 运行、桥在 8799。
用法：python3 tests/release-smoke.py [--quit]
"""
import argparse
import base64
import json
import os
import pathlib
import sys
import threading
import time
import urllib.request
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BRIDGE = "http://127.0.0.1:8799"
checks = []


def ok(label, cond, detail=""):
    checks.append((label, bool(cond)))
    mark = "✓" if cond else "✗"
    line = f"{mark} {label}"
    if detail and not cond:
        line += f" — {detail}"
    print(line)


def br(method, path, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BRIDGE + path, data=data, method=method,
        headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def state():
    return br("GET", "/state")


def selected_tab():
    s = state()
    tabs = s.get("tabs", [])
    idx = s.get("selected", 0)
    return tabs[idx] if 0 <= idx < len(tabs) else {}


def wait_for(predicate, seconds=20):
    end = time.time() + seconds
    while time.time() < end:
        try:
            if predicate():
                return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


ARTICLE = """<!DOCTYPE html><html><head><meta charset="utf-8"><title>Smoke Reader</title></head>
<body><nav>NAV</nav><article><h1>Smoke Reader Article</h1>
<p>First paragraph with enough words for the reader extractor to pick this article as the main content of the page.</p>
<p>Second paragraph with a <a href="next.html">relative link</a> for the absolute-URL pass.</p>
<p>Third paragraph to make the extracted text comfortably longer than the minimum threshold.</p>
</article>
<form id="f" onsubmit="event.preventDefault(); document.getElementById('result').textContent='submitted:' + document.getElementById('name').value + ':' + document.getElementById('email').value; document.title='Smoke Done';">
  <input id="name" name="name" placeholder="Name">
  <input id="email" name="email" type="email" placeholder="Email">
  <input id="password" name="password" type="password" placeholder="Password">
  <button id="submit" type="submit">Submit</button>
</form>
<div id="result"></div>
<footer>FOOTER</footer></body></html>"""


class FixtureHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] in ("/", "/index.html"):
            body = ARTICLE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass


def start_fixture():
    for port in (8877, 8878):
        try:
            server = ThreadingHTTPServer(("127.0.0.1", port), FixtureHandler)
        except OSError:
            continue
        threading.Thread(target=server.serve_forever, daemon=True).start()
        return server, f"http://127.0.0.1:{port}/index.html"
    raise RuntimeError("could not bind fixture server on 8877/8878")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--quit", action="store_true", help="结束时优雅退出应用")
    args = parser.parse_args()

    # 0) 桥与主窗
    try:
        s = br("GET", "/state")
    except Exception as exc:
        print(f"✗ bridge unreachable: {exc}", file=sys.stderr)
        return 1
    ok("应用就绪（/state tabs≥1）", len(s.get("tabs", [])) >= 1,
       f"tabs={len(s.get('tabs', []))}")

    original_url = selected_tab().get("url") or ""
    server = None
    backup_path = pathlib.Path(f"/tmp/desire-release-smoke-{os.getpid()}.json")
    diag_path = None
    enc_path = None
    try:
        # 1) 阅读模式：提取 + baseURL + 导航后退出
        server, fixture_url = start_fixture()
        br("POST", "/navigate", {"url": fixture_url})
        loaded = wait_for(lambda: selected_tab().get("title") == "Smoke Reader", 20)
        ok("阅读模式：fixture 页面加载", loaded, selected_tab().get("title", ""))
        # documentEnd 脚本可能还没装好；/command 也需要应用在前台。两者都等一下，
        # 避免把时序问题误报成阅读模式回归（v0.7.29 冒烟第一跑栽在这里）。
        for _ in range(20):
            probe = br("POST", "/execute", {"js": "typeof window._desireReader"})
            if probe.get("result") == "function":
                break
            time.sleep(0.3)
        os.system('osascript -e \'tell application "Desire" to activate\' >/dev/null 2>&1')
        time.sleep(0.4)
        br("POST", "/command", {"name": "toggleReader"})
        reader_ok = wait_for(
            lambda: (state().get("reader") or {}).get("active") is True
            and (state().get("reader") or {}).get("contentChars", 0) > 50, 20)
        reader = state().get("reader") or {}
        ok("阅读模式：提取成功（>50 字符）", reader_ok,
           f"active={reader.get('active')} chars={reader.get('contentChars')}")
        ok("阅读模式：baseURL 是页面 URL", reader.get("baseURL") == fixture_url,
           f"{reader.get('baseURL')!r}")
        if reader.get("active"):
            br("POST", "/command", {"name": "toggleReader"})
            time.sleep(0.5)

        # 2) 工作流：录制 → 重放（v0.7.29 旗舰）
        started = br("POST", "/workflow/start", {})
        ok("工作流：开始录制", started.get("ok") is True)
        fill_js = ("(function(){function set(id,v){var el=document.getElementById(id);"
                   "var s=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;"
                   "s.call(el,v);el.dispatchEvent(new Event('input',{bubbles:true}));"
                   "el.dispatchEvent(new Event('change',{bubbles:true}));}"
                   "set('name','Ada');set('email','ada@example.com');"
                   "set('password','SMOKE_PW_V29');return 'ok';})()")
        br("POST", "/execute", {"js": fill_js})
        br("POST", "/execute", {"js": "document.getElementById('submit').click(); document.getElementById('result').textContent"})
        time.sleep(0.6)
        saved = br("POST", "/workflow/stop", {"name": "smoke-flow"})
        details = saved.get("stepDetails") or []
        sensitive = [step for step in details if step.get("sensitive")]
        ok("工作流：录制到 4 步且密码敏感",
           len(details) >= 4 and len(sensitive) >= 1,
           json.dumps(details, ensure_ascii=False)[:300])
        ok("工作流：密码值不落盘",
           "SMOKE_PW_V29" not in json.dumps(saved, ensure_ascii=False))
        br("POST", "/navigate", {"url": fixture_url})
        wait_for(lambda: selected_tab().get("title") == "Smoke Reader", 20)
        run = (br("POST", "/workflow/run",
                  {"name": "smoke-flow", "values": {sensitive[0]["id"]: "SMOKE_PW_V29"}},
                  timeout=90) if sensitive else {})
        ok("工作流：重放全部步骤成功",
           run.get("ok") is True and all(step.get("ok") for step in run.get("results", [])),
           json.dumps(run, ensure_ascii=False)[:300])
        final = br("POST", "/execute", {"js": "document.getElementById('result').textContent"})
        ok("工作流：终态正确", final.get("result") == "submitted:Ada:ada@example.com",
           str(final))
        for workflow in br("GET", "/workflow/list").get("workflows", []):
            if workflow.get("name") == "smoke-flow":
                br("POST", "/workflow/delete", {"id": workflow["id"]})

        # 恢复原页面 + 清掉 fixture 历史（不污染用户历史）
        if original_url.startswith("http"):
            br("POST", "/navigate", {"url": original_url})
            time.sleep(1)
        try:
            for entry in br("GET", "/history?count=20").get("entries", []):
                if entry.get("url") == fixture_url:
                    br("POST", "/history/remove", {"id": entry.get("id")})
        except Exception:
            pass

        # 2) 备份：导出 → 预览 → 按域合并
        exported = br("POST", "/backup/export", {"path": str(backup_path)})
        counts = exported.get("counts") or {}
        ok("备份：导出（六域计数）",
           exported.get("ok") and {"bookmarks", "history", "settings"} <= set(counts),
           json.dumps(counts, ensure_ascii=False))
        preview = br("POST", "/backup/preview", {"path": str(backup_path)})
        ok("备份：预览（版本/支持性/计数）",
           preview.get("ok") and preview.get("supported") is True
           and isinstance(preview.get("counts"), dict),
           json.dumps(preview, ensure_ascii=False))
        applied = br("POST", "/backup/import",
                     {"path": str(backup_path), "mode": "merge", "domains": ["history"]})
        ok("备份：按域合并只动 history",
           applied.get("ok") and set((applied.get("applied") or {}).keys()) == {"history"},
           json.dumps(applied, ensure_ascii=False))

        # 2b) 备份：加密导出 / 预览 / 错口令 / 正确口令按域导入
        enc_path = pathlib.Path(f"/tmp/desire-release-smoke-enc-{os.getpid()}.json")
        enc = br("POST", "/backup/export",
                 {"path": str(enc_path), "passphrase": "SMOKE-PASS-V29"})
        raw = enc_path.read_bytes() if enc_path.exists() else b""
        ok("备份：加密导出（无明文 payloads）",
           enc.get("ok") is True and b"desire-backup-encrypted" in raw
           and b'"payloads"' not in raw)
        enc_preview = br("POST", "/backup/preview", {"path": str(enc_path)})
        ok("备份：加密预览标记", enc_preview.get("encrypted") is True)
        wrong = br("POST", "/backup/import",
                   {"path": str(enc_path), "mode": "merge", "passphrase": "wrong"})
        ok("备份：错口令拒绝", "error" in wrong)
        unlocked = br("POST", "/backup/import",
                      {"path": str(enc_path), "mode": "merge", "domains": ["history"],
                       "passphrase": "SMOKE-PASS-V29"})
        ok("备份：正确口令按域导入",
           unlocked.get("ok") is True
           and set((unlocked.get("applied") or {}).keys()) == {"history"})
        enc_path.unlink(missing_ok=True)

        # 2c) 活动中心
        activity = br("GET", "/activity")
        ok("活动中心：/activity 可用",
           activity.get("ok") is True and isinstance(activity.get("items"), list))

        # 3) 诊断包：OSLog + 崩溃摘要
        diag = br("POST", "/diag/export", {})
        diag_path = pathlib.Path(diag.get("path", "")) if diag.get("ok") else None
        ok("诊断：导出成功", diag.get("ok") and diag_path is not None and diag_path.exists(),
           json.dumps(diag, ensure_ascii=False))
        if diag_path and diag_path.exists():
            with zipfile.ZipFile(diag_path) as zf:
                names = zf.namelist()
            ok("诊断：包内含 OSLog", any("/oslog-" in n or n.startswith("oslog-") for n in names))
            ok("诊断：包内含崩溃摘要", any(n.endswith("browser-crashes.json") for n in names))

        # 4) 收件箱与预算快照
        ok("收件箱：/inbox 可用", br("GET", "/inbox").get("ok") is True)
        budget = br("GET", "/agent/budget")
        ok("预算：快照字段齐全",
           all(k in budget for k in ("budget", "used", "state", "stopLevel")))

    finally:
        if server:
            server.shutdown()
        try:
            backup_path.unlink(missing_ok=True)
        except Exception:
            pass
        if diag_path:
            try:
                diag_path.unlink(missing_ok=True)
            except Exception:
                pass
        if enc_path:
            try:
                enc_path.unlink(missing_ok=True)
            except Exception:
                pass
        if args.quit:
            os.system('osascript -e \'quit app "Desire"\' >/dev/null 2>&1')

    passed = sum(1 for _, c in checks if c)
    total = len(checks)
    print(f"\n发版冒烟：{passed}/{total} 通过")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
