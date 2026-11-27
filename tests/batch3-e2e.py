#!/usr/bin/env python3
"""v0.8.81 批 3 端到端（Debug 构建、封闭实例）：

1) 缓存前缀：同一会话两回合的 system 稳定段逐字节一致；消息上有前缀哈希。
2) 审批批量预览：模拟一次审批，桥返回预计放行数与参数形状。
3) 定时任务补跑：每周任务整周错过 → 启动后补跑一次（RunRecord.catchUp），
   且不会在下一个 20s tick 重复；任务行有可见标记。

前置：`tools/launch-hermetic.sh <dataDir>` 启动，桥可达。用法：
python3 tests/batch3-e2e.py [--base http://127.0.0.1:8799]
"""
import argparse
import datetime
import http.server
import json
import threading
import time
import urllib.request

PORT = 8915
checks = []
state = {"bodies": [], "data_dir": "/tmp"}


def ok(label, cond, detail=""):
    checks.append((label, bool(cond)))
    print(("✓ " if cond else "✗ ") + label + ("" if cond or not detail else f" — {detail}"))


def br(base, method, path, body=None, timeout=120):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def sse_events(handler, events):
    body = "".join("data: " + json.dumps(e) + "\n\n" for e in events).encode()
    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def sse(handler, text):
    sse_events(handler, [
        {"id": "x", "model": "fake-b3",
         "choices": [{"index": 0, "delta": {"role": "assistant", "content": text}}]},
        {"choices": [], "usage": {"prompt_tokens": 120, "completion_tokens": 8,
                                  "prompt_tokens_details": {"cached_tokens": 64}}},
    ])


def sse_tools(handler, calls):
    events = [
        {"id": "x", "model": "fake-b3",
         "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": calls},
                      "finish_reason": "tool_calls"}]},
        {"choices": [], "usage": {"prompt_tokens": 120, "completion_tokens": 8}},
    ]
    sse_events(handler, events)


class Fake(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw)
        except Exception:
            payload = {}
        state["bodies"].append(payload)
        messages = payload.get("messages") or []
        system = next((m.get("content") or "" for m in messages
                       if m.get("role") == "system" and isinstance(m.get("content"), str)), "")
        user_text = next((m.get("content") for m in reversed(messages)
                          if m.get("role") == "user" and isinstance(m.get("content"), str)), "")
        if not payload.get("tools"):
            if "自评者" in system or "reviewer" in system:
                sse(self, "答案没有验证工具结果，需要明确说明哪些结论未经验证。")
            elif "修订" in system or "revise" in system.lower():
                sse(self, "REVISED-ANSWER")
            else:
                sse(self, "TITLE")
        elif "REV-PROBE" in user_text:
            already_ran = any(m.get("role") == "tool" for m in messages)
            if already_ran:
                sse(self, "ORIGINAL-ANSWER")
            else:
                sse_tools(self, [
                    {"index": i, "id": f"rev_call_{i}", "type": "function",
                     "function": {"name": "readFile",
                                  "arguments": json.dumps({"path": f"{state['data_dir']}/agent-workspace/missing-{i}.txt"})}}
                    for i in range(3)
                ])
        elif "PFX-ONE" in user_text:
            sse(self, "ACK-ONE")
        elif "PFX-TWO" in user_text:
            sse(self, "ACK-TWO")
        elif "PFX-CATCHUP" in user_text:
            sse(self, "CATCHUP-DONE")
        else:
            sse(self, "OK")


def stable_prefix(system):
    marker = "\n\n<environment>"
    pos = system.find(marker)
    return system[:pos] if pos >= 0 else system[:24000]


