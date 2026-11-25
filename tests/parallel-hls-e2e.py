#!/usr/bin/env python3
"""分片并发端到端（v0.8.77 批 3）：本地限速 HLS 上，并发必须明显快于串行，且产物完整；
签名地址中途过期必须被识别出来。

下载走 URLSession（不经过 WebKit），所以**不需要**实例在前台——后台的封闭实例即可。
前置：应用以 tools/launch-hermetic.sh 启动（下载落到隔离数据目录里）；本机有 ffmpeg。

用法：python3 tests/parallel-hls-e2e.py [--base http://127.0.0.1:8799]
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SITE_PORT = 8895
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


def run_download(base, url, name, directory, connections):
    started = time.time()
    job = br(base, "POST", "/media/download", {"url": url, "filename": name,
                                               "directory": directory, "connections": connections})
    assert job.get("ok"), job
    job_id = job["id"]
    deadline = time.time() + 120
    row = None
    while time.time() < deadline:
        row = next((j for j in br(base, "GET", "/media/exports").get("jobs", []) if j["id"] == job_id), None)
        if row and row.get("state") in ("finished", "failed", "cancelled"):
            break
        time.sleep(0.25)
    return row, time.time() - started


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8799")
    args = parser.parse_args()
    base = args.base
    startup = br(base, "GET", "/state").get("startup") or {}
    if not (startup.get("dataDir") and startup.get("prefs") == "isolated" and startup.get("secrets") == "file"):
        print("✗ 需要封闭实例（dataDir / prefs=isolated / secrets=file）——用 tools/launch-hermetic.sh 启动")
        return 2
    out_dir = os.path.join(startup["dataDir"], "parallel-hls-out")
    os.makedirs(out_dir, exist_ok=True)
    for name in os.listdir(out_dir):      # 只清本脚本目录里的旧产物
        os.remove(os.path.join(out_dir, name))

    site = subprocess.Popen([sys.executable, os.path.join(HERE, "fixtures", "batch-site-server.py"), str(SITE_PORT)],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        info = json.loads(site.stdout.readline())
        site_base = f"http://127.0.0.1:{SITE_PORT}"
        slow = site_base + "/slow/hls/aaa/long.m3u8"
        segments = 24

        # 串行基线：1 个连接——服务器对每个分片固定延迟，串行下界 = 24 × 0.5 = 12 秒
        serial, serial_seconds = run_download(base, slow, "b77-serial", out_dir, connections=1)
        ok("串行（1 连接）：下载完成", serial and serial.get("state") == "finished", json.dumps(serial, ensure_ascii=False)[:300])
        ok(f"串行耗时 ≥ 10 秒（实测 {serial_seconds:.1f}s）", serial_seconds >= 10)

        # 并发：8 个连接——预期约 24 × 0.5 / 8 = 1.5 秒
        parallel, parallel_seconds = run_download(base, slow, "b77-parallel", out_dir, connections=8)
        ok("并发（8 连接）：下载完成", parallel and parallel.get("state") == "finished", json.dumps(parallel, ensure_ascii=False)[:300])
        speedup = serial_seconds / parallel_seconds if parallel_seconds else 0
        ok(f"并发比串行快 ≥ 4 倍（实测 {speedup:.1f} 倍，{parallel_seconds:.1f}s）", speedup >= 4)

        # 产物完整：时长约 48 秒（24 × 2 秒）、有音轨
        ffprobe = shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe"
        files = sorted(os.listdir(out_dir))
        target = next((f for f in files if f.startswith("b77-parallel") and f.endswith(".mp4")), None)
        ok("并发产物落盘为 mp4", target is not None, str(files))
        if target:
            probe = subprocess.run([ffprobe, "-v", "error", "-show_entries",
                                    "format=duration:stream=codec_type", "-of", "json",
                                    os.path.join(out_dir, target)], capture_output=True, text=True)
            meta = json.loads(probe.stdout or "{}")
            duration = float((meta.get("format") or {}).get("duration") or 0)
            kinds = [s.get("codec_type") for s in meta.get("streams", [])]
            ok(f"并发产物时长 ≈ 48 秒（实测 {duration:.1f}s）", 44 <= duration <= 52)
            ok("并发产物有视频与音频", "video" in kinds and "audio" in kinds, str(kinds))

        # 签名地址中途过期：第 4 个分片起 403 → 必须识别为"地址过期"，而不是当成普通失败硬重试
        expired, expired_seconds = run_download(base, site_base + "/expire/hls/aaa/index.m3u8",
                                               "b77-expired", out_dir, connections=8)
        ok("中途过期：任务失败", expired and expired.get("state") == "failed", json.dumps(expired, ensure_ascii=False)[:300])
        ok("中途过期：失败原因点名地址过期",
          expired and "expired" in (expired.get("summary") or ""), (expired or {}).get("summary", "")[:300])
        ok(f"中途过期：很快停下，不在死地址上反复重试（{expired_seconds:.1f}s）", expired_seconds < 10)
    finally:
        site.terminate()
        site.wait(timeout=10)

    passed = sum(1 for _, c in checks if c)
    print(f"\n分片并发端到端：{passed}/{len(checks)} 通过")
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    sys.exit(main())
