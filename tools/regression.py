#!/usr/bin/env python3
"""Desire browser automation regression suite.

Drives the running browser through its localhost automation bridge
(127.0.0.1:8799, enabled by launching the app with --automation).

Self-contained: writes the MCP test config, starts local helper servers
(MCP echo/add + static file server for downloads/pages), relaunches the
app with --automation, then runs the checks and prints a PASS/FAIL summary.

Usage: python3 tools/regression.py [--keep-app]
"""
import http.server
import json
import os
import socketserver
import subprocess
import sys
import threading
import time
import urllib.request
import uuid

BASE = "http://127.0.0.1:8799"
APP = os.path.expanduser(
    "~/Library/Developer/Xcode/DerivedData/Desire-cypvzjloyvrfvbcnlbdebkkbubhe"
    "/Build/Products/Debug/Desire.app"
)
MCP_PORT, FILE_PORT = 8901, 8877  # 8000 is commonly squatted by dev servers
results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail and not ok else ""))


def api(method, path, body=None):
    req = urllib.request.Request(BASE + path, method=method)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, data=data, timeout=10) as r:
        return json.loads(r.read())


def wait_loaded(index, timeout=20):
    # A fresh navigate POST returns before the new navigation started
    # spinning isLoading up — wait a beat, THEN poll for completion.
    time.sleep(1.5)
    deadline = time.time() + timeout
    while time.time() < deadline:
        meta = api("GET", f"/page/url?index={index}")
        if not meta.get("isLoading"):
            time.sleep(0.8)   # title/text KVO lands after didFinish
            return api("GET", f"/page/url?index={index}")
        time.sleep(0.5)
    return api("GET", f"/page/url?index={index}")


