#!/usr/bin/env python3
"""普通下载跨重启续传的端到端（v0.8.80 批 1-④）。

流程：开始一个限速的大文件下载 → 暂停（URLSession 产生 resumeData 并落盘）→
优雅退出 → 重启同一构建/同一数据目录 → 恢复暂停行 → 完成；断言服务器收到
**从中间偏移开始**的 Range 请求、产物字节数完整、resume 文件已清理。

下载走 URLSession（不经过 WebKit），**不需要实例在前台**。

前置：封闭实例（tools/launch-hermetic.sh）；可用 --app 指定重启用的 Desire.app。
用法：python3 tests/download-resume-e2e.py [--base http://127.0.0.1:8799] [--app /path/Desire.app]
"""
import argparse
import glob
import http.server
import json
import os
import subprocess
import sys
import threading
import time
import urllib.request

PORT = 8901
TOTAL = 6 * 1024 * 1024
CHUNK = 64 * 1024
DELAY = 0.03
checks = []
STATE = {"ranges": [], "served": 0}


def ok(label, cond, detail=""):
    checks.append((label, bool(cond)))
    print(("✓ " if cond else "✗ ") + label + ("" if cond or not detail else f" — {detail}"))


def br(base, method, path, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def wait_bridge(base, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            return br(base, "GET", "/state", timeout=3)
        except Exception:
            time.sleep(0.5)
    return None


def instance_pids(data_dir):
    pids = []
    for pid in subprocess.run(["pgrep", "-x", "Desire"], capture_output=True, text=True).stdout.split():
        args = subprocess.run(["ps", "-o", "args=", "-p", pid], capture_output=True, text=True).stdout
        if f"--data-dir={data_dir}" in args:
            pids.append(pid)
    return pids


def app_bundle(explicit):
    if explicit:
        return explicit
    hits = sorted(glob.glob(os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/Desire-*/Build/Products/Debug/Desire.app")))
    return hits[-1] if hits else None


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/stats":
            body = json.dumps(STATE).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        start = 0
        header = self.headers.get("Range")
        if header and header.startswith("bytes="):
            try:
                start = int(header.split("=", 1)[1].split("-", 1)[0])
            except ValueError:
                start = 0
        STATE["ranges"].append(start)
        if start > 0:
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{TOTAL - 1}/{TOTAL}")
        else:
            self.send_response(200)
        remaining = TOTAL - start
        self.send_header("Content-Length", str(remaining))
        self.send_header("Accept-Ranges", "bytes")
        # URLSession 生成 resumeData 需要**验证器**（ETag / Last-Modified 至少一个）：
        # 没有它们时 cancel(byProducingResumeData:) 直接给 nil（实测）。
        self.send_header("ETag", '"resume-e2e-v1"')
        self.send_header("Last-Modified", "Wed, 01 Jan 2025 00:00:00 GMT")
        self.send_header("Content-Type", "application/octet-stream")
        self.end_headers()
        chunk = b"x" * CHUNK
        while remaining > 0:
            n = min(CHUNK, remaining)
            try:
                self.wfile.write(chunk[:n])
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
            remaining -= n
            STATE["served"] += n
            time.sleep(DELAY)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8799")
    parser.add_argument("--app", default=None)
    args = parser.parse_args()
    base = args.base

    state = wait_bridge(base, 5)
    if not state:
        print("✗ 桥不可达——先用 tools/launch-hermetic.sh 启动封闭实例")
        return 2
    startup = state.get("startup") or {}
    if not (startup.get("dataDir") and startup.get("prefs") == "isolated" and startup.get("secrets") == "file"):
        print("✗ 需要封闭实例（dataDir / prefs=isolated / secrets=file）")
        return 2
    data_dir = startup["dataDir"]
    app = app_bundle(args.app)
    if not app or not os.path.isdir(app):
        print("✗ 找不到用于重启的构建（--app 指定 Desire.app）")
        return 2

    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    tag = f"{int(time.time()) % 100000}"
    url = f"http://127.0.0.1:{PORT}/desire-resume-e2e-{tag}.bin"
    row_id = None
    file_path = None
    try:
        br(base, "POST", "/downloads/start", {"url": url})
        deadline = time.time() + 20
        row = None
        while time.time() < deadline:
            rows = br(base, "GET", "/downloads").get("downloads", [])
            row = next((r for r in rows if url in (r.get("source") or "")
                        or f"desire-resume-e2e-{tag}" in (r.get("file") or "")), None)
            if row and row.get("bytes", 0) > 512 * 1024:
                break
            time.sleep(0.2)
        row_id = (row or {}).get("id")
        ok("下载：已经开始并有进度", bool(row_id) and (row or {}).get("bytes", 0) > 0,
           json.dumps(row, ensure_ascii=False)[:300])

        br(base, "POST", "/downloads/pause", {"id": row_id})
        resume_file = os.path.join(data_dir, "download-resume", f"{row_id}.resume")
        deadline = time.time() + 8
        size = 0
        while time.time() < deadline:
            if os.path.isfile(resume_file):
                size = os.path.getsize(resume_file)
                if size > 0:
                    break
            time.sleep(0.2)
        ok("暂停：resumeData 已落盘（跨重启的凭据）", size > 0, f"{resume_file} size={size}")
        paused_row = next((r for r in br(base, "GET", "/downloads").get("downloads", [])
                           if r.get("id") == row_id), {})
        ok("暂停：行状态为已暂停", paused_row.get("paused") is True, json.dumps(paused_row)[:200])
        paused_bytes = int(paused_row.get("bytes") or 0)

        try:
            br(base, "POST", "/app/quit", timeout=10)
        except Exception:
            pass
        deadline = time.time() + 30
        while time.time() < deadline and instance_pids(data_dir):
            time.sleep(0.5)
        ok("退出：进程已优雅退出", not instance_pids(data_dir))

        subprocess.run(["open", "-g", app, "--args", "--automation", f"--data-dir={data_dir}"], check=True)
        state2 = wait_bridge(base, 60)
        ok("重启：桥回来了", state2 is not None)
        ok("重启：仍是封闭实例",
           bool(state2) and (state2.get("startup") or {}).get("dataDir") == data_dir
           and (state2.get("startup") or {}).get("prefs") == "isolated")

        rows2 = br(base, "GET", "/downloads").get("downloads", [])
        restored = next((r for r in rows2 if r.get("id") == row_id), None)
        ok("重启：暂停行还在（同一 id）", restored is not None and restored.get("paused") is True,
           json.dumps(restored, ensure_ascii=False)[:300])
        ok("重启：已下进度保留", int((restored or {}).get("bytes") or 0) >= paused_bytes,
           f"before={paused_bytes} after={(restored or {}).get('bytes')}")

        STATE["ranges"].clear()
        br(base, "POST", "/downloads/resume", {"id": row_id})
        deadline = time.time() + 90
        final = None
        while time.time() < deadline:
            final = next((r for r in br(base, "GET", "/downloads").get("downloads", [])
                          if r.get("id") == row_id), None)
            if final and final.get("state") in ("completed", "failed"):
                break
            time.sleep(0.4)
        ok("续传：任务完成", (final or {}).get("state") == "completed",
           json.dumps(final, ensure_ascii=False)[:300])
        ok("续传：服务器收到从中间偏移开始的 Range 请求",
           any(start >= max(1, paused_bytes // 2) for start in STATE["ranges"]),
           f"ranges={STATE['ranges'][:5]} paused={paused_bytes}")
        file_path = (final or {}).get("path")
        if file_path and os.path.isfile(file_path):
            ok("续传：产物字节数完整", os.path.getsize(file_path) == TOTAL,
               f"{os.path.getsize(file_path)} vs {TOTAL}")
        else:
            ok("续传：产物落盘", False, str(file_path))
        ok("续传：resume 文件已清理", not os.path.isfile(resume_file))
    finally:
        try:
            if row_id:
                br(base, "POST", "/downloads/remove", {"id": row_id})
        except Exception:
            pass
        if file_path and "desire-resume-e2e" in file_path:
            try:
                os.remove(file_path)
            except OSError:
                pass
        server.shutdown()

    passed = sum(1 for _, cond in checks if cond)
    print("\n普通下载跨重启续传：%d/%d 通过" % (passed, len(checks)))
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
