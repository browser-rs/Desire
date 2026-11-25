#!/usr/bin/env python3
"""正片识别端到端（v0.8.77 批 1）：本地测试站点三种详情页 → `listPageVideos` 回执与
`downloadVideoList` 的任务表都必须是"排除杂项后的准确正片集合"。

前置：
- 应用以 tools/launch-hermetic.sh 启动（存储/偏好/钥匙串三项隔离——本脚本会装带 Key
  的假档案、往隔离数据目录里下载测试片），且**在前台**（隐藏解析器要创建 WKWebView，
  未激活的进程里会阻塞）。不在前台会直接退出，不会抢焦点。
- 本机有 ffmpeg（测试站点启动时现生成 HLS 素材）。

用法：python3 tests/batch-content-e2e.py [--base http://127.0.0.1:8799]
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SITE_PORT = 8895
MODEL_PORT = 8896
checks = []


def ok(label, cond, detail=""):
    checks.append((label, bool(cond)))
    print(("✓ " if cond else "✗ ") + label + ("" if cond or not detail else f" — {detail}"))


def br(base, method, path, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


class Model(BaseHTTPRequestHandler):
    """假模型：用户消息 → listPageVideos；工具结果 → 结束。旁路调用一律 500。"""
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _sse(self, chunks):
        payload = b"".join(f"data: {json.dumps(c)}\n\n".encode() for c in chunks) + b"data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        request = json.loads(self.rfile.read(length) or b"{}")
        messages = request.get("messages") or []
        last = messages[-1] if messages else {}
        if not request.get("tools"):
            self.send_response(500)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        def chunk(delta, finish=None):
            return {"id": "cmpl-b77", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": "b77-fixture", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}

        if last.get("role") == "user":
            call = {"index": 0, "id": "call_list_videos", "type": "function",
                    "function": {"name": "listPageVideos", "arguments": "{}"}}
            self._sse([chunk({"role": "assistant", "tool_calls": [call]}), chunk({}, "tool_calls")])
        else:
            self._sse([chunk({"role": "assistant", "content": "BATCH-LIST-DONE"}), chunk({}, "stop")])


def wait_turn(base):
    deadline = time.time() + 120
    while time.time() < deadline:
        state = br(base, "GET", "/agent/messages")
        text = json.dumps(state, ensure_ascii=False)
        if "BATCH-LIST-DONE" in text and not state.get("busy"):
            return state.get("messages", [])
        time.sleep(0.5)
    raise TimeoutError("listPageVideos 回合超时")


def tool_result(messages, marker):
    for message in messages:
        if message.get("role") == "tool" and marker in (message.get("content") or ""):
            return message.get("content") or ""
    return ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8799")
    args = parser.parse_args()
    base = args.base

    state = br(base, "GET", "/state")
    startup = state.get("startup") or {}
    if not (startup.get("dataDir") and startup.get("prefs") == "isolated" and startup.get("secrets") == "file"):
        print("✗ 需要封闭实例（dataDir / prefs=isolated / secrets=file）——用 tools/launch-hermetic.sh 启动")
        return 2
    if not state.get("isActive"):
        print("✗ 实例不在前台：隐藏解析器要创建 WKWebView，未激活的进程里会阻塞。"
              "把测试实例切到前台再跑（本脚本不会自己抢焦点）。")
        return 3
    data_dir = startup["dataDir"]

    site = subprocess.Popen([sys.executable, os.path.join(HERE, "fixtures", "batch-site-server.py"), str(SITE_PORT)],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    model = ThreadingHTTPServer(("127.0.0.1", MODEL_PORT), Model)
    import threading
    threading.Thread(target=model.serve_forever, daemon=True).start()
    site_base = f"http://127.0.0.1:{SITE_PORT}"
    profile_id = None
    conversation_ids = set()
    batch_id = None
    try:
        info = json.loads(site.stdout.readline())
        print(f"测试站点就绪：{site_base}（素材 {info['root']}）")

        created = br(base, "POST", "/ai/profiles", {
            "name": "b77-fixture", "endpoint": f"http://127.0.0.1:{MODEL_PORT}/v1/chat/completions",
            "model": "b77-fixture", "key": "b77-fake-key"})
        profile_id = created["id"]
        br(base, "POST", "/ai/profiles/activate", {"id": profile_id})
        assert br(base, "GET", "/ai/profiles").get("active") == profile_id
        br(base, "POST", "/agent/send", {"text": "/access full"})
        time.sleep(2)

        expectations = {
            "/videos/aaa-001/": {
                "title": "单视频 + 杂项",
                "content": ["1 content video", "/hls/aaa/index.m3u8"],
                "excluded": ["HLS segment of index", "preview/thumbnail", "ad "],
                "must_not": ["zzz_preview", "/ads/", "seg-000", "thumb.ts"],
            },
            # 这个工具只看得见**已加载**的播放器：懒加载页此刻只有第 1 部起了播。
            # 三部齐全由下面的批量下载路径（隐藏解析器会滚动收集）断言。
            "/videos/bbb-002/": {
                "title": "多视频（滚动才加载）——工具快照",
                "content": ["content video", "/hls/bbb-ep1/index.m3u8", "scroll so they load"],
                "excluded": ["preview/thumbnail"],
                "must_not": ["ccc-720p.mp4", "zzz_preview", "seg-000"],
            },
            "/videos/ccc-003/": {
                "title": "单视频 + 预览噪声",
                "content": ["1 content video", "/hls/ccc/index.m3u8"],
                "excluded": ["HLS segment of index", "preview/thumbnail"],
                "must_not": ["zzz_preview", "seg-000"],
            },
        }
        for path, want in expectations.items():
            br(base, "POST", "/navigate", {"url": site_base + path})
            time.sleep(2.5)
            br(base, "POST", "/agent/new", {})
            time.sleep(1)
            br(base, "POST", "/agent/send", {"text": "BATCHSITE 列出这个页面的视频"})
            messages = wait_turn(base)
            trace = br(base, "GET", "/agent/trace")
            if trace.get("conversation"):
                conversation_ids.add(trace["conversation"])
            result = tool_result(messages, "content video")
            ok(f"{want['title']}：listPageVideos 有正片清单", bool(result), json.dumps(messages[-3:], ensure_ascii=False)[:300])
            for needle in want["content"]:
                ok(f"{want['title']}：含 {needle}", needle in result, result[:400])
            for needle in want["excluded"]:
                ok(f"{want['title']}：排除清单含「{needle}」", needle in result, result[:600])
            for needle in want["must_not"]:
                ok(f"{want['title']}：正片里没有 {needle}", needle not in result.split("Excluded")[0], result[:400])

        # downloadVideoList：三个详情页 → 任务表必须是 1 + 3 + 1 条正片
        started = br(base, "POST", "/media/batch", {
            "mode": "list",
            "urls": [site_base + p for p in expectations],
            "directory": os.path.join(data_dir, "batch-out")})
        ok("批量已启动", "batchId" in started, json.dumps(started, ensure_ascii=False))
        batch_id = started.get("batchId")
        deadline = time.time() + 150
        snapshot = None
        while batch_id and time.time() < deadline:
            batches = br(base, "GET", f"/media/batch?id={batch_id}").get("batches", [])
            snapshot = batches[0] if batches else None
            items = (snapshot or {}).get("items", [])
            resolved = [i for i in items if i.get("media")]
            if len(resolved) >= 5 and not any(i.get("state") == "resolving" for i in items):
                break
            time.sleep(1)
        items = (snapshot or {}).get("items", [])
        medias = sorted(i.get("media", "") for i in items)
        ok("批量任务表 = 5 条正片（1 + 3 + 1）", len(items) == 5, json.dumps(items, ensure_ascii=False)[:600])
        expected = sorted(f"{site_base}{p}" for p in
                          ["/hls/aaa/index.m3u8", "/hls/bbb-ep1/index.m3u8", "/hls/bbb-ep2/index.m3u8",
                           "/clips/ccc-1080p.mp4", "/hls/ccc/index.m3u8"])
        ok("每条任务指向正片（没有分片/预览/广告）", medias == expected, str(medias))
        ok("多视频页展开成 02 / 02-2 / 02-3", any(t.startswith("02-2-") for t in [i.get("title", "") for i in items])
           and any(t.startswith("02-3-") for t in [i.get("title", "") for i in items]), str([i.get("title") for i in items]))
        log = br(base, "GET", f"/media/batch/log?id={batch_id}")
        log_text = json.dumps(log, ensure_ascii=False)
        ok("批次日志写明排除了什么", "已排除" in log_text and "条正片" in log_text, log_text[:300])
    finally:
        if batch_id:
            try:
                br(base, "POST", "/media/batch/cancel", {"id": batch_id})
            except Exception:
                pass
        if profile_id:
            try:
                br(base, "POST", "/ai/profiles/delete", {"id": profile_id})
            except Exception:
                pass
        if conversation_ids:
            try:
                br(base, "POST", "/conversations/delete", {"ids": sorted(conversation_ids)})
            except Exception:
                pass
        model.shutdown()
        site.terminate()
        site.wait(timeout=10)

    passed = sum(1 for _, c in checks if c)
    print(f"\n正片识别端到端：{passed}/{len(checks)} 通过")
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    sys.exit(main())
