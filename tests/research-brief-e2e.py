#!/usr/bin/env python3
"""研究简报 E2E（v0.8.50 批 2）：本地 fixture 站点 + 假 OpenAI SSE，全程离线确定性。

覆盖：种子 URL 直取（跳过搜索引擎）→ 非持久会话抓取（含登录墙标记）→
旁路模型阅读/成文 → 引用清洗（越界丢弃）→ 逐句核验（伪造引文标 ⚠️）→
无出处列表项标注 → 落盘（brief.md/sources.json/meta.json）→ Jobs 台账。

前置：应用以 --automation 运行（桥 8799）。**会临时新建一个模型档案并把
"旁路调用"指向假端点，结束后删除档案并还原旁路设置**；不改动用户已有档案。
用法：python3 tests/research-brief-e2e.py
"""
import json
import os
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BRIDGE = "http://127.0.0.1:8799"
FIXTURE_PORT = 8879
FAKE_PORT = 8899
STORE_DIR = os.path.expanduser("~/Library/Application Support/Desire/ResearchBriefs")

# 正文必须 > 200 字符（抓取器的可用性阈值），否则会被标 empty。
FILLER = ("This paragraph exists to give the extractor enough body text to treat the page as an "
          "article rather than a login or error screen. It repeats harmless neutral sentences so the "
          "reading stage has something realistic to work with. ")
PAGES = {
    "/one": "Alpha beta gamma. The quick brown fox jumps over the lazy dog. Distributed systems need clear boundaries. " + FILLER,
    "/two": "Second page body about citation contracts and verification workflows. It explains how quotes are checked. " + FILLER,
    "/three": "Third page discusses retrieval budgets and domain diversity in research pipelines. Budgets keep runs bounded. " + FILLER,
    "/login.html": "<p>Please sign in</p>",
}

TOKENS = {"passed": 0, "failed": 0}


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (" — " + str(detail) if detail else ""))
    TOKENS["passed" if ok else "failed"] += 1


def call(path, payload=None, timeout=30):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BRIDGE + path, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response)


# ---------- 本地 fixture 站点 ----------

