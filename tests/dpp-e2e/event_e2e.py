#!/usr/bin/env python3
"""DPP 事件驱动回合真机 E2E（spec §4.5 / PageEventHub 全链）。

链路：IM fixture（DPP events: new-message → .msg.unread）→ 页面内 MutationObserver
0→正 跳变 → postMessage → PageEventHub（auto 档）→ 自动开 Agent 回合 →
假 LLM 收到 "[DPP Event]" 消息并回包 → 对话里可见。

前置：应用 --automation 运行；daemon（8877 fixture / 8880 假 LLM）已起。
档案重定向由本脚本负责记录与还原；访问等级不敏感（事件回合不执行工具）。
"""
import json
import sys
import time
import urllib.request

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

def wait_turn_done(before_ids, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = bridge("GET", "/agent/messages")
        fresh = [m for m in state.get("messages", []) if m.get("id") not in before_ids]
        has_assistant = any(m.get("role") == "assistant" and m.get("content") for m in fresh)
        if has_assistant and not state.get("busy"):
            time.sleep(0.5)
            state = bridge("GET", "/agent/messages")
            fresh = [m for m in state.get("messages", []) if m.get("id") not in before_ids]
            if any(m.get("role") == "assistant" and m.get("content") for m in fresh) and not state.get("busy"):
                return state
        time.sleep(0.5)
    raise TimeoutError("回合超时")

def main():
    # 档案重定向
    profiles = bridge("GET", "/ai/profiles")
    target = next(p for p in profiles["profiles"] if p.get("active"))
    original = dict(target)
    bridge("POST", "/ai/profiles", body={
        "id": target["id"], "name": target["name"],
        "endpoint": "http://127.0.0.1:8880/v1/chat/completions",
        "model": "fake-gate", "models": target.get("models") or [],
        "headers": target.get("headers") or {}, "apiFormat": target.get("apiFormat")})
    # 事件模式 auto（同时验证 /dpp/mode 端点）
    r = bridge("POST", "/dpp/mode", body={"host": "127.0.0.1", "mode": "auto"})
    check("事件模式设为 auto", r.get("mode") == "auto")

    try:
        bridge("POST", "/navigate", body={"url": "http://127.0.0.1:8877/im"})
        time.sleep(2)
        check("IM 页面已加载", js("document.querySelectorAll('.msg').length").get("result") in (1, "1"))

        # 建立会话（fake echo）
        before = {m.get("id") for m in bridge("GET", "/agent/messages").get("messages", [])}
        bridge("POST", "/agent/send", body={"text": "hello"})
        wait_turn_done(before)

        # 注入新消息（0→正 跳变 → observer → PageEventHub → 自动回合）
        injected = js("window.__injectMessage('新审批到达')")
        check("注入未读消息", injected.get("result") in (1, "1"))

        # 轮询事件回合出现
        event_msg = None
        deadline = time.time() + 25
        while time.time() < deadline and event_msg is None:
            state = bridge("GET", "/agent/messages")
            for m in state.get("messages", []):
                if m.get("role") == "user" and "[DPP Event]" in (m.get("content") or ""):
                    event_msg = m
                    break
            if event_msg is None:
                time.sleep(1)
        check("事件自动触发 Agent 回合（[DPP Event] 消息进对话）", event_msg is not None)
        if event_msg:
            check("事件 prompt 带事件名与 host",
                  "new-message" in (event_msg.get("content") or "") and "127.0.0.1" in (event_msg.get("content") or ""))
            check("事件 prompt 带协议摘要（视图/动作名）",
                  "Page protocol:" in (event_msg.get("content") or "")
                  and "views [thread]" in (event_msg.get("content") or ""))

        # 等事件回合完成（fake 对非 DPPGATE 文本回 echo）
        try:
            state = wait_turn_done(before, timeout=30)
            assistant = [m.get("content") or "" for m in state.get("messages", []) if m.get("role") == "assistant"]
            check("事件回合完成（模型收到并回包）", any("echo" in a for a in assistant))
        except TimeoutError:
            check("事件回合完成（模型收到并回包）", False)

        # 防抖：3s 内连续注入不产生第二条事件消息
        before_debounce = {m.get("id") for m in bridge("GET", "/agent/messages").get("messages", [])}
        n_before = sum(1 for m in bridge("GET", "/agent/messages").get("messages", [])
                       if m.get("role") == "user" and "[DPP Event]" in (m.get("content") or ""))
        js("window.__injectMessage('第二条')")
        js("window.__injectMessage('第三条')")
        time.sleep(4)
        n_after = sum(1 for m in bridge("GET", "/agent/messages").get("messages", [])
                      if m.get("role") == "user" and "[DPP Event]" in (m.get("content") or ""))
        check("事件风暴防护生效（防抖窗口内不翻倍）", n_after <= n_before + 1)

    finally:
        bridge("POST", "/ai/profiles", body={
            "id": original["id"], "name": original["name"],
            "endpoint": original["endpoint"], "model": original["model"],
            "models": original.get("models") or [], "headers": original.get("headers") or {},
            "apiFormat": original.get("apiFormat")})
        after = bridge("GET", "/ai/profiles")
        now = next(p for p in after["profiles"] if p["id"] == original["id"])
        check("档案已还原", now["endpoint"] == original["endpoint"])
        bridge("POST", "/dpp/mode", body={"host": "127.0.0.1", "mode": "off"})
        try:
            trace = bridge("GET", "/agent/trace")
            cid = trace.get("conversation")
            if cid:
                bridge("POST", "/conversations/delete", body={"ids": [cid]})
                print("已删除测试会话", cid)
        except Exception as e:
            print("会话清理跳过：", e)

    failed = [n for n, ok in checks if not ok]
    print(f"\nDPP 事件驱动 E2E：{len(checks)} 项，失败 {len(failed)} 项")
    if failed:
        for f in failed:
            print("  -", f)
        sys.exit(1)
    print("全部通过 ✓")

if __name__ == "__main__":
    main()
