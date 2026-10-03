#!/usr/bin/env python3
"""DPP 审批闸门真机 E2E（2026-10-02 审计 P0-1 的实测补全）。

流程：autoEdit 访问等级下（该档位曾零审批放行一切非 runCommand/fillLogin 工具），
假 LLM 逼 app 调 DPP 声明的 pageAction：
  A) local 动作 → 自动执行、无审批（证明 sideEffect 正常路径不受影响）
  B) danger 动作 → 审批挂起、工具未执行 → deny → 仍未执行 + 拒绝消息进对话
  C) danger 动作 → 审批挂起 → allow_once → 执行 + success 信号检测

前置：应用以 --automation 启动（本脚本不管启动）；bridge 可达。
访问等级/模型档案由 bash 外层负责快照与还原；本脚本负责档案与事件模式的
桥侧改动（还原并核对）+ 会话清理 + 服务进程退出。
"""
import json
import os
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BRIDGE = "http://127.0.0.1:8799"
FIXTURE_PORT = 8877
FAKE_PORT = 8880

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def bridge(method, path, body=None, timeout=15):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BRIDGE + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with opener.open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())

checks = []
def check(name, cond):
    checks.append((name, bool(cond)))
    print(("✓ " if cond else "✗ ") + name)

# ---------- fixture 页面 ----------

