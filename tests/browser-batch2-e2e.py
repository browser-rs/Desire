#!/usr/bin/env python3
"""批 2「浏览器补件」端到端（v0.8.80）：标签组重色/加标签、站点级静音、
媒体菜单命令、文本翻译（旁路档案）。

前置：封闭实例在前台（命令总线按 key window 投递）。用法：
    python3 tests/browser-batch2-e2e.py [--base http://127.0.0.1:8799]
"""
import argparse
import http.server
import json
import threading
import time
import urllib.request

FAKE_PORT = 8899
PAGE_PORT = 8905
checks = []


def ok(label, cond, detail=""):
    checks.append((label, bool(cond)))
    print(("✓ " if cond else "✗ ") + label + ("" if cond or not detail else f" — {detail}"))


def br(base, method, path, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


class FakeTranslate(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        body = (
            'data: {"id":"t1","model":"fake-translate","choices":[{"index":0,"delta":{"role":"assistant","content":"translated:"}}]}\n\n'
            'data: {"id":"t1","model":"fake-translate","choices":[{"index":0,"delta":{"content":"ok"}}],"usage":{"prompt_tokens":8,"completion_tokens":2}}\n\n'
            'data: [DONE]\n\n'
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Page(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        body = b"<!doctype html><title>mute-page</title><p>hello</p>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def selected_tab(base):
    state = br(base, "GET", "/state")
    index = state.get("selected", -1)
    tabs = state.get("tabs", [])
    return (tabs[index] if 0 <= index < len(tabs) else None), state


def open_tab(base, url):
    br(base, "POST", "/new-tab", {"url": url})
    deadline = time.time() + 20
    while time.time() < deadline:
        tab, _ = selected_tab(base)
        if tab and not tab.get("loading"):
            return tab
        time.sleep(0.3)
    return selected_tab(base)[0]


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
    ok("实例在前台（命令总线可用）", state.get("isActive") is True,
       "先 osascript activate 再跑")

    fake = http.server.ThreadingHTTPServer(("127.0.0.1", FAKE_PORT), FakeTranslate)
    threading.Thread(target=fake.serve_forever, daemon=True).start()
    page = http.server.ThreadingHTTPServer(("127.0.0.1", PAGE_PORT), Page)
    threading.Thread(target=page.serve_forever, daemon=True).start()

    profiles = br(base, "GET", "/ai/profiles")
    previous_active = profiles.get("active")
    temp_profile_id = None
    group_name = "b80-batch2-%d" % (int(time.time()) % 100000)
    try:
        # 至少两个标签，供分组/加标签使用
        open_tab(base, "about:blank")
        open_tab(base, f"http://127.0.0.1:{PAGE_PORT}/")

        # ---- 标签组：创建 / 重色 / 加标签 / 折叠 ----
        created = br(base, "POST", "/tabgroups/create", {"name": group_name, "index": 0})
        ok("标签组：创建", created.get("ok") is True, str(created))
        groups = {g["name"]: g for g in br(base, "GET", "/tabgroups").get("groups", [])}
        ok("标签组：默认色号 0", groups.get(group_name, {}).get("colorIndex") == 0, str(groups))
        colored = br(base, "POST", "/tabgroups/color", {"name": group_name, "colorIndex": 5})
        groups = {g["name"]: g for g in br(base, "GET", "/tabgroups").get("groups", [])}
        ok("标签组：改色生效", colored.get("ok") is True and groups.get(group_name, {}).get("colorIndex") == 5,
           str(groups.get(group_name)))
        added = br(base, "POST", "/tabgroups/add", {"name": group_name, "index": 1})
        groups = {g["name"]: g for g in br(base, "GET", "/tabgroups").get("groups", [])}
        ok("标签组：把第二个标签加进组", added.get("ok") is True and groups.get(group_name, {}).get("tabs") == 2,
           str(added))
        collapsed = br(base, "POST", "/tabgroups/collapse", {"name": group_name, "collapsed": True})
        groups = {g["name"]: g for g in br(base, "GET", "/tabgroups").get("groups", [])}
        ok("标签组：折叠", collapsed.get("ok") is True and groups.get(group_name, {}).get("collapsed") is True,
           str(groups.get(group_name)))

        # ---- 站点级静音 ----
        tab, _ = selected_tab(base)
        br(base, "POST", "/site-settings/mute", {"host": "127.0.0.1", "enabled": True, "index": tab.get("index")})
        tab, _ = selected_tab(base)
        ok("站点静音：当前标签立即静音", tab.get("muted") is True, str(tab))
        br(base, "POST", "/navigate", {"url": f"http://127.0.0.1:{PAGE_PORT}/again"})
        deadline = time.time() + 10
        while time.time() < deadline:
            tab, _ = selected_tab(base)
            if tab and not tab.get("loading"):
                break
            time.sleep(0.3)
        ok("站点静音：重新加载后仍自动静音", tab.get("muted") is True, str(tab))
        br(base, "POST", "/site-settings/mute", {"host": "127.0.0.1", "enabled": False, "index": tab.get("index")})
        tab, _ = selected_tab(base)
        ok("站点静音：关闭后当前标签取消静音", tab.get("muted") is False, str(tab))

        # ---- 媒体菜单命令（全部静音 / 取消）----
        muted_all = br(base, "POST", "/command", {"name": "muteAllTabs"})
        time.sleep(0.5)
        tabs = br(base, "GET", "/state").get("tabs", [])
        ok("媒体菜单：Mute All Tabs", muted_all.get("ok") is True and all(t.get("muted") for t in tabs),
           json.dumps(muted_all)[:200])
        br(base, "POST", "/command", {"name": "unmuteAllTabs"})
        time.sleep(0.5)
        tabs = br(base, "GET", "/state").get("tabs", [])
        ok("媒体菜单：Unmute All Tabs", all(not t.get("muted") for t in tabs))

        # ---- 文本翻译（临时假档案 + 旁路调用）----
        created_profile = br(base, "POST", "/ai/profiles", {
            "name": "batch2-translate-%d" % (int(time.time()) % 100000),
            "endpoint": f"http://127.0.0.1:{FAKE_PORT}/v1/chat/completions",
            "model": "fake-translate",
            "key": "batch2-key-1234567890",
        })
        temp_profile_id = created_profile.get("id")
        if temp_profile_id:
            br(base, "POST", "/ai/profiles/activate", {"id": temp_profile_id})
            messages_before = len(br(base, "GET", "/agent/messages").get("messages", []))
            translated = br(base, "POST", "/translate/text", {"text": "hello world"})
            messages_after = len(br(base, "GET", "/agent/messages").get("messages", []))
            ok("翻译：旁路调用返回译文",
               translated.get("ok") is True and "translated:ok" in (translated.get("translation") or ""),
               str(translated)[:300])
            ok("翻译：不写进会话消息", messages_after == messages_before,
               f"{messages_before} → {messages_after}")
        else:
            ok("翻译：临时档案创建", False, str(created_profile))
    finally:
        try:
            br(base, "POST", "/site-settings/mute", {"host": "127.0.0.1", "enabled": False})
            br(base, "POST", "/tabgroups/delete", {"name": group_name})
            if previous_active:
                br(base, "POST", "/ai/profiles/activate", {"id": previous_active})
            if temp_profile_id:
                br(base, "POST", "/ai/profiles/delete", {"id": temp_profile_id})
        except Exception:
            pass
        fake.shutdown()
        page.shutdown()

    passed = sum(1 for _, cond in checks if cond)
    print("\n批 2 浏览器补件端到端：%d/%d 通过" % (passed, len(checks)))
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
