#!/usr/bin/env python3
"""分片并发与下载方式研判的端到端（v0.8.77 批 3 / 批 6）。

- 本地限速 HLS 上，并发必须明显快于串行，且产物完整；签名地址中途过期必须被识别出来；
- 每个下载带着研判（事实 → 引擎）与测速结论；探测端点按流的形态给出不同的方法与原因；
  音轨分离的流不丢声音；码率上限在并发路径上同样挑档。

下载与探测走 URLSession（不经过 WebKit），所以**不需要**实例在前台——后台的封闭实例即可。

用法：
  python3 tests/parallel-hls-e2e.py [--base http://127.0.0.1:8799]
  python3 tests/parallel-hls-e2e.py --expect-no-ffmpeg     # 实例带 `--no-ffmpeg` 启动时

前置：应用以 tools/launch-hermetic.sh 启动（下载落到隔离数据目录里）；本机有 ffmpeg。
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.error
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
    try:
        with opener.open(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as error:
        return json.loads(error.read().decode() or "{}")


def run_download(base, url, name, directory, connections, max_bandwidth=None):
    started = time.time()
    payload = {"url": url, "filename": name, "directory": directory, "connections": connections}
    if max_bandwidth is not None:
        payload["maxBandwidth"] = max_bandwidth
    job = br(base, "POST", "/media/download", payload)
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


def probe(base, url, connections=None):
    query = {"url": url}
    if connections:
        query["connections"] = connections
    return br(base, "GET", "/media/probe?" + urllib.parse.urlencode(query), timeout=60)


def streams_of(ffprobe, path):
    result = subprocess.run([ffprobe, "-v", "error", "-show_entries",
                             "format=duration:stream=codec_type", "-of", "json", path],
                            capture_output=True, text=True)
    meta = json.loads(result.stdout or "{}")
    kinds = [s.get("codec_type") for s in meta.get("streams", [])]
    return float((meta.get("format") or {}).get("duration") or 0), kinds


def plan_lines(row):
    return row.get("plan") or []


def no_ffmpeg_round(base, out_dir, site_base, slow, ffprobe):
    """实例带 `--no-ffmpeg` 启动：模拟本机没装 ffmpeg——此前这条路根本不并发。"""
    report = probe(base, slow, 8)
    ok("没装 ffmpeg：探测如实报告", "no ffmpeg" in (report.get("facts") or [])
       and (report.get("method") or "") == "parallel segment prefetch (8 connections) + built-in decrypt/concat",
       json.dumps(report, ensure_ascii=False)[:300])
    serial, serial_seconds = run_download(base, slow, "b77-noffmpeg-serial", out_dir, connections=1)
    ok("没装 ffmpeg · 串行（1 连接）：下载完成", serial and serial.get("state") == "finished",
       json.dumps(serial, ensure_ascii=False)[:300])
    ok(f"没装 ffmpeg · 串行耗时 ≥ 10 秒（实测 {serial_seconds:.1f}s）", serial_seconds >= 10)
    parallel, parallel_seconds = run_download(base, slow, "b77-noffmpeg-parallel", out_dir, connections=8)
    ok("没装 ffmpeg · 并发（8 连接）：下载完成", parallel and parallel.get("state") == "finished",
       json.dumps(parallel, ensure_ascii=False)[:300])
    speedup = serial_seconds / parallel_seconds if parallel_seconds else 0
    ok(f"没装 ffmpeg · 并发比串行快 ≥ 3 倍（实测 {speedup:.1f} 倍，{parallel_seconds:.1f}s）", speedup >= 3)
    plan = plan_lines(parallel)
    ok("没装 ffmpeg · 研判写明：内置解密拼接",
       any("no ffmpeg → parallel segment prefetch (8 connections) + built-in decrypt/concat" in line for line in plan),
       json.dumps(plan, ensure_ascii=False)[:400])
    ok("没装 ffmpeg · 带测速结论", any(line.startswith("speed probe — single connection") for line in plan),
       json.dumps(plan, ensure_ascii=False)[:400])
    ok("没装 ffmpeg · 并发任务确实抓了分片（不是复用上一次留下的工作目录）", parallel_seconds >= 1.5,
       f"{parallel_seconds:.1f}s")
    files = sorted(os.listdir(out_dir))
    target = next((f for f in files if f.startswith("b77-noffmpeg-parallel") and f.endswith(".ts")), None)
    serial_file = next((f for f in files if f.startswith("b77-noffmpeg-serial") and f.endswith(".ts")), None)
    ok("没装 ffmpeg · 产物是可直接拼接的 .ts（没有 ffmpeg 可转封装）", target is not None, str(files))
    if target and serial_file:
        # 裸 .ts 带 DISCONTINUITY，ffprobe 的时长估计不可靠——用字节数与串行产物比对。
        size = os.path.getsize(os.path.join(out_dir, target))
        serial_size = os.path.getsize(os.path.join(out_dir, serial_file))
        _, kinds = streams_of(ffprobe, os.path.join(out_dir, target))
        ok(f"没装 ffmpeg · 产物与串行产物逐字节等长（{size} vs {serial_size}）、音视频齐全",
           size == serial_size and size > 500_000 and "video" in kinds and "audio" in kinds, str(kinds))
    # 字节切片：内置下载器不认 BYTERANGE，没 ffmpeg 必须诚实报"做不了"，不产出坏文件
    br_report = probe(base, site_base + "/byterange/index.m3u8")
    ok("没装 ffmpeg · 字节切片：诚实报做不了", br_report.get("method") == "unsupported"
       and "need ffmpeg" in (br_report.get("rule") or ""), json.dumps(br_report, ensure_ascii=False)[:300])
    br_failed, _ = run_download(base, site_base + "/byterange/index.m3u8", "b80-noffmpeg-br", out_dir, connections=8)
    ok("没装 ffmpeg · 字节切片：任务失败且原因点名需要 ffmpeg",
       br_failed and br_failed.get("state") == "failed" and "ffmpeg" in (br_failed.get("summary") or ""),
       json.dumps(br_failed, ensure_ascii=False)[:300])

    # 加密流在没 ffmpeg 时走"并发预取 + 内置解密拼接"：必须能出 .ts 且音视频齐全
    enc, _ = run_download(base, site_base + "/enc/index.m3u8", "b77-noffmpeg-enc", out_dir, connections=8)
    ok("没装 ffmpeg · 加密流：下载完成且没有回退", enc and enc.get("state") == "finished"
       and "fell back" not in (enc.get("summary") or ""), json.dumps(enc, ensure_ascii=False)[:300])
    enc_file = next((f for f in sorted(os.listdir(out_dir)) if f.startswith("b77-noffmpeg-enc")), None)
    if enc_file:
        _, kinds = streams_of(ffprobe, os.path.join(out_dir, enc_file))
        ok(f"没装 ffmpeg · 加密流：产物音视频齐全（{kinds}）", "video" in kinds and "audio" in kinds, str(kinds))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8799")
    parser.add_argument("--expect-no-ffmpeg", action="store_true")
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
    ffprobe = shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe"

    site = subprocess.Popen([sys.executable, os.path.join(HERE, "fixtures", "batch-site-server.py"), str(SITE_PORT)],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        info = json.loads(site.stdout.readline())
        site_base = f"http://127.0.0.1:{SITE_PORT}"
        # 限速流的地址带上本轮的轮次号：预取工作目录按地址命名，固定地址会复用上一轮留下的分片。
        slow = site_base + f"/slow-{info.get('run', '')}/hls/aaa/long.m3u8"

        if args.expect_no_ffmpeg:
            no_ffmpeg_round(base, out_dir, site_base, slow, ffprobe)
            return finish()

        # 串行基线：1 个连接——服务器对每个分片固定延迟，串行下界 = 24 × 0.5 = 12 秒
        serial, serial_seconds = run_download(base, slow, "b77-serial", out_dir, connections=1)
        ok("串行（1 连接）：下载完成", serial and serial.get("state") == "finished", json.dumps(serial, ensure_ascii=False)[:300])
        ok(f"串行耗时 ≥ 10 秒（实测 {serial_seconds:.1f}s）", serial_seconds >= 10)

        # 并发：8 个连接——预期约 24 × 0.5 / 8 = 1.5 秒（外加测速那一轮的 1 秒）
        parallel, parallel_seconds = run_download(base, slow, "b77-parallel", out_dir, connections=8)
        ok("并发（8 连接）：下载完成", parallel and parallel.get("state") == "finished", json.dumps(parallel, ensure_ascii=False)[:300])
        # 倍数阈值是 3 而不是 4：开头的测速先用单连接抓第 1 个分片再放并发——不产生多余请求，
        # 但对这个 24 片 × 0.5 秒的小夹具是固定的约 1 秒（真实长片上不到 1%）。
        speedup = serial_seconds / parallel_seconds if parallel_seconds else 0
        ok(f"并发比串行快 ≥ 3 倍（实测 {speedup:.1f} 倍，{parallel_seconds:.1f}s）", speedup >= 3)
        ok(f"并发绝对耗时 < 6 秒（实测 {parallel_seconds:.1f}s）", parallel_seconds < 6)

        # 产物完整：时长约 48 秒（24 × 2 秒）、有音轨
        files = sorted(os.listdir(out_dir))
        target = next((f for f in files if f.startswith("b77-parallel") and f.endswith(".mp4")), None)
        ok("并发产物落盘为 mp4", target is not None, str(files))
        if target:
            duration, kinds = streams_of(ffprobe, os.path.join(out_dir, target))
            ok(f"并发产物时长 ≈ 48 秒（实测 {duration:.1f}s）", 44 <= duration <= 52)
            ok("并发产物有视频与音频", "video" in kinds and "audio" in kinds, str(kinds))

        # ---- 研判与测速（v0.8.77 批 6）：每个下载都带着"为什么走这条路" ----
        plan = plan_lines(parallel)
        ok("研判：事实 → 引擎写在任务上",
           any("HLS VOD" in line and "24 segments ≈ 48s" in line
               and line.endswith("→ parallel segment prefetch (8 connections) + local ffmpeg decrypt/remux") for line in plan),
           json.dumps(plan, ensure_ascii=False)[:400])
        ok("测速：单连接 vs 并发的实测结论写在任务上",
           any(line.startswith("speed probe — single connection") and "8 connections" in line for line in plan),
           json.dumps(plan, ensure_ascii=False)[:400])
        serial_plan = plan_lines(serial)
        ok("显式要 1 个连接：不测速，结论里写 1 个连接",
           not any(line.startswith("speed probe") for line in serial_plan)
           and any(line.endswith("(1 connection) + local ffmpeg decrypt/remux") for line in serial_plan),
           json.dumps(serial_plan, ensure_ascii=False)[:400])

        # ---- 探测端点（与智能体工具 probeDownload 同一份回执）：按形态给方法与原因 ----
        plain = probe(base, site_base + "/hls/aaa/index.m3u8")
        ok("探测·普通点播：并发预取 + 本地 ffmpeg，带测速与预计耗时",
           (plain.get("method") or "").startswith("parallel segment prefetch")
           and (plain.get("speed") or {}).get("gain", 0) > 0 and "- estimate:" in (plain.get("text") or ""),
           json.dumps(plain, ensure_ascii=False)[:400])
        demux = probe(base, site_base + "/demux/master.m3u8")
        ok("探测·音轨分离：认出独立音轨，方法 = ffmpeg 直连（串行），不丢声音",
           "separate audio/video renditions" in (demux.get("facts") or [])
           and demux.get("method") == "ffmpeg direct (serial)"
           and "prefetching a single variant" in (demux.get("rule") or ""),
           json.dumps(demux, ensure_ascii=False)[:400])
        sample = probe(base, site_base + "/sampleaes/index.m3u8")
        ok("探测·SAMPLE-AES：交给 ffmpeg，原因点名加密",
           sample.get("method") == "ffmpeg direct (serial)" and "encryption" in (sample.get("rule") or ""),
           json.dumps(sample, ensure_ascii=False)[:300])
        direct = probe(base, site_base + "/clips/ccc.mp4")
        ok("探测·直链文件：直连下载，给出大小",
           direct.get("method") == "direct file download" and (direct.get("estimatedBytes") or 0) > 0,
           json.dumps(direct, ensure_ascii=False)[:300])
        not_media = probe(base, site_base + "/videos/aaa-001/")
        ok("探测·网页不是媒体地址：直说，并指向 resolveVideos",
           "returns a web page, not a media stream" in (not_media.get("text") or "")
           and "resolveVideos" in (not_media.get("text") or ""),
           json.dumps(not_media, ensure_ascii=False)[:300])

        # ---- 加密流（v0.8.77 修 7 回归）：密钥文件名 key.ts 触发过 ffmpeg 的扩展名检查，
        #      本地合成必须成功、不得回退到远端重下。----
        enc, enc_seconds = run_download(base, site_base + "/enc/index.m3u8", "b77-enc", out_dir, connections=8)
        ok("加密流：下载完成", enc and enc.get("state") == "finished", json.dumps(enc, ensure_ascii=False)[:300])
        enc_summary = (enc or {}).get("summary") or ""
        ok("加密流：本地合成成功、没有回退重下", "fell back" not in enc_summary and "parallel HLS export failed" not in enc_summary,
           enc_summary[:300])
        ok("加密流：研判写的是并发预取", any("→ parallel segment prefetch" in line and "AES-128" in line
                                            for line in plan_lines(enc)),
           json.dumps(plan_lines(enc), ensure_ascii=False)[:300])
        enc_file = next((f for f in sorted(os.listdir(out_dir)) if f.startswith("b77-enc") and f.endswith(".mp4")), None)
        ok("加密流：产物落盘为 mp4", enc_file is not None, str(sorted(os.listdir(out_dir))))
        if enc_file:
            duration, kinds = streams_of(ffprobe, os.path.join(out_dir, enc_file))
            ok(f"加密流：产物完整（{duration:.0f}s，音视频 {kinds}）",
               10 <= duration <= 14 and "video" in kinds and "audio" in kinds)

        # ---- 直播（无 ENDLIST）与字节切片（v0.8.79 形态矩阵）----
        live_report = probe(base, site_base + "/live/index.m3u8")
        ok("探测·直播：事实写明 live、方法为并发预取 + 内置拼接",
           "HLS live" in (live_report.get("facts") or [])
           and "live stream" in (live_report.get("rule") or "")
           and (live_report.get("method") or "").endswith("+ built-in decrypt/concat"),
           json.dumps(live_report, ensure_ascii=False)[:300])
        live, _ = run_download(base, site_base + "/live/index.m3u8", "b80-live", out_dir, connections=8)
        ok("直播：下载完成、没有回退", live and live.get("state") == "finished"
           and "fell back" not in (live.get("summary") or ""), json.dumps(live, ensure_ascii=False)[:300])
        live_file = next((f for f in sorted(os.listdir(out_dir)) if f.startswith("b80-live") and f.endswith(".mp4")), None)
        if live_file:
            duration, kinds = streams_of(ffprobe, os.path.join(out_dir, live_file))
            ok(f"直播：只导出当前可用分片（{duration:.0f}s，音视频 {kinds}）",
               10 <= duration <= 14 and "video" in kinds and "audio" in kinds)
        br_report = probe(base, site_base + "/byterange/index.m3u8")
        ok("探测·字节切片：改走 ffmpeg 直连",
           "byte-range segments" in (br_report.get("facts") or [])
           and br_report.get("method") == "ffmpeg direct (serial)",
           json.dumps(br_report, ensure_ascii=False)[:300])
        branged, _ = run_download(base, site_base + "/byterange/index.m3u8", "b80-byterange", out_dir, connections=8)
        ok("字节切片：下载完成", branged and branged.get("state") == "finished",
           json.dumps(branged, ensure_ascii=False)[:300])
        br_file = next((f for f in sorted(os.listdir(out_dir)) if f.startswith("b80-byterange") and f.endswith(".mp4")), None)
        if br_file:
            duration, kinds = streams_of(ffprobe, os.path.join(out_dir, br_file))
            ok(f"字节切片：产物完整（{duration:.0f}s，音视频 {kinds}）",
               10 <= duration <= 14 and "video" in kinds and "audio" in kinds)

        # ---- 下载本身按研判走 ----
        demuxed, _ = run_download(base, site_base + "/demux/master.m3u8", "b77-demuxed", out_dir, connections=8)
        ok("音轨分离的流：下载完成", demuxed and demuxed.get("state") == "finished",
           json.dumps(demuxed, ensure_ascii=False)[:300])
        ok("音轨分离的流：研判写明 master 整体交给 ffmpeg",
           any("separate audio/video renditions" in line and line.endswith("→ ffmpeg direct (serial)")
               for line in plan_lines(demuxed)),
           json.dumps(plan_lines(demuxed), ensure_ascii=False)[:400])
        demuxed_file = next((f for f in sorted(os.listdir(out_dir)) if f.startswith("b77-demuxed") and f.endswith(".mp4")), None)
        ok("音轨分离的流：产物落盘为 mp4", demuxed_file is not None, str(sorted(os.listdir(out_dir))))
        if demuxed_file:
            duration, kinds = streams_of(ffprobe, os.path.join(out_dir, demuxed_file))
            ok(f"音轨分离的流：产物里音轨还在（{kinds}，{duration:.0f}s）",
               "video" in kinds and "audio" in kinds and 10 <= duration <= 14)

        capped, _ = run_download(base, site_base + "/variants/master.m3u8", "b77-capped", out_dir, connections=8,
                                 max_bandwidth=300_000)
        ok("码率上限：并发路径也按上限挑低档（160x120）",
           capped and capped.get("state") == "finished" and "160x120" in (capped.get("summary") or ""),
           (capped or {}).get("summary", "")[:300])
        uncapped, _ = run_download(base, site_base + "/variants/master.m3u8", "b77-uncapped", out_dir, connections=8)
        ok("没有码率上限：取最高档（320x240）",
           uncapped and uncapped.get("state") == "finished" and "320x240" in (uncapped.get("summary") or ""),
           (uncapped or {}).get("summary", "")[:300])
        ok("master 的研判写出变体清单",
           any("master playlist (2 variants, best 320x240)" in line for line in plan_lines(uncapped)),
           json.dumps(plan_lines(uncapped), ensure_ascii=False)[:300])

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
    return finish()


def finish():
    passed = sum(1 for _, passed in checks if passed)
    print(f"\n分片并发与研判端到端：{passed}/{len(checks)} 通过")
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    sys.exit(main())
