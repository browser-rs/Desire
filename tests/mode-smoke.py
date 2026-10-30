#!/usr/bin/env python3
"""使用模式冒烟（v0.8.24）：桥级断言，不需要真实鼠标。

前置：Desire 以 --automation 运行。默认只测 browser↔agentFocus（不新建窗口，
不留 Agent 窗口）；`--hybrid` 额外验证混合模式（会开一扇 Agent 窗口）。
退出时恢复原模式。

用法：python3 tests/mode-smoke.py [--base http://127.0.0.1:8799] [--hybrid]
"""
import argparse
import json
import sys
import time
import urllib.request


def call(base, method, path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode() or "{}")


def windows(base):
    data = call(base, "GET", "/diag/windows")
    return [(w.get("role"), w.get("sessionKey", ""), w.get("url", ""), w.get("isKey"))
            for w in data.get("windows", []) if w.get("sessionKey")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8799")
    ap.add_argument("--hybrid", action="store_true")
    args = ap.parse_args()
    base = args.base
    failures = []

    def check(name, ok, detail=""):
        print(("✓ " if ok else "✗ ") + name + ((" — " + detail) if detail else ""))
        if not ok:
            failures.append(name)

    original = call(base, "GET", "/app/mode").get("mode", "browser")
    print("original mode:", original)
    try:
        # browser → agentFocus：只改布局，不新建窗口，key 不变
        before = windows(base)
        key_before = call(base, "GET", "/diag/windows").get("keyWindowTitle", "")
        call(base, "POST", "/app/mode", {"mode": "agentFocus"})
        time.sleep(1.5)
        state = call(base, "GET", "/app/mode")
        check("mode roundtrip", state.get("mode") == "agentFocus", state.get("mode", "?"))
        after = windows(base)
        roles = [w[0] for w in after]
        check("agent pane exists", "agentPane" in roles, str(roles))
        # agentPane 是面板（不是窗口），计数只看 user 角色的真实窗口。
        users_before = [w for w in before if w[0] == "user"]
        users_after = [w for w in after if w[0] == "user"]
        check("no new user window in agentFocus", len(users_before) == len(users_after),
              f"{len(users_before)} → {len(users_after)}")
        key_after = call(base, "GET", "/diag/windows").get("keyWindowTitle", "")
        check("key window unchanged", key_before == key_after,
              f"{key_before!r} → {key_after!r}")
        user_urls_before = [w[2] for w in before if w[0] == "user"]
        user_urls_after = [w[2] for w in after if w[0] == "user"]
        check("user tabs untouched", user_urls_before == user_urls_after,
              f"{user_urls_before} → {user_urls_after}")

        # Peek：请求 → 展开（锁）→ 完成
        call(base, "POST", "/peek", {"action": "request", "reason": "mode-smoke"})
        call(base, "POST", "/peek", {"action": "open"})
        peek = call(base, "GET", "/peek")
        check("peek visible", (peek.get("active") or {}).get("status") == "visible",
              str(peek.get("active")))
        check("surface locked", peek.get("locked", 0) >= 1, str(peek.get("locked")))
        call(base, "POST", "/peek", {"action": "resolve"})
        peek = call(base, "GET", "/peek")
        check("peek resolved", peek.get("active") is None and peek.get("locked") == 0)

        if args.hybrid:
            call(base, "POST", "/app/mode", {"mode": "hybrid"})
            deadline = time.time() + 10
            found = False
            while time.time() < deadline:
                if any(w[0] == "agent" for w in windows(base)):
                    found = True
                    break
                time.sleep(0.5)
            check("hybrid opens agent window", found)
    finally:
        call(base, "POST", "/app/mode", {"mode": original})
        print("restored mode:", original)

    if failures:
        print("FAILED:", ", ".join(failures))
        return 1
    print("mode smoke OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
