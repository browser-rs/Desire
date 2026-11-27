#!/usr/bin/env python3
"""提示词缓存端到端（v0.8.80 批 3）：OpenAI 兼容的 cached_tokens 解析、Anthropic 的
cache_read_input_tokens 与 cache_control 断点、用量随会话落盘。

前置：封闭实例（tools/launch-hermetic.sh）。回合会启动后台标题/记忆调用，假端点
对所有请求统一回同一种流即可。

用法：python3 tests/prompt-cache-e2e.py [--base http://127.0.0.1:8799]
"""
import argparse
import http.server
import json
import os
import threading
import time
import urllib.request

OPENAI_PORT = 8906
ANTHROPIC_PORT = 8907
checks = []
captured = {"openai": [], "anthropic": []}


def ok(label, cond, detail=""):
    checks.append((label, bool(cond)))
    print(("✓ " if cond else "✗ ") + label + ("" if cond or not detail else f" — {detail}"))


def br(base, method, path, body=None, timeout=120):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def wait_done(base, timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        st = br(base, "GET", "/agent/messages")
        if not st.get("busy"):
            return st
        time.sleep(0.4)
    return br(base, "GET", "/agent/messages")


class OpenAI(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        captured["openai"].append(raw.decode(errors="ignore"))
        body = (
            'data: {"id":"o1","model":"fake-cache-openai","choices":[{"index":0,"delta":{"role":"assistant","content":"CACHE-OPENAI-OK"}}]}\n\n'
            'data: {"id":"o1","model":"fake-cache-openai","choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":5,'
            '"prompt_tokens_details":{"cached_tokens":640}}}\n\n'
            'data: [DONE]\n\n'
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Anthropic(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        captured["anthropic"].append(raw.decode(errors="ignore"))
        events = [
            {"type": "message_start", "message": {
                "id": "m1", "model": "claude-sonnet-4-20250514",
                "usage": {"input_tokens": 900, "cache_read_input_tokens": 700}}},
            {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
            {"type": "content_block_delta", "index": 0,
             "delta": {"type": "text_delta", "text": "CACHE-ANTHROPIC-OK"}},
            {"type": "content_block_stop", "index": 0},
            {"type": "message_delta", "delta": {"stop_reason": "end_turn"},
             "usage": {"output_tokens": 7, "cache_read_input_tokens": 700}},
            {"type": "message_stop"},
        ]
        body = "".join("data: " + json.dumps(e) + "\n\n" for e in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def read_conversation(data_dir, probe):
    """按探针文本找刚落盘的会话（桥的 /agent/messages 不带会话 id）。"""
    import glob
    deadline = time.time() + 12
    while time.time() < deadline:
        paths = sorted(glob.glob(os.path.join(data_dir, "storage", "conversation-*.json")),
                       key=os.path.getmtime, reverse=True)
        for path in paths[:12]:
            try:
                with open(path, encoding="utf-8") as fh:
                    conv = json.load(fh)
            except Exception:
                continue
            if any(probe in (message.get("content") or "") for message in conv.get("messages", [])):
                return conv
        time.sleep(0.4)
    return {}


def run_case(base, data_dir, profile_body, label, marker, probe_text):
    created = br(base, "POST", "/ai/profiles", profile_body)
    profile_id = created.get("id")
    ok(f"{label}：临时档案创建", bool(profile_id), str(created))
    if not profile_id:
        return
    br(base, "POST", "/ai/profiles/activate", {"id": profile_id})
    br(base, "POST", "/agent/new", {})
    br(base, "POST", "/agent/send", {"text": probe_text})
    wait_done(base)
    conv = read_conversation(data_dir, probe_text)
    assistant = next((m for m in conv.get("messages", [])
                      if m.get("role") == "assistant" and marker in (m.get("content") or "")), None)
    ok(f"{label}：回合完成并落盘", assistant is not None, json.dumps(conv.get("messages", []), ensure_ascii=False)[:300])
    return assistant, profile_id


def bypass_kinds(message):
    return [record.get("kind") for record in (message.get("bypassUsage") or [])]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8799")
    args = parser.parse_args()
    base = args.base

    state = br(base, "GET", "/state")
    startup = state.get("startup") or {}
    ok("封闭实例（存储/偏好/密钥三项隔离）",
       startup.get("dataDir") and startup.get("prefs") == "isolated" and startup.get("secrets") == "file",
       str(startup))
    data_dir = startup.get("dataDir") or ""

    oa = http.server.ThreadingHTTPServer(("127.0.0.1", OPENAI_PORT), OpenAI)
    an = http.server.ThreadingHTTPServer(("127.0.0.1", ANTHROPIC_PORT), Anthropic)
    threading.Thread(target=oa.serve_forever, daemon=True).start()
    threading.Thread(target=an.serve_forever, daemon=True).start()

    profiles = br(base, "GET", "/ai/profiles")
    previous_active = profiles.get("active")
    created_ids = []
    run_tag = "%d" % (int(time.time()) % 1000000)
    try:
        case = run_case(base, data_dir, {
            "name": "cache-openai-%d" % (int(time.time()) % 100000),
            "endpoint": f"http://127.0.0.1:{OPENAI_PORT}/v1/chat/completions",
            "model": "fake-cache-openai",
            "key": "cache-key-1234567890",
            "apiFormat": "openai",
        }, "OpenAI", "CACHE-OPENAI-OK", f"cache probe OpenAI {run_tag}")
        if case:
            assistant, profile_id = case
            created_ids.append(profile_id)
            ok("OpenAI：cached_tokens 记在消息上",
               assistant is not None
               and assistant.get("cachedPromptTokens") == 640
               and int(assistant.get("promptTokens") or 0) >= 1000
               and "title" in bypass_kinds(assistant),
               json.dumps(assistant or {}, ensure_ascii=False)[:300])

        case = run_case(base, data_dir, {
            "name": "cache-anthropic-%d" % (int(time.time()) % 100000),
            "endpoint": f"http://127.0.0.1:{ANTHROPIC_PORT}/v1/messages",
            "model": "claude-sonnet-4-20250514",
            "key": "cache-key-1234567890",
            "apiFormat": "anthropic",
        }, "Anthropic", "CACHE-ANTHROPIC-OK", f"cache probe Anthropic {run_tag}")
        if case:
            assistant, profile_id = case
            created_ids.append(profile_id)
            ok("Anthropic：cache_read_input_tokens 记在消息上",
               assistant is not None
               and assistant.get("cachedPromptTokens") == 700
               and int(assistant.get("promptTokens") or 0) >= 900
               and "title" in bypass_kinds(assistant),
               json.dumps(assistant or {}, ensure_ascii=False)[:300])
            # 主回合请求体（工具最多的那条）应带 cache_control 断点
            main_body = None
            for raw in captured["anthropic"]:
                try:
                    parsed = json.loads(raw)
                except Exception:
                    continue
                tools = parsed.get("tools") or []
                if len(tools) > len((main_body or {}).get("tools") or []):
                    main_body = parsed
            ok("Anthropic：请求带 system/tools 的 cache_control 断点",
               isinstance(main_body, dict)
               and isinstance(main_body.get("system"), list)
               and (main_body["system"][0].get("cache_control") == {"type": "ephemeral"})
               and isinstance(main_body.get("tools"), list) and len(main_body["tools"]) > 0
               and main_body["tools"][-1].get("cache_control") == {"type": "ephemeral"}
               and main_body["tools"][0].get("cache_control") is None,
               json.dumps(main_body or {}, ensure_ascii=False)[:400])
    finally:
        try:
            if previous_active:
                br(base, "POST", "/ai/profiles/activate", {"id": previous_active})
            for profile_id in created_ids:
                br(base, "POST", "/ai/profiles/delete", {"id": profile_id})
        except Exception:
            pass
        oa.shutdown()
        an.shutdown()

    passed = sum(1 for _, cond in checks if cond)
    print("\n提示词缓存端到端：%d/%d 通过" % (passed, len(checks)))
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