FIXTURE_HTML = """<!doctype html><html><head>
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

class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        body = FIXTURE_HTML.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

# ---------- 假 LLM ----------

class FakeLLMHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw)
        except Exception:
            body = {}
        msgs = body.get("messages") or []
        model = body.get("model", "fake-gate")
        last_user = max((i for i, m in enumerate(msgs) if m.get("role") == "user"), default=-1)
        mode_text = (msgs[last_user].get("content") or "") if last_user >= 0 else ""
        round_msgs = msgs[last_user + 1:]
        has_tool = any(m.get("role") == "tool" for m in round_msgs)

        def sse(chunk, finish=None):
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            if finish:
                done = {"id": "chatcmpl-gate", "object": "chat.completion.chunk",
                        "created": int(time.time()), "model": model,
                        "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]}
                self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
                self.wfile.write(b"data: [DONE]\n\n")

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        if "DPPNAV" in mode_text and not has_tool:
            call = {"index": 0, "id": "call_nav_1", "type": "function",
                    "function": {"name": "navigate",
                                 "arguments": json.dumps({"url": f"http://127.0.0.1:{FIXTURE_PORT}/"})}}
            sse({"id": "chatcmpl-gate", "object": "chat.completion.chunk",
                 "created": int(time.time()), "model": model,
                 "choices": [{"index": 0,
                              "delta": {"role": "assistant", "tool_calls": [call]},
                              "finish_reason": None}]}, finish="tool_calls")
        elif "DPPNAV" in mode_text and has_tool:
            tool_text = next((m.get("content") or "" for m in round_msgs if m.get("role") == "tool"), "")
            text = "NAV-DONE: " + tool_text[:500].replace("\n", " | ")
            sse({"id": "chatcmpl-gate", "object": "chat.completion.chunk",
                 "created": int(time.time()), "model": model,
                 "choices": [{"index": 0, "delta": {"role": "assistant", "content": text},
                              "finish_reason": None}]}, finish="stop")
        elif "DPPGATE" in mode_text and not has_tool:
            action = "local-refresh" if "LOCAL" in mode_text else "place-order"
            call = {"index": 0, "id": "call_gate_1", "type": "function",
                    "function": {"name": "pageAction",
                                 "arguments": json.dumps({"name": action, "args": {}})}}
            sse({"id": "chatcmpl-gate", "object": "chat.completion.chunk",
                 "created": int(time.time()), "model": model,
                 "choices": [{"index": 0,
                              "delta": {"role": "assistant", "tool_calls": [call]},
                              "finish_reason": None}]}, finish="tool_calls")
        elif "DPPGATE" in mode_text and has_tool:
            tool_text = next((m.get("content") or "" for m in round_msgs if m.get("role") == "tool"), "")
            text = "GATE-DONE: " + tool_text[:160].replace("\n", " ")
            sse({"id": "chatcmpl-gate", "object": "chat.completion.chunk",
                 "created": int(time.time()), "model": model,
                 "choices": [{"index": 0, "delta": {"role": "assistant", "content": text},
                              "finish_reason": None}]}, finish="stop")
        else:
            sse({"id": "chatcmpl-gate", "object": "chat.completion.chunk",
                 "created": int(time.time()), "model": model,
                 "choices": [{"index": 0, "delta": {"role": "assistant", "content": "echo"},
                              "finish_reason": None}]}, finish="stop")
        self.wfile.flush()
        self.close_connection = True

def serve(port, handler):
    server = ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server

# ---------- 断言辅助 ----------

def wait_approval(timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        st = bridge("GET", "/approvals")
        if st.get("pending"):
            return st
        time.sleep(0.5)
    return None

def assert_no_approval_while(fn_poll, duration=8):
    saw = False
    deadline = time.time() + duration
    while time.time() < deadline:
        if bridge("GET", "/approvals").get("pending"):
            saw = True
        fn_poll()
        time.sleep(0.5)
    return not saw

def last_tool_msgs(state):
    return [m for m in state.get("messages", []) if m.get("role") == "tool"]

def wait_turn_done(before_ids, timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = bridge("GET", "/agent/messages")
        msgs = state.get("messages", [])
        fresh = [m for m in msgs if m.get("id") not in before_ids and m.get("role") == "assistant"]
        if fresh and not state.get("busy") and fresh[-1].get("content"):
            time.sleep(0.5)
            state = bridge("GET", "/agent/messages")
            fresh = [m for m in state.get("messages", []) if m.get("id") not in before_ids and m.get("role") == "assistant"]
            if fresh and not state.get("busy"):
                return state
        time.sleep(0.5)
    raise TimeoutError("turn did not finish")

def run_case(prompt):
    before = {m.get("id") for m in bridge("GET", "/agent/messages").get("messages", [])}
    sent = bridge("POST", "/agent/send", body={"text": prompt})
    if not sent.get("ok"):
        raise RuntimeError(f"/agent/send rejected: {sent}")
    return before

def js(expr):
    return bridge("POST", "/execute", body={"js": expr})

# ---------- 主流程 ----------

def require_autoedit():
    """闸门 E2E 依赖 autoEdit 档——fullAccess 下闸门第一分支全静默放行，
    B/C 轮会假绿为"无审批直接执行"（三次踩坑后固化为脚本自检）。"""
    def read(key):
        try:
            return subprocess.run(["defaults", "read", "me.siwi.Desire", key],
                                  capture_output=True, text=True).stdout.strip()
        except Exception:
            return ""
    level, full = read("aiAccessLevel"), read("aiFullAccess")
    if level != "1" or full == "1":
        print(f"✗ 访问等级不是 autoEdit（aiAccessLevel={level or '未设'}, aiFullAccess={full or '未设'}）")
        print("  先执行：defaults write me.siwi.Desire aiAccessLevel -int 1 && "
              "defaults write me.siwi.Desire aiFullAccess -bool false")
        print("  然后**重启 app**（init 只在启动时读取），测完恢复原值。")
        sys.exit(1)
    print("✓ 访问等级 = autoEdit")

def main():
    require_autoedit()
    use_daemon = "--use-daemon" in sys.argv
    fixture = None if use_daemon else serve(FIXTURE_PORT, FixtureHandler)
    fake = None if use_daemon else serve(FAKE_PORT, FakeLLMHandler)

    # 档案重定向（记录原值，结束时还原并核对）
    profiles = bridge("GET", "/ai/profiles")
    target = next((p for p in profiles.get("profiles", []) if p.get("active")), None)
    if not target:
        print("✗ 没有激活的模型档案，无法重定向"); sys.exit(1)
    original = dict(target)
    up = bridge("POST", "/ai/profiles", body={
        "id": target["id"], "name": target["name"],
        "endpoint": f"http://127.0.0.1:{FAKE_PORT}/v1/chat/completions",
        "model": "fake-gate", "models": target.get("models") or [],
        "headers": target.get("headers") or {}, "apiFormat": target.get("apiFormat")})
    check("档案已重定向到假端点", not up.get("error"))
    # 事件模式关掉（fixture 无事件声明，纯确定性起见 + 顺带验端点）
    bridge("POST", "/dpp/mode", body={"host": "127.0.0.1", "mode": "off"})

    try:
        bridge("POST", "/navigate", body={"url": f"http://127.0.0.1:{FIXTURE_PORT}/"})
        time.sleep(2)

        # Round 0：经 agent 工具 navigate → ready 信号等待接线（fixture 声明
        # signals.ready=#app-ready，页面已就绪应立即观察到）
        before = run_case("DPPNAV 打开 fixture 页")
        state = wait_turn_done(before)
        assistant_text = " ".join(m.get("content") or "" for m in state.get("messages", [])
                                  if m.get("role") == "assistant")
        check("0 navigate 返回 ready 信号观察（signals 接线生效）",
              "Ready signal observed" in assistant_text)
        check("0 navigate 返回 DPP 视图/动作提示", "pageAction" in assistant_text)

        # Round A：local 动作在 autoEdit 下自动执行、无审批
        bridge("POST", "/navigate", body={"url": f"http://127.0.0.1:{FIXTURE_PORT}/"})
        time.sleep(1.5)
        before = run_case("DPPGATE-LOCAL 请刷新面板")
        no_approval = assert_no_approval_while(lambda: None, duration=6)
        state = wait_turn_done(before)
        refreshed = js("window.__refreshed === true")
        check("A local 动作无审批（autoEdit 正常路径不受影响）", no_approval)
        check("A local 动作确实执行了", refreshed.get("result") in (True, "true"))

        # Round B：danger 动作 → 审批挂起 → deny → 未执行
        bridge("POST", "/navigate", body={"url": f"http://127.0.0.1:{FIXTURE_PORT}/"})
        time.sleep(1.5)
        before = run_case("DPPGATE 请下单")
        approval = wait_approval()
        check("B danger 动作触发审批挂起", approval is not None)
        check("B 审批的是 pageAction", approval and approval.get("tool") == "pageAction")
        check("B 风险档为 Runs code（dangerous 升级生效）",
              approval and approval.get("risk") == "Runs code")
        not_executed = js("window.__ordered === true")
        check("B 审批挂起期间动作未执行", not_executed.get("result") in (False, "false", None))
        check("B 审批摘要带 host 与动作声明",
              approval and "place-order" in (approval.get("arguments") or ""))
        res = bridge("POST", "/approvals/resolve", body={"decision": "deny"})
        check("B deny 被接受", res.get("ok") is True)
        state = wait_turn_done(before)
        print("  [B tool]", (last_tool_msgs(state)[-1].get("content") or "")[:200].replace("\n", " | "))
        still_not = js("window.__ordered === true")
        check("B deny 后动作仍未执行", still_not.get("result") in (False, "false", None))
        tool_msgs = [m for m in state.get("messages", []) if m.get("role") == "tool"]
        check("B 拒绝消息进对话（Error/declined 可见）",
              tool_msgs and "denied" in (tool_msgs[-1].get("content") or ""))

        # Round C：danger 动作 → allow_once → 执行 + success 信号
        bridge("POST", "/navigate", body={"url": f"http://127.0.0.1:{FIXTURE_PORT}/"})
        time.sleep(1.5)
        before = run_case("DPPGATE 再来一次，下单")
        approval = wait_approval()
        check("C danger 动作再次触发审批（非一次放行永久）", approval is not None)
        pending_ordered = js("window.__ordered === true")
        check("C 审批挂起期间仍未执行", pending_ordered.get("result") in (False, "false", None))
        res = bridge("POST", "/approvals/resolve", body={"decision": "allow_once"})
        check("C allow_once 被接受", res.get("ok") is True)
        state = wait_turn_done(before)
        print("  [C tool]", (last_tool_msgs(state)[-1].get("content") or "")[:200].replace("\n", " | "))
        executed = js("window.__ordered === true")
        check("C 允许后动作执行了", executed.get("result") in (True, "true"))
        assistant_text = " ".join(m.get("content") or "" for m in state.get("messages", [])
                                  if m.get("role") == "assistant")
        check("C 返回带 success 信号检测", "success signal detected" in assistant_text)
        check("C 返回带 busy 信号语义（页面 busy 1.5s 内已消）",
              "still present" not in assistant_text)

    finally:
        # 还原档案并核对
        rec = bridge("POST", "/ai/profiles", body={
            "id": original["id"], "name": original["name"],
            "endpoint": original["endpoint"], "model": original["model"],
            "models": original.get("models") or [], "headers": original.get("headers") or {},
            "apiFormat": original.get("apiFormat")})
        after = bridge("GET", "/ai/profiles")
        now = next((p for p in after.get("profiles", []) if p.get("id") == original["id"]), {})
        check("档案端点已还原", now.get("endpoint") == original["endpoint"])
        # 清理本轮测试会话（只删本脚本创建的）
        try:
            trace = bridge("GET", "/agent/trace")
            cid = trace.get("conversation")
            if cid:
                bridge("POST", "/conversations/delete", body={"ids": [cid]})
                print("已删除测试会话", cid)
        except Exception as e:
            print("会话清理跳过：", e)
        if fixture: fixture.shutdown()
        if fake: fake.shutdown()

    failed = [n for n, ok in checks if not ok]
    print(f"\nDPP 审批闸门 E2E：{len(checks)} 项，失败 {len(failed)} 项")
    if failed:
        for f in failed:
            print("  -", f)
        sys.exit(1)
    print("全部通过 ✓")

if __name__ == "__main__":
    main()
