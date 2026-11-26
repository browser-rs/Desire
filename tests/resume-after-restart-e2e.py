#!/usr/bin/env python3
"""跨重启续传端到端（v0.8.80）：下载中途优雅退出 → 重启同一构建 → 再次下载同一地址，
已抓到的分片不再请求、任务完成。

凭据：预取工作目录按地址（单文件）稳定命名，重启后仍在；`.part` 与分段文件名不变。

前置：
- 封闭实例以 `tools/launch-hermetic.sh` 启动（存储/偏好/钥匙串三项隔离）；本脚本会
  自己重启它（桥 `POST /app/quit` → `open -g <app> --args --automation --data-dir=…`）。
- 默认取 DerivedData 的 Debug 产物启动；可用 `--app` 指定同一构建的路径。
- 下载走 URLSession，不需要实例在前台。

用法：python3 tests/resume-after-restart-e2e.py [--base http://127.0.0.1:8799] [--app /path/Desire.app]
"""
import argparse
import glob
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


def br(base, method, path, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def wait_bridge(base, timeout=45):
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
    out_dir = os.path.join(data_dir, "resume-out")
    shutil.rmtree(out_dir, ignore_errors=True)
    os.makedirs(out_dir, exist_ok=True)

    site = subprocess.Popen([sys.executable, os.path.join(HERE, "fixtures", "batch-site-server.py"), str(SITE_PORT)],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        info = json.loads(site.stdout.readline())
        site_base = f"http://127.0.0.1:{SITE_PORT}"
        token = info.get("run", "")
        # 24 个互不相同的分片（48 秒）——按分片地址计数才有意义
        slow = f"{site_base}/slow-{token}/hls/uniq/index.m3u8"

        def seg_hits():
            stats = br(site_base, "GET", "/stats", timeout=10)
            hits = stats.get("hits", {})
            return {n: hits.get(f"/slow-{token}/hls/uniq/seg-{n:03d}.ts", 0) for n in range(24)}

        # 第一段：1 个连接（每片 0.5 秒），抓到 ≥6 片后优雅退出
        job = br(base, "POST", "/media/download", {
            "url": slow, "filename": "b80-resume", "directory": out_dir, "connections": 1})
        ok("第一段：任务已启动", bool(job.get("ok")) and bool(job.get("id")), json.dumps(job, ensure_ascii=False)[:200])
        deadline = time.time() + 60
        fetched = 0
        while time.time() < deadline:
            fetched = sum(1 for n, c in seg_hits().items() if c > 0)
            if fetched >= 6:
                break
            time.sleep(0.3)
        ok(f"第一段：退出前已抓到 ≥6 个分片（实测 {fetched}）", fetched >= 6)
        try:
            br(base, "POST", "/app/quit", timeout=10)
        except Exception:
            pass
        deadline = time.time() + 30
        while time.time() < deadline and instance_pids(data_dir):
            time.sleep(0.5)
        ok("退出：进程已优雅退出（同数据目录无残留）", not instance_pids(data_dir))
        # 快照要在进程退出之后取：退出瞬间在途的分片可能已请求但没落盘，那部分允许重抓。
        before = seg_hits()

        # 重启同一构建、同一数据目录
        subprocess.run(["open", "-g", app, "--args", "--automation", f"--data-dir={data_dir}"], check=True)
        state2 = wait_bridge(base, 60)
        ok("重启：桥回来了", state2 is not None)
        ok("重启：仍是封闭实例",
           bool(state2) and (state2.get("startup") or {}).get("dataDir") == data_dir
           and (state2.get("startup") or {}).get("prefs") == "isolated")

        # 第二段：同一地址再下（同一工作目录）→ 续传
        job2 = br(base, "POST", "/media/download", {
            "url": slow, "filename": "b80-resume", "directory": out_dir, "connections": 8})
        ok("续传：任务已启动", bool(job2.get("ok")), json.dumps(job2, ensure_ascii=False)[:200])
        deadline = time.time() + 180
        row = None
        while time.time() < deadline:
            rows = br(base, "GET", "/media/exports").get("jobs", [])
            row = next((r for r in rows if r.get("id") == job2.get("id")), None)
            if row and row.get("state") in ("finished", "failed", "cancelled"):
                break
            time.sleep(0.5)
        ok("续传：任务完成", bool(row) and row.get("state") == "finished",
           json.dumps(row, ensure_ascii=False)[:300])
        after = seg_hits()
        re_requested = [n for n in range(24) if before.get(n, 0) > 0 and after.get(n, 0) > before.get(n, 0)]
        # 退出瞬间在途的分片可能被重试一次——允许 ≤2 个
        ok(f"续传：已抓分片没有重抓（重抓 {len(re_requested)} 个，允许 ≤2 个在途）",
           len(re_requested) <= 2, f"重抓={re_requested} 前={before} 后={after}")
        total_requests = sum(after.values())
        ok(f"续传：总请求数 ≈ 分片数（{total_requests} ≤ 26）", total_requests <= 26,
           f"前={before} 后={after}")
        target = next((f for f in sorted(os.listdir(out_dir)) if f.endswith(".mp4")), None)
        ok("续传：产物落盘", target is not None, str(sorted(os.listdir(out_dir))))
        ffprobe = shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe"
        if target:
            probe = subprocess.run([ffprobe, "-v", "error", "-show_entries",
                                    "format=duration:stream=codec_type", "-of", "json",
                                    os.path.join(out_dir, target)], capture_output=True, text=True)
            meta = json.loads(probe.stdout or "{}")
            duration = float((meta.get("format") or {}).get("duration") or 0)
            kinds = [s.get("codec_type") for s in meta.get("streams", [])]
            ok(f"续传：产物完整（{duration:.0f}s，{kinds}）",
               44 <= duration <= 52 and "video" in kinds and "audio" in kinds)
    finally:
        try:
            br(base, "POST", "/media/batch/cancel", {"id": ""})
        except Exception:
            pass
        site.terminate()
        site.wait(timeout=10)

    passed = sum(1 for _, c in checks if c)
    print(f"\n跨重启续传端到端：{passed}/{len(checks)} 通过")
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    sys.exit(main())
