#!/usr/bin/env python3
"""v0.8.80 批 6 端到端：

1) 存储：`GET /diag/storage` 按域报表 + 清理翻译缓存。
2) 上下文预算：手动预算/触发阈值经桥写入并读回（按档案持久化）。
3) Doctor：稳定 id、可修复项、清理转存动作；`/diag/health` 带 screenLocked。
4) 锁屏守卫：模拟锁屏下定时任务不投递，解锁后自动重放。

前置：封闭实例在前台。用法：python3 tests/batch6-e2e.py [--base http://127.0.0.1:8799]
"""
import argparse
import http.server
import json
import threading
import time
import urllib.request

LOCK_PORT = 8914
checks = []
state = {"prompts": []}


def ok(label, cond, detail=""):
    checks.append((label, bool(cond)))
    print(("✓ " if cond else "✗ ") + label + ("" if cond or not detail else f" — {detail}"))


def br(base, method, path, body=None, timeout=120):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def sse(handler, text):
    body = (
        'data: ' + json.dumps({"id": "x", "model": "fake-lock",
                               "choices": [{"index": 0, "delta": {"role": "assistant",
                                                                  "content": text}}]}) + '\n\n'
        'data: ' + json.dumps({"choices": [], "usage": {"prompt_tokens": 20,
                                                        "completion_tokens": 5}}) + '\n\n'
        'data: [DONE]\n\n'
    ).encode()
    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


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
        messages = payload.get("messages") or []
        user_text = next((m.get("content") for m in reversed(messages)
                          if m.get("role") == "user" and isinstance(m.get("content"), str)), "")
        if payload.get("tools") and "LOCK-PROBE" in user_text:
            state["prompts"].append(user_text)
            sse(self, "LOCK-DONE")
        else:
            sse(self, "TITLE")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8799")
    args = parser.parse_args()
    base = args.base
    startup = (br(base, "GET", "/state").get("startup") or {})
    ok("封闭实例（存储/偏好/密钥三项隔离）",
       startup.get("dataDir") and startup.get("prefs") == "isolated" and startup.get("secrets") == "file",
       str(startup))
    ok("实例在前台", br(base, "GET", "/state").get("isActive") is True, "先 osascript activate")

    server = http.server.ThreadingHTTPServer(("127.0.0.1", LOCK_PORT), Fake)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    previous_active = br(base, "GET", "/ai/profiles").get("active")
    profile_id = None
    task = f"b6-lock-{int(time.time()) % 100000}"
    try:
        # 1. 存储
        storage = br(base, "GET", "/diag/storage")
        ids = {d.get("id") for d in storage.get("domains", [])}
        ok("存储：按域报表（会话/归档/翻译缓存/转存/续传）",
           {"conversations", "archives", "translations", "toolResults",
            "downloadResume", "batchLogs"}.issubset(ids)
           and isinstance(storage.get("totalBytes"), int),
           json.dumps(sorted(ids))[:300])
        cleaned = br(base, "POST", "/diag/storage/clean", {"domain": "translations"})
        after = br(base, "GET", "/diag/storage")
        trans = next((d for d in after.get("domains", []) if d.get("id") == "translations"), {})
        ok("存储：翻译缓存可清理（清后为 0）",
           cleaned.get("ok") is True and trans.get("bytes") == 0,
           json.dumps(cleaned, ensure_ascii=False)[:200])

        # 2. 上下文预算
        default_budget = br(base, "GET", "/ai/context-budget")
        set_budget = br(base, "POST", "/ai/context-budget",
                        {"chars": 120000, "triggerPercent": 0.9})
        read_budget = br(base, "GET", "/ai/context-budget")
        ok("上下文预算：手动值 + 触发阈值按档案持久化",
           default_budget.get("ok") is True
           and set_budget.get("chars") == 120000
           and read_budget.get("chars") == 120000
           and abs((read_budget.get("triggerPercent") or 0) - 0.9) < 0.001,
           json.dumps(read_budget, ensure_ascii=False)[:300])
        cleared_budget = br(base, "POST", "/ai/context-budget", {"chars": None})
        ok("上下文预算：清手动值回到自动", cleared_budget.get("chars") in (None, "null") or
           cleared_budget.get("chars") is None, str(cleared_budget)[:200])
        br(base, "POST", "/ai/context-budget", {"triggerPercent": 0.85})

        # 3. Doctor / 健康
        doctor = br(base, "GET", "/agent/doctor")
        checks_list = doctor.get("checks") or []
        ids = [c.get("id") for c in checks_list]
        ok("Doctor：检查项有唯一稳定 id",
           len(checks_list) > 0 and len(ids) == len(set(ids)) and all(ids),
           f"ids={ids[:6]}...")
        ok("Doctor：至少一项带一键修复",
           any(c.get("fix") for c in checks_list),
           json.dumps(checks_list[:3], ensure_ascii=False)[:300])
        fix = br(base, "POST", "/agent/doctor/fix", {"action": "clearSpills"})
        ok("Doctor：清理转存动作可执行", fix.get("ok") is True and bool(fix.get("message")),
           str(fix)[:200])
        health = br(base, "GET", "/diag/health")
        ok("/diag/health：带 screenLocked", health.get("screenLocked") is False,
           str(health.get("screenLocked")))

        # 4. 锁屏守卫
        created = br(base, "POST", "/ai/profiles", {
            "name": f"b6-lock-{task}",
            "endpoint": f"http://127.0.0.1:{LOCK_PORT}/v1/chat/completions",
            "model": "fake-lock",
            "key": "b6-key-1234567890",
            "apiFormat": "openai",
        })
        profile_id = created.get("id")
        if profile_id:
            br(base, "POST", "/ai/profiles/activate", {"id": profile_id})
        br(base, "POST", "/agent/tasks/create", {"name": task, "prompt": "LOCK-PROBE", "minutes": 120})
        locked = br(base, "POST", "/diag/screen-lock", {"locked": True})
        ok("锁屏：模拟标志生效", locked.get("screenLocked") is True, str(locked)[:120])
        br(base, "POST", "/agent/tasks/fire", {"name": task})
        time.sleep(2.0)
        ok("锁屏：任务被挂起（未投递）", state["prompts"] == [], f"prompts={len(state['prompts'])}")
        row = next((t for t in br(base, "GET", "/agent/tasks").get("tasks", [])
                    if t.get("name") == task), {})
        ok("锁屏：任务卡显示 deferred",
           "deferred" in (row.get("lastResult") or "").lower()
           or "锁屏" in (row.get("lastResult") or ""),
           json.dumps(row, ensure_ascii=False)[:250])
        unlocked = br(base, "POST", "/diag/screen-lock", {"locked": False})
        deadline = time.time() + 30
        while time.time() < deadline and not state["prompts"]:
            time.sleep(0.5)
        ok("解锁：任务自动重放",
           unlocked.get("screenLocked") is False and state["prompts"] != [],
           f"prompts={len(state['prompts'])}")
        br(base, "POST", "/diag/screen-lock", {})
    finally:
        try:
            br(base, "POST", "/diag/screen-lock", {})
            br(base, "POST", "/agent/tasks/remove", {"name": task})
            if previous_active:
                br(base, "POST", "/ai/profiles/activate", {"id": previous_active})
            if profile_id:
                br(base, "POST", "/ai/profiles/delete", {"id": profile_id})
            br(base, "POST", "/ai/context-budget", {"chars": None, "triggerPercent": 0.85})
        except Exception:
            pass
        server.shutdown()

    passed = sum(1 for _, cond in checks if cond)
    print("\nv0.8.80 批 6：%d/%d 通过" % (passed, len(checks)))
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