def wait_for(fn, timeout=60, interval=0.5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(interval)
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8799")
    args = parser.parse_args()
    base = args.base
    startup = (br(base, "GET", "/state").get("startup") or {})
    ok("封闭实例（存储/偏好/密钥三项隔离）",
       startup.get("dataDir") and startup.get("prefs") == "isolated" and startup.get("secrets") == "file",
       str(startup))

    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Fake)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    state["data_dir"] = startup.get("dataDir") or "/tmp"
    # 本套件只跑模型/调度，不需要浏览器；若用户锁屏，调试开关放行定时任务
    # （实际产品语义仍由 SessionGuard 决定，batch6 专测锁屏挂起）。
    br(base, "POST", "/diag/screen-lock", {"locked": False})
    # 评估/多回合会话会累计 token；先放开预算，结束恢复原值。
    budget_before = (br(base, "GET", "/agent/budget").get("budget") or 0)
    br(base, "POST", "/agent/budget", {"tokens": 100000})
    previous_active = br(base, "GET", "/ai/profiles").get("active")
    profile_id = None
    task = f"b3-catchup-{int(time.time()) % 100000}"
    task2 = task + "-off"
    try:
        created = br(base, "POST", "/ai/profiles", {
            "name": f"b3-{task}",
            "endpoint": f"http://127.0.0.1:{PORT}/v1/chat/completions",
            "model": "fake-b3",
            "key": "b3-key-1234567890",
            "apiFormat": "openai",
        })
        profile_id = created.get("id")
        if profile_id:
            br(base, "POST", "/ai/profiles/activate", {"id": profile_id})

        # 1. 缓存前缀：两回合稳定段一致（抓假端点请求体）。
        br(base, "POST", "/agent/send", {"text": "PFX-ONE"})
        ok("缓存前缀：第一回合完成",
           wait_for(lambda: any(m.get("content") == "ACK-ONE"
                                for m in br(base, "GET", "/agent/messages").get("messages", [])), 60) is not None)
        br(base, "POST", "/agent/send", {"text": "PFX-TWO"})
        ok("缓存前缀：第二回合完成",
           wait_for(lambda: any(m.get("content") == "ACK-TWO"
                                for m in br(base, "GET", "/agent/messages").get("messages", [])), 60) is not None)
        bodies = [b for b in state["bodies"] if b.get("tools")]
        one = next((b for b in bodies if "PFX-ONE" in
                    next((m.get("content") for m in reversed(b.get("messages") or [])
                          if m.get("role") == "user" and isinstance(m.get("content"), str)), "")), None)
        two = next((b for b in bodies if "PFX-TWO" in
                    next((m.get("content") for m in reversed(b.get("messages") or [])
                          if m.get("role") == "user" and isinstance(m.get("content"), str)), "")), None)
        prefix_one = stable_prefix(next((m.get("content") or "" for m in (one or {}).get("messages", [])
                                         if m.get("role") == "system"), "")) if one else ""
        prefix_two = stable_prefix(next((m.get("content") or "" for m in (two or {}).get("messages", [])
                                         if m.get("role") == "system"), "")) if two else ""
        ok("缓存前缀：两回合 system 稳定段逐字节一致",
           bool(prefix_one) and prefix_one == prefix_two,
           f"len1={len(prefix_one)} len2={len(prefix_two)}")
        messages = br(base, "GET", "/agent/messages").get("messages", [])
        hashed = [m for m in messages if m.get("promptPrefixHash")]
        reasons = [m.get("promptPrefixChanged") for m in hashed]
        ok("缓存前缀：哈希随消息落盘，首回合标 first、次回合未标变化",
           len(hashed) >= 2 and "first" in reasons and reasons[-1] is None,
           f"reasons={reasons}")

        # 2. 审批批量预览：先压到"逐次确认"（封闭实例默认可能允许自动编辑），
        #    再伪造"本轮还有 3 条同形状调用"。
        br(base, "POST", "/agent/send", {"text": "/access confirm"})
        time.sleep(1.0)
        br(base, "POST", "/approvals/simulate", {
            "tool": "addBookmark",
            "arguments": json.dumps({"url": "https://example.com/a", "title": "A"}),
            "risk": "dangerous",
            "batchCandidates": 3,
        })
        pending = wait_for(lambda: (lambda p: p if p.get("pending") else None)(
            br(base, "GET", "/approvals")), 20) or {}
        ok("审批批量：预览数/参数形状/上限可见",
           pending.get("batchCandidateCount") == 3
           and pending.get("batchArgumentKeys") == ["title", "url"]
           and pending.get("batchLimit") == 8,
           json.dumps(pending, ensure_ascii=False)[:300])
        br(base, "POST", "/approvals/resolve", {"decision": "deny"})

        # 3. 修订可见性：三次失败工具调用 → 自评 → 有界修订 → diff/撤销。
        br(base, "POST", "/agent/send", {"text": "REV-PROBE"})
        revised = wait_for(lambda: next((m for m in br(base, "GET", "/agent/messages").get("messages", [])
                                         if m.get("content") == "REVISED-ANSWER" and m.get("wasRevised")),
                                        None), 120)
        ok("修订：自评后自动修订并保留原文",
           bool(revised) and (revised.get("originalAnswerLength") or 0) > 0
           and bool(revised.get("critique")),
           json.dumps(revised, ensure_ascii=False)[:300] if revised else "no revised message")
        if revised:
            undone = br(base, "POST", "/agent/revision/undo", {"message": revised["id"]})
            after = next((m for m in br(base, "GET", "/agent/messages").get("messages", [])
                          if m.get("id") == revised["id"]), {})
            ok("修订：撤销恢复原文并清标记",
               undone.get("ok") is True and after.get("content") == "ORIGINAL-ANSWER"
               and not after.get("wasRevised") and not after.get("originalAnswerLength"),
               json.dumps(after, ensure_ascii=False)[:300])
        else:
            ok("修订：撤销恢复原文并清标记", False, "revision did not happen")

        # 4. 每周任务补跑：把 lastFiredAt 锚到三周前，应跑时刻是 1 小时前。
        now = datetime.datetime.now().astimezone()
        scheduled = (now - datetime.timedelta(hours=1)).replace(second=0, microsecond=0)
        # Python Monday=0 → Calendar 1=Sunday…7=Saturday
        weekday = (scheduled.weekday() + 1) % 7 + 1
        seeded = (scheduled - datetime.timedelta(weeks=3)).isoformat()
        made = br(base, "POST", "/agent/tasks/create", {
            "name": task,
            "prompt": "PFX-CATCHUP",
            "weekday": weekday,
            "hour": scheduled.hour,
            "minute": scheduled.minute,
            "lastFiredAt": seeded,
        })
        ok("补跑：每周任务创建（可回填 lastFiredAt）", made.get("ok") is True, str(made)[:200])
        deadline = time.time() + 45
        first_seen = None
        while time.time() < deadline:
            hits = [b for b in state["bodies"] if b.get("tools") and "PFX-CATCHUP" in
                    next((m.get("content") for m in reversed(b.get("messages") or [])
                          if m.get("role") == "user" and isinstance(m.get("content"), str)), "")]
            if hits:
                first_seen = time.time()
                break
            time.sleep(0.5)
        ok("补跑：启动后的下一个 tick 自动补跑一次", first_seen is not None)
        runs = br(base, "GET", "/agent/tasks").get("runs", [])
        catch_runs = [r for r in runs if r.get("task") == task and r.get("catchUp")]
        def caught_up_row():
            return next((t for t in br(base, "GET", "/agent/tasks").get("tasks", [])
                         if t.get("name") == task
                         and ("caught up" in (t.get("lastResult") or "").lower()
                              or "补跑" in (t.get("lastResult") or ""))), None)
        row = wait_for(caught_up_row, 10) or {}
        ok("补跑：RunRecord 标记 catchUp + scheduledFor；任务行可见",
           len(catch_runs) == 1 and catch_runs[0].get("scheduledFor") and bool(row),
           json.dumps(catch_runs[:1], ensure_ascii=False)[:300])

        # 再等一个 20s tick：补跑不能变成每 tick 重复。
        before = len([b for b in state["bodies"] if b.get("tools") and "PFX-CATCHUP" in
                      next((m.get("content") for m in reversed(b.get("messages") or [])
                            if m.get("role") == "user" and isinstance(m.get("content"), str)), "")])
        time.sleep(22)
        after = len([b for b in state["bodies"] if b.get("tools") and "PFX-CATCHUP" in
                     next((m.get("content") for m in reversed(b.get("messages") or [])
                           if m.get("role") == "user" and isinstance(m.get("content"), str)), "")])
        ok("补跑：同一应跑时刻只补一次（下一个 tick 不重复）",
           before == 1 and after == 1, f"before={before} after={after}")
    finally:
        try:
            br(base, "POST", "/agent/tasks/remove", {"name": task})
            br(base, "POST", "/agent/tasks/remove", {"name": task2})
            if previous_active:
                br(base, "POST", "/ai/profiles/activate", {"id": previous_active})
            if profile_id:
                br(base, "POST", "/ai/profiles/delete", {"id": profile_id})
            br(base, "POST", "/agent/budget", {"tokens": budget_before})
            br(base, "POST", "/diag/screen-lock", {})
        except Exception:
            pass
        server.shutdown()

    passed = sum(1 for _, cond in checks if cond)
    print("\nv0.8.81 批 3：%d/%d 通过" % (passed, len(checks)))
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
