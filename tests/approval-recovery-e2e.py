#!/usr/bin/env python3
"""待批审批跨重启（v0.8.80 批 3）：回合停在审批卡时优雅退出 → 重启 → 打开该会话
→ 面板/桥看到 recovered 快照 → 允许并续跑 → 同形状调用被恢复授权自动放行。

前置：封闭实例（tools/launch-hermetic.sh）；可用 --app 指定重启用的 Desire.app。
用法：python3 tests/approval-recovery-e2e.py [--base http://127.0.0.1:8799] [--app /path/Desire.app]
"""
import argparse
import glob
import http.server
import json
import os
import subprocess
import threading
import time
import urllib.request

PORT = 8910
checks = []
state = {"main_calls": 0}


def ok(label, cond, detail=""):
    checks.append((label, bool(cond)))
    print(("✓ " if cond else "✗ ") + label + ("" if cond or not detail else f" — {detail}"))


def br(base, method, path, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def wait_bridge(base, timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            return br(base, "GET", "/state", timeout=3)
        except Exception:
            time.sleep(0.5)
    return None


def instance_pids(data_dir):
    pids = []
    for pid in subprocess.run(["pgrep", "-x", "Desire"], capture_output=True, text=True).stdout.split():
        args = subprocess.run(["ps", "-o", "args=", "-p", pid], capture_output=True, text=True).stdout
        if f"--data-dir={data_dir}" in args:
            pids.append(pid)
    return pids


def app_bundle(explicit):
    if explicit:
        return explicit
    hits = sorted(glob.glob(os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/Desire-*/Build/Products/Debug/Desire.app")))
    return hits[-1] if hits else None


def sse(handler, events):
    body = "".join("data: " + json.dumps(e) + "\n\n" for e in events).encode()
    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream")
    handler.send_header("Content-Length", str(len(body)))
    self_end = handler.wfile
    self_end.write(body)


class Fake(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        model = "fake-recovery"
        if state["main_calls"] == 0:
            state["main_calls"] = 1
            sse(self, [
                {"id": "x", "model": model,
                 "choices": [{"index": 0,
                              "delta": {"role": "assistant",
                                        "tool_calls": [{"index": 0, "id": "call_recover", "type": "function",
                                                        "function": {"name": "addQuickDial",
                                                                     "arguments": json.dumps(
                                                                         {"title": "recover-a",
                                                                          "url": "https://recover-a.example/"})}}]},
                              "finish_reason": "tool_calls"}]},
                {"id": "x", "model": model, "choices": [],
                 "usage": {"prompt_tokens": 90, "completion_tokens": 8}},
            ])
            return
        if state["main_calls"] == 1:
            # 重启后续跑：模型重发同形状调用（应被恢复授权自动放行）
            state["main_calls"] = 2
            sse(self, [
                {"id": "x", "model": model,
                 "choices": [{"index": 0,
                              "delta": {"role": "assistant",
                                        "tool_calls": [{"index": 0, "id": "call_recover2", "type": "function",
                                                        "function": {"name": "addQuickDial",
                                                                     "arguments": json.dumps(
                                                                         {"title": "recover-b",
                                                                          "url": "https://recover-b.example/"})}}]},
                              "finish_reason": "tool_calls"}]},
                {"id": "x", "model": model, "choices": [],
                 "usage": {"prompt_tokens": 110, "completion_tokens": 8}},
            ])
            return
        state["main_calls"] += 1
        sse(self, [
            {"id": "x", "model": model,
             "choices": [{"index": 0, "delta": {"role": "assistant", "content": "RECOVERED-DONE"}}]},
            {"id": "x", "model": model, "choices": [],
             "usage": {"prompt_tokens": 130, "completion_tokens": 6}},
        ])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8799")
    parser.add_argument("--app", default=None)
    args = parser.parse_args()
    base = args.base

    state0 = wait_bridge(base, 5)
    if not state0:
        print("✗ 桥不可达——先用 tools/launch-hermetic.sh 启动封闭实例")
        return 2
    startup = state0.get("startup") or {}
    if not (startup.get("dataDir") and startup.get("prefs") == "isolated" and startup.get("secrets") == "file"):
        print("✗ 需要封闭实例（dataDir / prefs=isolated / secrets=file）")
        return 2
    data_dir = startup["dataDir"]
    app = app_bundle(args.app)
    if not app or not os.path.isdir(app):
        print("✗ 找不到用于重启的构建（--app 指定 Desire.app）")
        return 2

    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Fake)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    tag = "%d" % (int(time.time()) % 1000000)
    previous_active = br(base, "GET", "/ai/profiles").get("active")
    profile_id = None
    conversation_id = None
    try:
        br(base, "POST", "/agent/send", {"text": "/access confirm"})
        time.sleep(0.4)
        created = br(base, "POST", "/ai/profiles", {
            "name": f"recover-{tag}",
            "endpoint": f"http://127.0.0.1:{PORT}/v1/chat/completions",
            "model": "fake-recovery",
            "key": "recover-key-1234567890",
            "apiFormat": "openai",
        })
        profile_id = created.get("id")
        ok("临时档案创建", bool(profile_id), str(created))
        if profile_id:
            br(base, "POST", "/ai/profiles/activate", {"id": profile_id})
        br(base, "POST", "/agent/new", {})
        probe = f"recover probe {tag}"
        br(base, "POST", "/agent/send", {"text": probe})

        pending = None
        deadline = time.time() + 30
        while time.time() < deadline:
            body = br(base, "GET", "/agent/approvals")
            if body.get("pending"):
                pending = body
                break
            time.sleep(0.2)
        ok("回合停在审批卡", bool(pending) and pending.get("tool") == "addQuickDial",
           json.dumps(pending or {}, ensure_ascii=False)[:200])

        # 会话文件里应有 turnActive + pendingApproval 快照
        snapshot = None
        deadline = time.time() + 10
        while time.time() < deadline:
            for path in sorted(glob.glob(os.path.join(data_dir, "storage", "conversation-*.json")),
                               key=os.path.getmtime, reverse=True)[:8]:
                try:
                    conv = json.load(open(path, encoding="utf-8"))
                except Exception:
                    continue
                if any(probe in (m.get("content") or "") for m in conv.get("messages", [])):
                    conversation_id = conv.get("id")
                    snapshot = conv.get("pendingApproval")
                    if snapshot:
                        break
            if snapshot:
                break
            time.sleep(0.3)
        ok("待批快照随会话落盘（工具+参数+站点）",
           bool(snapshot) and snapshot.get("toolName") == "addQuickDial"
           and "url" in (snapshot.get("argumentsJSON") or ""),
           json.dumps(snapshot or {}, ensure_ascii=False)[:300])

        try:
            br(base, "POST", "/app/quit", timeout=10)
        except Exception:
            pass
        deadline = time.time() + 30
        while time.time() < deadline and instance_pids(data_dir):
            time.sleep(0.5)
        ok("退出：进程已优雅退出", not instance_pids(data_dir))

        subprocess.run(["open", "-g", app, "--args", "--automation", f"--data-dir={data_dir}"], check=True)
        state2 = wait_bridge(base, 90)
        ok("重启：桥回来了", state2 is not None)
        # 重启后模型档案与 Key 仍在（封闭实例的文件库）
        if profile_id:
            br(base, "POST", "/ai/profiles/activate", {"id": profile_id})

        if conversation_id:
            opened = br(base, "POST", "/agent/open", {"conversationId": conversation_id})
            ok("重启：打开被打断的会话", opened.get("ok") is not False, json.dumps(opened)[:200])
        recovered = br(base, "GET", "/agent/approvals")
        ok("重启：待批快照恢复为 recovered",
           recovered.get("recovered") is True and recovered.get("tool") == "addQuickDial",
           json.dumps(recovered, ensure_ascii=False)[:300])

        resolved = br(base, "POST", "/agent/approvals/resolve", {"decision": "recoveredAllow"})
        ok("恢复：允许并续跑", resolved.get("ok") is True, str(resolved)[:200])
        # 续跑：模型重发同形状调用 → 自动放行；若又弹审批就是恢复授权没生效
        approval_after = 0
        deadline = time.time() + 60
        while time.time() < deadline:
            body = br(base, "GET", "/agent/approvals")
            if body.get("pending"):
                approval_after += 1
                br(base, "POST", "/agent/approvals/resolve", {"decision": "deny"})
            if not br(base, "GET", "/agent/messages").get("busy"):
                break
            time.sleep(0.2)
        ok("续跑：同形状调用不再弹审批", approval_after == 0, f"approvals={approval_after}")

        deadline = time.time() + 30
        final = ""
        while time.time() < deadline:
            for path in sorted(glob.glob(os.path.join(data_dir, "storage", "conversation-*.json")),
                               key=os.path.getmtime, reverse=True)[:8]:
                try:
                    conv = json.load(open(path, encoding="utf-8"))
                except Exception:
                    continue
                if conv.get("id") != conversation_id:
                    continue
                final = next((m.get("content") or "" for m in reversed(conv.get("messages", []))
                              if m.get("role") == "assistant" and "RECOVERED-DONE" in (m.get("content") or "")), "")
                if final:
                    ok("续跑：终答产出", True)
                    ok("续跑：快照已清除", conv.get("pendingApproval") is None)
                    break
            if final:
                break
            time.sleep(0.4)
        if not final:
            ok("续跑：终答产出", False, "RECOVERED-DONE 未出现")
        history = br(base, "GET", "/approvals/history?count=20").get("history", [])
        ok("恢复审批写审计行",
           any("recovered approval" in (h.get("decision") or "") for h in history),
           json.dumps(history[:6], ensure_ascii=False)[:300])
    finally:
        try:
            for dial in ("https://recover-a.example/", "https://recover-b.example/"):
                br(base, "POST", "/quickdial/delete", {"url": dial})
        except Exception:
            pass
        try:
            br(base, "POST", "/agent/cancel")
        except Exception:
            pass
        try:
            if previous_active:
                br(base, "POST", "/ai/profiles/activate", {"id": previous_active})
            if profile_id:
                br(base, "POST", "/ai/profiles/delete", {"id": profile_id})
        except Exception:
            pass
        server.shutdown()

    passed = sum(1 for _, cond in checks if cond)
    print("\n待批审批跨重启：%d/%d 通过" % (passed, len(checks)))
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