class FixtureSite(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        body = PAGES.get(path)
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        html = f"<html><head><title>Fixture {path}</title></head><body><article>{body}</article></body></html>"
        data = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


# ---------- 假 OpenAI SSE ----------

def fake_reply(prompt: str) -> str:
    if "Return ONLY JSON" in prompt and "queries" in prompt:
        return '{"queries": ["fixture alpha", "fixture beta"]}'
    if "Extract 3 to 5 key points" in prompt:
        if "/one" in prompt:
            quote = "The quick brown fox jumps over the lazy dog"
        elif "/two" in prompt:
            quote = "this quote is fabricated by the model"
        elif "/three" in prompt:
            quote = "retrieval budgets and domain diversity"
        else:
            quote = "no useful quote"
        return json.dumps({"points": [{"point": "fixture point", "quote": quote}]}, ensure_ascii=False)
    # compose
    return ("## 概述\n背景介绍，来自甲页[1]。\n\n"
            "## 要点\n- 有出处的一条[1][2]\n- 没有出处的断言\n- 越界引用这条[9]\n")


class FakeModel(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw)
            messages = payload.get("messages", [])
            prompt = "\n".join(m.get("content") or "" for m in messages
                               if m.get("role") in ("user", "system"))
        except Exception:
            prompt = ""
        content = fake_reply(prompt)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        chunk = {"id": "fake", "model": "fake-model",
                 "choices": [{"index": 0, "delta": {"content": content}}]}
        self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
        usage = {"id": "fake", "model": "fake-model", "choices": [],
                 "usage": {"prompt_tokens": 100, "completion_tokens": 50}}
        self.wfile.write(("data: " + json.dumps(usage) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def log_message(self, *args):
        pass


def wait_brief(brief_id, timeout=120):
    deadline = time.time() + timeout
    state = None
    while time.time() < deadline:
        try:
            state = call(f"/research/briefs/state?id={brief_id}", timeout=15)
        except Exception:
            time.sleep(0.5)
            continue
        if state.get("state") in ("done", "failed", "cancelled"):
            return state
        time.sleep(1)
    return state or {}


def main():
    site = ThreadingHTTPServer(("127.0.0.1", FIXTURE_PORT), FixtureSite)
    fake = ThreadingHTTPServer(("127.0.0.1", FAKE_PORT), FakeModel)
    for server in (site, fake):
        threading.Thread(target=server.serve_forever, daemon=True).start()

    profile_id = None
    original_bypass = {}
    brief_id = None
    try:
        call("/state", timeout=5)  # bridge alive?
        original_bypass = call("/ai/bypass-profile", timeout=10)

        created = call("/ai/profiles", {
            "name": "Research E2E (temp)",
            "endpoint": f"http://127.0.0.1:{FAKE_PORT}/v1/chat/completions",
            "model": "fake-model",
            # 旁路档案必须**配了 Key** 才会被采纳（bypassPreferences 的门槛），
            # 假端点不校验值，任何非空串即可。
            "key": "test-key",
        }, timeout=15)
        profile_id = created.get("id") or (created.get("profile") or {}).get("id")
        check("临时模型档案已建", bool(profile_id), created)
        activated = call("/ai/bypass-profile", {"id": profile_id}, timeout=10)
        check("旁路调用指向假端点", activated.get("ok") is True, activated)

        urls = [f"http://127.0.0.1:{FIXTURE_PORT}{path}"
                for path in ("/one", "/two", "/three", "/login.html")]
        started = call("/research/briefs", {
            "topic": "fixture research topic",
            "urls": urls,
            "depth": 4,
            "language": "zh-Hans",
        }, timeout=20)
        brief_id = started.get("id")
        check("简报任务已启动", bool(brief_id), started)

        state = wait_brief(brief_id)
        print("state:", state.get("state"), "sources:", len(state.get("sources", [])))
        check("简报完成", state.get("state") == "done", state.get("state"))
        sources = state.get("sources", [])
        check("来源 4 条", len(sources) == 4, [s.get("url") for s in sources])
        check("登录墙来源被标记",
              any(s.get("gated") or (s.get("note") or "") in ("login", "empty") for s in sources),
              [(s.get("url"), s.get("note"), s.get("gated")) for s in sources])
        check("伪造引文被标未核验", state.get("unverifiedQuotes") == 1,
              state.get("unverifiedQuotes"))
        check("越界引用被丢弃", state.get("droppedRefs") == 1, state.get("droppedRefs"))
        check("无出处列表项被标注", state.get("uncitedBullets") == 2, state.get("uncitedBullets"))
        markdown = state.get("markdown", "")
        check("正文含来源列表", "## 来源" in markdown and "1. [" in markdown, markdown[:120])
        check("未核验在说明里", "未核验引用 1 处" in markdown, "")

        folder = os.path.join(STORE_DIR, brief_id or "")
        check("落盘 brief.md", os.path.exists(os.path.join(folder, "brief.md")), folder)
        check("落盘 sources.json", os.path.exists(os.path.join(folder, "sources.json")), folder)
        check("落盘 meta.json", os.path.exists(os.path.join(folder, "meta.json")), folder)

        jobs = call("/jobs", timeout=10).get("jobs", [])
        research_jobs = [j for j in jobs if j.get("kind") == "research"]
        check("Jobs 台账含研究任务", any(j.get("state") == "done" for j in research_jobs),
              [(j.get("kind"), j.get("state")) for j in research_jobs[:3]])
    finally:
        if brief_id:
            try:
                call("/research/briefs/delete", {"id": brief_id}, timeout=10)
            except Exception:
                pass
        # 还原旁路设置（原来有就设回去，没有就清空）
        try:
            if original_bypass.get("id"):
                call("/ai/bypass-profile", {"id": original_bypass["id"]}, timeout=10)
            else:
                call("/ai/bypass-profile", {}, timeout=10)
        except Exception as exc:
            print("WARN restore bypass failed:", exc)
        if profile_id:
            try:
                call("/ai/profiles/delete", {"id": profile_id}, timeout=10)
            except Exception as exc:
                print("WARN delete temp profile failed:", exc)
        site.shutdown()
        fake.shutdown()

    total = TOKENS["passed"] + TOKENS["failed"]
    print(f"\nRESULT {TOKENS['passed']}/{total}")
    return 0 if TOKENS["failed"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
