#!/usr/bin/env python3
"""Agent 工具隔离世界迁移回归：getPageSnapshot / click（__desire* 函数路径）。"""
import json, sys, time, urllib.request
BRIDGE = "http://127.0.0.1:8799"
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def bridge(method, path, body=None, timeout=15):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BRIDGE + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with opener.open(req, timeout=timeout) as r:
        return json.loads(r.read().decode())

checks = []
def check(name, cond):
    checks.append((name, bool(cond)))
    print(("✓ " if cond else "✗ ") + name)

def js(expr):
    return bridge("POST", "/execute", body={"js": expr})

def run_case(prompt, timeout=60):
    before = {m.get("id") for m in bridge("GET", "/agent/messages").get("messages", [])}
    bridge("POST", "/agent/send", body={"text": prompt})
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = bridge("GET", "/agent/messages")
        fresh = [m for m in state.get("messages", []) if m.get("id") not in before]
        if any(m.get("role") == "assistant" and m.get("content") for m in fresh) and not state.get("busy"):
            time.sleep(0.5)
            state = bridge("GET", "/agent/messages")
            fresh = [m for m in state.get("messages", []) if m.get("id") not in before]
            if any(m.get("role") == "assistant" and m.get("content") for m in fresh) and not state.get("busy"):
                return state
        time.sleep(0.5)
    raise TimeoutError(prompt)

def tool_text(state):
    tools = [m.get("content") or "" for m in state.get("messages", []) if m.get("role") == "tool"]
    return tools[-1] if tools else ""

def main():
    profiles = bridge("GET", "/ai/profiles")
    target = next(p for p in profiles["profiles"] if p.get("active"))
    original = dict(target)
    bridge("POST", "/ai/profiles", body={
        "id": target["id"], "name": target["name"],
        "endpoint": "http://127.0.0.1:8880/v1/chat/completions",
        "model": "fake-gate", "models": target.get("models") or [],
        "headers": target.get("headers") or {}, "apiFormat": target.get("apiFormat")})
    try:
        bridge("POST", "/navigate", body={"url": "http://127.0.0.1:8877/"})
        time.sleep(2)
        before = run_case("DPPSNAP 快照页面")
        text = tool_text(bridge("GET", "/agent/messages"))
        check("getPageSnapshot 在隔离世界正常（标题/元素/文本齐）",
              '"title"' in text and '"elements"' in text and "Order" in text)
        check("快照带 viewport 几何", '"viewport"' in text)

        before = run_case("DPPSNAP-CLICK 点第一个元素")
        text2 = tool_text(bridge("GET", "/agent/messages"))
        check("__desireClick 隔离世界正常", "clicked" in text2.lower() or "ok" in text2.lower())
    finally:
        bridge("POST", "/ai/profiles", body={
            "id": original["id"], "name": original["name"],
            "endpoint": original["endpoint"], "model": original["model"],
            "models": original.get("models") or [], "headers": original.get("headers") or {},
            "apiFormat": original.get("apiFormat")})
        after = bridge("GET", "/ai/profiles")
        now = next(p for p in after["profiles"] if p["id"] == original["id"])
        check("档案已还原", now["endpoint"] == original["endpoint"])
        try:
            trace = bridge("GET", "/agent/trace")
            if trace.get("conversation"):
                bridge("POST", "/conversations/delete", body={"ids": [trace["conversation"]]})
        except Exception:
            pass
    failed = [n for n, ok in checks if not ok]
    print(f"\n工具迁移回归：{len(checks)} 项，失败 {len(failed)} 项")
    if failed:
        for f in failed: print("  -", f)
        sys.exit(1)
    print("全部通过 ✓")

if __name__ == "__main__":
    main()