def wait_mcp_ready(timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            mcp = api("GET", "/mcp")
            srv = (mcp.get("servers") or [{}])[0]
            if "ready" in srv.get("status", ""):
                return srv
        except Exception:
            pass
        time.sleep(1)
    return {"status": "timeout", "tools": []}


def wait_agent_done(timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = api("GET", "/agent/messages")
        if not state.get("busy"):
            return state
        time.sleep(1.0)
    return api("GET", "/agent/messages")


# ── Local helpers ────────────────────────────────────────────────

def start_mcp_server():
    server_src = r'''
import http.server, json
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        req = json.loads(self.rfile.read(length) or b'{}')
        method, rid = req.get('method'), req.get('id')
        result = {}
        if method == 'initialize':
            result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                      "serverInfo": {"name": "desire-test-mcp", "version": "0.1"}}
        elif method == 'tools/list':
            result = {"tools": [{"name": "echo", "description": "Echo input",
                      "inputSchema": {"type": "object", "properties": {"message": {"type": "string"}},
                       "required": ["message"]}}]}
        elif method == 'tools/call':
            args = req['params'].get('arguments', {})
            result = {"content": [{"type": "text", "text": "echo: " + args.get('message', '')}]}
        body = json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
http.server.HTTPServer(('127.0.0.1', %d), Handler).serve_forever()
''' % MCP_PORT
    path = "/tmp/desire_regression_mcp.py"
    open(path, "w").write(server_src)
    return subprocess.Popen([sys.executable, path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def start_file_server(tmpdir):
    class Quiet(socketserver.TCPServer):
        allow_reuse_address = True
    handler = lambda *a, **k: http.server.SimpleHTTPRequestHandler(*a, directory=tmpdir, **k)
    srv = Quiet(("127.0.0.1", FILE_PORT), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def main():
    keep = "--keep-app" in sys.argv
    # 0. Environment: MCP config + local test servers + app relaunch
    cfg_dir = os.path.expanduser("~/Library/Application Support/Desire/storage")
    os.makedirs(cfg_dir, exist_ok=True)
    mcp_cfg = [{"id": str(uuid.uuid4()), "name": "desire-test",
                "url": f"http://127.0.0.1:{MCP_PORT}/mcp", "isEnabled": True}]
    json.dump(mcp_cfg, open(os.path.join(cfg_dir, "mcp-servers.json"), "w"))

    tmpdir = "/tmp/desire_regression_files"
    os.makedirs(tmpdir, exist_ok=True)
    open(os.path.join(tmpdir, "page.html"), "w").write(
        "<html><head><title>Desire Regression Page</title></head>"
        "<body><h1>regression-ok</h1>"
        "<input id='name' placeholder='your name'>"
        "<button id='go' onclick=\"document.getElementById('result').textContent="
        "'hello ' + document.getElementById('name').value\">submit</button>"
        "<div id='result'></div>"
        "<a href='page.html'>self</a></body></html>")
    open(os.path.join(tmpdir, "test.zip"), "wb").write(
        b"PK\x05\x06" + b"\x00" * 18 + b"regression")

    mcp_proc = start_mcp_server()
    file_srv = start_file_server(tmpdir)
    time.sleep(0.5)

    subprocess.run(["pkill", "-9", "-x", "Desire"], check=False)
    time.sleep(2)
    subprocess.run(["open", APP, "--args", "--automation"], check=False)
    deadline = time.time() + 20
    while time.time() < deadline:
        try:
            api("GET", "/state")
            break
        except Exception:
            time.sleep(0.5)

    try:
        # 1. State baseline
        state = api("GET", "/state")
        check("state: tabs listed", len(state.get("tabs", [])) >= 1)

        # 2. Search resolution: no-dot text → SOME search engine URL
        #    (engine is user config; don't assert a specific one)
        nav = api("POST", "/navigate", {"url": "hello world"})
        meta = wait_loaded(0)
        target = nav.get("navigatedTo", "")
        is_search = ("/search?" in target or "/s?wd=" in target
                     or "duckduckgo.com/?q=" in target)
        check("search resolution", is_search, target)

        # 3. Local page: deterministic load + title
        api("POST", "/navigate", {"url": f"http://127.0.0.1:{FILE_PORT}/page.html"})
        meta = wait_loaded(0)
        check("local page load", "Desire Regression Page" in (meta.get("title") or ""), str(meta))

        # 4. Page text extraction
        text = api("GET", "/page/text").get("text", "")
        check("page text", "regression-ok" in text)

        # 5. MCP status (async connect — poll until ready)
        srv = wait_mcp_ready()
        check("mcp ready", "ready" in srv.get("status", "") and len(srv.get("tools", [])) >= 1,
              srv.get("status", ""))

        # 6. Agent: MCP tool call end-to-end
        api("POST", "/agent/send", {"text": "用 MCP 工具 echo 发送 reg-test，只告诉我返回内容"})
        state = wait_agent_done()
        blob = json.dumps(state)
        check("agent mcp echo", "echo: reg-test" in blob)

        # 7. Agent: runCommand (dangerous → approval bridge)
        api("POST", "/agent/send", {"text": "用 runCommand 运行 python3，参数 [\"-c\", \"print(13*13)\"]，告诉我输出的数字"})
        time.sleep(8)
        approvals = api("GET", "/approvals")
        check("approval surfaced", approvals.get("pending") is True
              and approvals.get("tool") == "runCommand", json.dumps(approvals)[:120])
        if approvals.get("pending"):
            api("POST", "/approvals/resolve", {"decision": "allow_once"})
        state = wait_agent_done()
        blob = json.dumps(state)
        check("agent runCommand 169", "169" in blob)

        # 8. Downloads
        api("POST", "/navigate", {"url": f"http://127.0.0.1:{FILE_PORT}/test.zip"})
        deadline = time.time() + 15
        done = False
        while time.time() < deadline:
            dls = api("GET", "/downloads").get("downloads", [])
            if any(d.get("state") == "completed" and d.get("file") == "test.zip" for d in dls):
                done = True
                break
            time.sleep(1)
        check("download completed", done)

        # 9. Incognito isolation
        before = api("GET", "/history?count=1").get("entries", [])
        api("POST", "/new-tab", {"url": f"http://127.0.0.1:{FILE_PORT}/page.html?incog", "incognito": True})
        time.sleep(3)
        after = api("GET", "/history?count=1").get("entries", [])
        check("incognito history isolation",
              [e.get("url") for e in after] == [e.get("url") for e in before] or not after,
              json.dumps(after)[:120])
        tabs = api("GET", "/state").get("tabs", [])
        incog_index = next((t["index"] for t in tabs if t.get("incognito")), None)
        check("incognito tab flagged", incog_index is not None)
        if incog_index is not None:
            api("POST", "/close-tab", {"index": incog_index})

        # 9.5 Agent DOM interaction: fill input, click button, read result
        api("POST", "/navigate", {"url": f"http://127.0.0.1:{FILE_PORT}/page.html"})
        wait_loaded(0)
        api("POST", "/agent/send", {"text":
            "在当前页面的输入框（id=name）填入 Alice，然后点击提交按钮（id=go），"
            "等页面更新后告诉我 result 区域显示的文字"})
        state = wait_agent_done(timeout=120)
        blob = json.dumps(state)
        check("agent fill+click+read", "hello Alice" in blob)

        # 10. Screenshot
        shot = api("GET", "/screenshot")
        check("screenshot written", os.path.exists(shot.get("path", "")), json.dumps(shot)[:120])

        # 11. Back/forward on a deterministic stack: pageA → pageB → back
        api("POST", "/navigate", {"url": f"http://127.0.0.1:{FILE_PORT}/page.html?step=1"})
        wait_loaded(0)
        api("POST", "/navigate", {"url": f"http://127.0.0.1:{FILE_PORT}/page.html?step=2"})
        wait_loaded(0)
        api("POST", "/back", {})
        time.sleep(2)
        meta = wait_loaded(0)
        check("back navigation", "step=1" in (meta.get("url") or ""), meta.get("url") or "")
    finally:
        if not keep:
            subprocess.run(["pkill", "-9", "-x", "Desire"], check=False)
        mcp_proc.terminate()
        print(f"\n{sum(1 for _, ok, _ in results if ok)}/{len(results)} passed")
        sys.exit(0 if all(ok for _, ok, _ in results) else 1)


if __name__ == "__main__":
    main()
