#!/usr/bin/env python3
"""v0.8.80 批 3 Agent 旗舰的端到端：

1. 成本/延迟**建议**（只读）：填单价 → /ai/routing/advice 给出更便宜的模型与省下比例；
   采纳 = 显式切换（建议本身不换）。
2. 审批批处理：两个同形状的 addQuickDial 调用 → 第一次「批准本轮剩余」后不再弹卡；
   审计行写明 rest of turn。
3. 自评后一次有界修订：3 个失败工具调用 → 自评指出问题 → 一次修订 → 终答替换，
   消息标记 wasRevised，修订用量入账 kind=revision。

前置：封闭实例（tools/launch-hermetic.sh）。用法：
    python3 tests/agent-batch3-e2e.py [--base http://127.0.0.1:8799]
"""
import argparse
import glob
import http.server
import json
import os
import threading
import time
import urllib.request

APPROVAL_PORT = 8908
REVISION_PORT = 8909
checks = []
state = {"approval_calls": 0, "revision_calls": 0}


def ok(label, cond, detail=""):
    checks.append((label, bool(cond)))
    print(("✓ " if cond else "✗ ") + label + ("" if cond or not detail else f" — {detail}"))


def br(base, method, path, body=None, timeout=120):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def wait_idle(base, timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not br(base, "GET", "/agent/messages").get("busy"):
            return True
        time.sleep(0.3)
    return False


def wait_pending(base, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        body = br(base, "GET", "/agent/approvals")
        if body.get("pending"):
            return body
        time.sleep(0.2)
    return None


def read_conversation(data_dir, probe, timeout=40, predicate=None):
    deadline = time.time() + timeout
    latest = {}
    while time.time() < deadline:
        paths = sorted(glob.glob(os.path.join(data_dir, "storage", "conversation-*.json")),
                       key=os.path.getmtime, reverse=True)
        for path in paths[:10]:
            try:
                with open(path, encoding="utf-8") as fh:
                    conv = json.load(fh)
            except Exception:
                continue
            if not any(probe in (m.get("content") or "") for m in conv.get("messages", [])):
                continue
            latest = conv
            if predicate is None or predicate(conv):
                return conv
        time.sleep(0.4)
    return latest


def sse(handler, events):
    body = "".join("data: " + json.dumps(e) + "\n\n" for e in events).encode()
    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def text_events(text, model):
    return [
        {"id": "x", "model": model,
         "choices": [{"index": 0, "delta": {"role": "assistant", "content": text}}]},
        {"id": "x", "model": model, "choices": [],
         "usage": {"prompt_tokens": 120, "completion_tokens": 8}},
    ]


def tool_events(call_id, name, args, model):
    return [
        {"id": "x", "model": model,
         "choices": [{"index": 0,
                      "delta": {"role": "assistant",
                                "tool_calls": [{"index": 0, "id": call_id, "type": "function",
                                                "function": {"name": name,
                                                             "arguments": json.dumps(args)}}]},
                      "finish_reason": "tool_calls"}]},
        {"id": "x", "model": model, "choices": [],
         "usage": {"prompt_tokens": 100, "completion_tokens": 12}},
    ]


class ApprovalFake(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw)
        except Exception:
            payload = {}
        model = "fake-batch3-approval"
        tools = payload.get("tools") or []
        if not tools:
            sse(self, text_events("BATCH3-TITLE", model))
            return
        state["approval_calls"] += 1
        if state["approval_calls"] == 1:
            sse(self, tool_events("call_q1", "addQuickDial",
                                  {"title": "batch3-a", "url": "https://batch3-a.example/"}, model))
        elif state["approval_calls"] == 2:
            sse(self, tool_events("call_q2", "addQuickDial",
                                  {"title": "batch3-b", "url": "https://batch3-b.example/"}, model))
        else:
            sse(self, text_events("BATCH3-ADDED", model))


class RevisionFake(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw)
        except Exception:
            payload = {}
        model = "fake-batch3-revision"
        tools = payload.get("tools") or []
        system = ""
        messages = payload.get("messages") or []
        if messages and messages[0].get("role") == "system":
            system = messages[0].get("content") or ""
        if not tools:
            if "自评者" in system:
                sse(self, text_events("1) 结论未验证：没有任何成功证据。", model))
            elif "修订" in system:
                sse(self, text_events("REVISED-ANSWER", model))
            else:
                sse(self, text_events("BATCH3-REVISION-TITLE", model))
            return
        state["revision_calls"] += 1
        if state["revision_calls"] <= 3:
            n = state["revision_calls"]
            sse(self, tool_events(f"call_r{n}", "readFile",
                                  {"path": f"batch3-missing-{n}.txt"}, model))
        else:
            sse(self, text_events("ORIGINAL-ANSWER", model))


def create_profile(base, name, port, model):
    return br(base, "POST", "/ai/profiles", {
        "name": name,
        "endpoint": f"http://127.0.0.1:{port}/v1/chat/completions",
        "model": model,
        "key": "batch3-key-1234567890",
        "apiFormat": "openai",
    }).get("id")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8799")
    args = parser.parse_args()
    base = args.base

    startup = (br(base, "GET", "/state").get("startup") or {})
    ok("封闭实例（存储/偏好/密钥三项隔离）",
       startup.get("dataDir") and startup.get("prefs") == "isolated" and startup.get("secrets") == "file",
       str(startup))
    data_dir = startup.get("dataDir") or ""

    approval_server = http.server.ThreadingHTTPServer(("127.0.0.1", APPROVAL_PORT), ApprovalFake)
    revision_server = http.server.ThreadingHTTPServer(("127.0.0.1", REVISION_PORT), RevisionFake)
    threading.Thread(target=approval_server.serve_forever, daemon=True).start()
    threading.Thread(target=revision_server.serve_forever, daemon=True).start()

    profiles = br(base, "GET", "/ai/profiles")
    previous_active = profiles.get("active")
    created = []
    tag = "%d" % (int(time.time()) % 1000000)
    try:
        # ---- ① 成本/延迟建议（只读） ----
        cheap_id = create_profile(base, f"batch3-cheap-{tag}", APPROVAL_PORT, f"batch3-cheap-{tag}")
        expensive_id = create_profile(base, f"batch3-expensive-{tag}", REVISION_PORT, f"batch3-expensive-{tag}")
        created.extend([x for x in (cheap_id, expensive_id) if x])
        ok("建议：两个临时档案创建", bool(cheap_id and expensive_id))
        if cheap_id and expensive_id:
            br(base, "POST", "/ai/profiles/activate", {"id": expensive_id})
            br(base, "POST", "/ai/prices", {"models": {
                f"batch3-cheap-{tag}": {"input": 0.1, "output": 0.3},
                f"batch3-expensive-{tag}": {"input": 5.0, "output": 15.0},
            }})
            advice = br(base, "GET", "/ai/routing/advice?promptTokens=8000&completionTokens=1000")
            row = next((a for a in advice.get("advice", [])
                        if a.get("model") == f"batch3-cheap-{tag}"), None)
            ok("建议：更便宜的模型被点名，附省下比例与成本",
               advice.get("advisoryOnly") is True and row is not None
               and row.get("kind") == "cheaper"
               and (row.get("savingFraction") or 0) > 0.9
               and row.get("estimatedCost") is not None,
               json.dumps(advice, ensure_ascii=False)[:400])
            ok("建议：只读不切换（仍在贵的档案上）",
               br(base, "GET", "/ai/profiles").get("active") == expensive_id)
            # 采纳 = 显式切换
            br(base, "POST", "/ai/profiles/activate", {"id": cheap_id})
            br(base, "POST", "/ai/model", {"model": f"batch3-cheap-{tag}"})
            after = br(base, "GET", "/ai/profiles")
            cheap_row = next((p for p in after.get("profiles", []) if p.get("id") == cheap_id), {})
            ok("建议：采纳后档案与模型都切过去",
               after.get("active") == cheap_id and cheap_row.get("model") == f"batch3-cheap-{tag}",
               json.dumps(cheap_row, ensure_ascii=False)[:200])
            # 清掉假单价，别在统计页留下 0.1/5.0 的行
            br(base, "POST", "/ai/prices", {"remove": [f"batch3-cheap-{tag}", f"batch3-expensive-{tag}"]})

        # ---- ② 审批批处理 ----
        br(base, "POST", "/agent/send", {"text": "/access confirm"})
        time.sleep(0.4)
        approval_id = create_profile(base, f"batch3-approval-{tag}", APPROVAL_PORT, "fake-batch3-approval")
        if approval_id:
            created.append(approval_id)
            br(base, "POST", "/ai/profiles/activate", {"id": approval_id})
        br(base, "POST", "/agent/new", {})
        probe = f"batch3 approval probe {tag}"
        br(base, "POST", "/agent/send", {"text": probe})
        first = wait_pending(base, 30)
        ok("审批批处理：第一个 addQuickDial 等待批准",
           bool(first) and first.get("tool") == "addQuickDial", json.dumps(first, ensure_ascii=False)[:300])
        approvals_seen = 1 if first else 0
        if first:
            br(base, "POST", "/agent/approvals/resolve", {"decision": "allowTurn"})
        # 等回合结束；期间若再弹一次审批就记下来（批量失败）
        deadline = time.time() + 60
        while time.time() < deadline:
            pending = br(base, "GET", "/agent/approvals")
            if pending.get("pending"):
                approvals_seen += 1
                br(base, "POST", "/agent/approvals/resolve", {"decision": "allowOnce"})
            if not br(base, "GET", "/agent/messages").get("busy"):
                break
            time.sleep(0.2)
        ok("审批批处理：第二次同类调用没有再弹卡", approvals_seen == 1, f"approvals_seen={approvals_seen}")
        conv = read_conversation(data_dir, probe, timeout=30,
                                 predicate=lambda c: any(
                                     m.get("role") == "assistant" and "BATCH3-ADDED" in (m.get("content") or "")
                                     for m in c.get("messages", [])))
        calls = [call for m in conv.get("messages", []) for call in (m.get("toolCalls") or [])]
        results = [m for m in conv.get("messages", []) if m.get("role") == "tool"]
        final = next((m.get("content") or "" for m in reversed(conv.get("messages", []))
                      if m.get("role") == "assistant" and "BATCH3-ADDED" in (m.get("content") or "")), "")
        ok("审批批处理：两个调用都执行了", len(calls) >= 2 and len(results) >= 2 and final == "BATCH3-ADDED",
           f"calls={len(calls)} results={len(results)} final={final!r}")
        history = br(base, "GET", "/approvals/history?count=20").get("history", [])
        ok("审批批处理：审计行写明 rest of turn",
           any("rest of turn" in (h.get("decision") or "") for h in history),
           json.dumps(history[:6], ensure_ascii=False)[:400])
        for dial in ("https://batch3-a.example/", "https://batch3-b.example/"):
            try:
                br(base, "POST", "/quickdial/delete", {"url": dial})
            except Exception:
                pass

        # ---- ③ 自评后一次有界修订 ----
        revision_id = create_profile(base, f"batch3-revision-{tag}", REVISION_PORT, "fake-batch3-revision")
        if revision_id:
            created.append(revision_id)
            br(base, "POST", "/ai/profiles/activate", {"id": revision_id})
        state["revision_calls"] = 0
        br(base, "POST", "/agent/new", {})
        probe2 = f"batch3 revision probe {tag}"
        br(base, "POST", "/agent/send", {"text": probe2})
        conv = read_conversation(data_dir, probe2, timeout=90,
                                 predicate=lambda c: any(
                                     m.get("role") == "assistant" and m.get("wasRevised") is True
                                     for m in c.get("messages", [])))
        assistant = next((m for m in reversed(conv.get("messages", []))
                          if m.get("role") == "assistant" and m.get("wasRevised") is True), None)
        ok("自动修订：终答被修订稿替换", assistant is not None
           and assistant.get("content") == "REVISED-ANSWER"
           and assistant.get("critique"),
           json.dumps(assistant or {}, ensure_ascii=False)[:400])
        ok("自动修订：修订用量入账 kind=revision",
           assistant is not None
           and any(b.get("kind") == "revision" for b in (assistant.get("bypassUsage") or [])),
           json.dumps((assistant or {}).get("bypassUsage") or [], ensure_ascii=False)[:300])
        ok("自动修订：只修订一次（4 次主请求 + 1 次修订调用）",
           state["revision_calls"] == 4, f"revision_calls={state['revision_calls']}")
    finally:
        try:
            if previous_active:
                br(base, "POST", "/ai/profiles/activate", {"id": previous_active})
            for profile_id in created:
                br(base, "POST", "/ai/profiles/delete", {"id": profile_id})
        except Exception:
            pass
        approval_server.shutdown()
        revision_server.shutdown()

    passed = sum(1 for _, cond in checks if cond)
    print("\nv0.8.80 批 3 Agent 旗舰：%d/%d 通过" % (passed, len(checks)))
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
