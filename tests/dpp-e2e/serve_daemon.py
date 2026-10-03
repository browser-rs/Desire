#!/usr/bin/env python3
"""常驻 fixture(8877) + 假 LLM(8880)——E2E 诊断用，独立进程不死。"""
import json, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FIXTURE_HTML = open("/tmp/dpp_audit/fixture/index.html").read() if False else """<!doctype html><html><head>
<script type="application/x-desire+json">
{"protocol":"desire/1","page":{"type":"workbench"},
 "signals":{"ready":"#app-ready","busy":"#busy-flag"},
 "actions":[
  {"name":"place-order","description":"下单一台 Widget","effects":"outbound","danger":true,
   "precondition":"#order-btn","run":[{"click":"#order-btn"}],"success":"ORDERED"},
  {"name":"local-refresh","description":"刷新面板","effects":"local",
   "run":[{"click":"#refresh-btn"}],"success":"REFRESHED"}]}
</script></head>
<body><div id="app-ready">ready</div>
<button id="order-btn" onclick="order()">Order</button>
<button id="refresh-btn" onclick="refresh()">Refresh</button>
<script>
function order(){ window.__ordered = true;
  var b = document.createElement('div'); b.id = 'busy-flag'; document.body.appendChild(b);
  setTimeout(function(){ b.remove(); }, 1500);
  document.body.innerText += ' ORDERED'; }
function refresh(){ window.__refreshed = true;
  document.body.innerText += ' REFRESHED'; }
</script></body></html>"""

IM_HTML = """<!doctype html><html><head>
<script type="application/x-desire+json">
{"protocol":"desire/1","page":{"type":"chat"},
 "views":{"thread":{"item":".msg","fields":{"text":".t"}}},
 "events":{"new-message":{"watch":".msg.unread","debounce":2}}}
</script></head>
<body>
<div class="msg"><span class="t">历史消息</span></div>
<script>
window.__injectMessage = function(text){
  var d = document.createElement('div'); d.className = 'msg unread';
  d.innerHTML = '<span class="t">' + text + '</span>';
  document.body.appendChild(d); return document.querySelectorAll('.msg.unread').length; };
</script></body></html>"""

class Fixture(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        body = (IM_HTML if self.path.startswith("/im") else FIXTURE_HTML).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

class FakeLLM(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try: body = json.loads(raw)
        except Exception: body = {}
        msgs = body.get("messages") or []
        model = body.get("model", "fake-gate")
        with open("/tmp/dpp_audit/fake_llm.log", "a") as f:
            f.write(f"REQ roles={[m.get('role') for m in msgs]} last_user={(next((m.get('content') for m in reversed(msgs) if m.get('role')=='user'), ''))[:60]!r}\n")
        last_user = max((i for i, m in enumerate(msgs) if m.get("role") == "user"), default=-1)
        mode_text = (msgs[last_user].get("content") or "") if last_user >= 0 else ""
        round_msgs = msgs[last_user + 1:]
        has_tool = any(m.get("role") == "tool" for m in round_msgs)

        def sse(chunk, finish=None):
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            if finish:
                done = {"id": "c", "object": "chat.completion.chunk", "created": int(time.time()),
                        "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]}
                self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
                self.wfile.write(b"data: [DONE]\n\n")

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        if "DPPNAV" in mode_text and not has_tool:
            call = {"index": 0, "id": "call_nav_1", "type": "function",
                    "function": {"name": "navigate", "arguments": json.dumps({"url": "http://127.0.0.1:8877/"})}}
            sse({"id": "c", "object": "chat.completion.chunk", "created": int(time.time()), "model": model,
                 "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [call]}, "finish_reason": None}]}, finish="tool_calls")
        elif "DPPGATE" in mode_text and not has_tool:
            action = "local-refresh" if "LOCAL" in mode_text else "place-order"
            call = {"index": 0, "id": "call_gate_1", "type": "function",
                    "function": {"name": "pageAction", "arguments": json.dumps({"name": action, "args": {}})}}
            sse({"id": "c", "object": "chat.completion.chunk", "created": int(time.time()), "model": model,
                 "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [call]}, "finish_reason": None}]}, finish="tool_calls")
        elif ("DPPGATE" in mode_text or "DPPNAV" in mode_text) and has_tool:
            tool_text = next((m.get("content") or "" for m in round_msgs if m.get("role") == "tool"), "")
            text = ("NAV-DONE: " if "DPPNAV" in mode_text else "GATE-DONE: ") + tool_text[:500].replace("\n", " | ")
            sse({"id": "c", "object": "chat.completion.chunk", "created": int(time.time()), "model": model,
                 "choices": [{"index": 0, "delta": {"role": "assistant", "content": text}, "finish_reason": None}]}, finish="stop")
        else:
            sse({"id": "c", "object": "chat.completion.chunk", "created": int(time.time()), "model": model,
                 "choices": [{"index": 0, "delta": {"role": "assistant", "content": "echo"}, "finish_reason": None}]}, finish="stop")
        self.wfile.flush()
        self.close_connection = True

for port, handler in [(8877, Fixture), (8880, FakeLLM)]:
    t = threading.Thread(target=ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever, daemon=True)
    t.start()
print("serving 8877 + 8880", flush=True)
while True:
    time.sleep(60)
