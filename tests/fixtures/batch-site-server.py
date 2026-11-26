#!/usr/bin/env python3
"""批量下载正片识别的本地测试站点（v0.8.77 批 1/批 5）。

用法：python3 tests/fixtures/batch-site-server.py [port]   # 默认 127.0.0.1:8895

三种详情页形态 + 一个列表页（站点信息全部中性，不对应任何真实站点）：
- /videos/aaa-001/   单视频 + 杂项：一个 HLS 播放列表，页面脚本像真实播放器那样
                     依次 fetch 播放列表、分片、缩略图分片，外加预览片与广告片；
- /videos/bbb-002/   多视频：三个播放器**滚动进视口才加载**（IntersectionObserver），
                     另有一个悬停预览；
- /videos/ccc-003/   单视频 + 预览噪声；
- /models/actor/     列表页：指向上面三个详情页。

HLS 素材在启动时用 ffmpeg 现生成（测试图案、2 秒分片；单视频页 12 秒、多视频页每部 100 秒），
每个流一份独立目录——分片必须落在各自播放列表目录之下，才能验证"分片归并进所属播放列表"。
"""
import atexit
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8895
ROOT = tempfile.mkdtemp(prefix="desire-batch-site-")
# 进程退出（含 terminate() 发来的 SIGTERM）时清掉现生成的素材，不在临时目录里越积越多。
atexit.register(shutil.rmtree, ROOT, ignore_errors=True)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
# 每个流的时长（秒）→ 分片数（每片 2 秒）。多视频页的几部要长得像正片（≥ 90 秒）：
# 批量引擎会把"短于 90 秒、而页面上还有别的候选"的流判为广告/预览——12 秒的测试流
# 放在多视频页上会被这条规则剔掉（实测）。
DURATIONS = {"aaa": 12, "bbb-ep1": 100, "bbb-ep2": 100, "ccc": 12}
STREAMS = {name: seconds // 2 for name, seconds in DURATIONS.items()}

# 限速与过期两种故障形态（v0.8.77 批 3 的速度/续传验证）：
# - `/slow/…`：同一个文件，但每个分片响应先睡 SLOW_DELAY 秒——模拟"单连接被限速"的 CDN；
#   串行下 N 个分片至少 N × SLOW_DELAY 秒，并发 k 路约 N × SLOW_DELAY / k 秒。
# - `/expire/…`：序号 ≥ EXPIRE_AFTER 的分片返回 403——模拟签名地址在下载中途过期。
SLOW_DELAY = 0.5
# 每次启动一个轮次号：限速流的地址随它变（/slow-<轮次号>/…）。下载器按地址给预取工作目录
# 命名——地址固定的话，上一轮（或修复前的构建）留下的分片会被下一轮悄悄复用。
RUN = uuid.uuid4().hex[:8]
EXPIRE_AFTER = 3
# `/expire/` 的语义（确定性，不数播放列表被请求过几次——解析阶段的时长探测也会取
# 一次播放列表）：尾部分片（序号 ≥ EXPIRE_AFTER）一律 403，**直到出现过 403 之后**
# 播放列表又被请求过一次 = "页面被重新解析、拿到新签名"，此后全部正常。用来验证
# "下载中途过期 → 批量引擎重新解析 → 从已抓到的分片续传"。`GET /_reset` 复位。
STATE = {"expireSaw403": False, "expireRefreshed": False, "expireRefreshes": 0, "hits": {}}

TYPES = {".m3u8": "application/vnd.apple.mpegurl", ".ts": "video/mp2t", ".mp4": "video/mp4",
         ".html": "text/html; charset=utf-8", ".js": "text/javascript"}


def build_media():
    ffmpeg = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
    if not os.path.exists(ffmpeg):
        print("ffmpeg not found — media will be placeholder bytes", file=sys.stderr)
        for stream, count in STREAMS.items():
            d = os.path.join(ROOT, "hls", stream)
            os.makedirs(d)
            for n in range(count):
                open(os.path.join(d, f"seg-{n:03d}.ts"), "wb").write(b"\x47" * 188 * 100)
            open(os.path.join(d, "thumb.ts"), "wb").write(b"\x47" * 188 * 4)
        os.makedirs(os.path.join(ROOT, "clips"))
        open(os.path.join(ROOT, "clips", "ccc.mp4"), "wb").write(b"\0" * 4096)
        return
    # 每种时长只生成一份母带，各流目录整份拷过去（分片必须落在各自播放列表目录之下）。
    masters = {}
    for stream in STREAMS:
        d = os.path.join(ROOT, "hls", stream)
        os.makedirs(d)
        seconds = DURATIONS[stream]
        if seconds not in masters:
            masters[seconds] = os.path.join(ROOT, "masters", str(seconds))
            os.makedirs(masters[seconds])
            subprocess.run([ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", f"testsrc=duration={seconds}:size=320x240:rate=15",
                            "-f", "lavfi", "-i", f"sine=frequency=440:duration={seconds}", "-c:v", "libx264", "-preset", "ultrafast",
                            "-g", "30", "-c:a", "aac", "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod",
                            "-hls_segment_filename", os.path.join(masters[seconds], "seg-%03d.ts"),
                            os.path.join(masters[seconds], "index.m3u8")], check=True)
        for name in os.listdir(masters[seconds]):
            shutil.copy(os.path.join(masters[seconds], name), os.path.join(d, name))
    os.makedirs(os.path.join(ROOT, "clips"))
    for name in ("ccc", "ccc-720p", "ccc-1080p", "zzz_preview"):
        src = os.path.join(ROOT, "hls", "ccc", "index.m3u8")
        out = os.path.join(ROOT, "clips", f"{name}.mp4")
        subprocess.run([ffmpeg, "-v", "error", "-y", "-allowed_extensions", "ALL", "-i", src, "-c", "copy", out], check=True)
    for stream in STREAMS:   # 每个流目录一个缩略图分片（真实站点有 thumb.ts 这类噪声）
        shutil.copy(os.path.join(ROOT, "hls", stream, "seg-000.ts"), os.path.join(ROOT, "hls", stream, "thumb.ts"))
    full = os.path.join(ROOT, "hls", "ccc", "index.m3u8")
    # 24 个互不相同的分片（48 秒）：`long.m3u8` 是同一组重复 4 轮的合成列表（省空间），
    # 但跨重启续传要按**分片地址**计数，重复地址会让计数失真——这里用真实形态。
    uniq_dir = os.path.join(ROOT, "hls", "uniq")
    os.makedirs(uniq_dir, exist_ok=True)
    uniq_lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:6", "#EXT-X-PLAYLIST-TYPE:VOD"]
    for n in range(24):
        source = os.path.join(ROOT, "hls", "aaa", f"seg-{n % 6:03d}.ts")
        shutil.copy(source, os.path.join(uniq_dir, f"seg-{n:03d}.ts"))
        uniq_lines.append("#EXTINF:2.000000,")
        uniq_lines.append(f"seg-{n:03d}.ts")
    uniq_lines.append("#EXT-X-ENDLIST")
    with open(os.path.join(uniq_dir, "index.m3u8"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(uniq_lines) + "\n")

    # 直播（无 ENDLIST）：同一批分片，但播放列表不宣告结束——只导出当前可用分片。
    live_dir = os.path.join(ROOT, "live")
    os.makedirs(live_dir, exist_ok=True)
    for name in os.listdir(os.path.join(ROOT, "hls", "aaa")):
        shutil.copy(os.path.join(ROOT, "hls", "aaa", name), os.path.join(live_dir, name))
    live_playlist = open(os.path.join(ROOT, "hls", "aaa", "index.m3u8"), encoding="utf-8").read()
    with open(os.path.join(live_dir, "index.m3u8"), "w", encoding="utf-8") as handle:
        handle.write(live_playlist.replace("#EXT-X-ENDLIST\n", "").replace("#EXT-X-ENDLIST", ""))

    # 字节切片（EXT-X-BYTERANGE）：一个整文件 + 按区间切的三片——内置下载器不认这种形态，
    # 有 ffmpeg 时必须走直连。
    br_dir = os.path.join(ROOT, "byterange")
    os.makedirs(br_dir, exist_ok=True)
    source_playlist = open(os.path.join(ROOT, "hls", "aaa", "index.m3u8"), encoding="utf-8").read()
    durations = [line[len("#EXTINF:"):].split(",")[0] for line in source_playlist.splitlines()
                 if line.startswith("#EXTINF:")]
    concat = b""
    offsets = []
    for n in range(6):
        data = open(os.path.join(ROOT, "hls", "aaa", f"seg-{n:03d}.ts"), "rb").read()
        offsets.append((len(concat), len(data)))
        concat += data
    with open(os.path.join(br_dir, "media.ts"), "wb") as handle:
        handle.write(concat)
    lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:6", "#EXT-X-PLAYLIST-TYPE:VOD"]
    for n, (offset, length) in enumerate(offsets):
        lines.append(f"#EXTINF:{durations[n] if n < len(durations) else '2.0'},")
        lines.append(f"#EXT-X-BYTERANGE:{length}@{offset}")
        lines.append("media.ts")
    lines.append("#EXT-X-ENDLIST")
    with open(os.path.join(br_dir, "index.m3u8"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")

    # 加密流（v0.8.77 修 7 回归）：AES-128，密钥文件名故意用 `key.ts`——ffmpeg 9 的扩展名
    # 安全检查会拒收非白名单扩展名的**密钥文件**（真实事故：本地合成因此失败，旧逻辑回退到
    # 远端重下整部片）。并发路径必须能本地合成出带音视频的完整 mp4。
    enc_dir = os.path.join(ROOT, "enc")
    os.makedirs(enc_dir, exist_ok=True)
    key_bytes = bytes([(i * 37 + 11) & 0xFF for i in range(16)])
    with open(os.path.join(enc_dir, "key.ts"), "wb") as handle:
        handle.write(key_bytes)
    keyinfo = os.path.join(enc_dir, "keyinfo.txt")
    with open(keyinfo, "w", encoding="utf-8") as handle:
        handle.write("key.ts\n" + os.path.join(enc_dir, "key.ts") + "\n"
                     + "000102030405060708090a0b0c0d0e0f\n")
    subprocess.run([ffmpeg, "-v", "error", "-y", "-allowed_extensions", "ALL", "-i", full,
                    "-c", "copy", "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod",
                    "-hls_key_info_file", keyinfo,
                    "-hls_segment_filename", os.path.join(enc_dir, "seg-%03d.ts"),
                    os.path.join(enc_dir, "index.m3u8")], check=True)

    # 三种特殊形态（v0.8.77 批 6，下载方式的研判用）：
    # - /demux/master.m3u8    音轨分离（EXT-X-MEDIA 独立音轨）——master 必须整体交给 ffmpeg；
    # - /variants/master.m3u8 两个变体（320x240 / 160x120）——码率上限挑档；
    # - /sampleaes/index.m3u8 写着 SAMPLE-AES 的播放列表（分片是普通的，只用来探测，不用来下载）。
    def cut_hls(source, out_dir, *filters):
        os.makedirs(out_dir, exist_ok=True)
        subprocess.run([ffmpeg, "-v", "error", "-y", "-allowed_extensions", "ALL", "-i", source, *filters,
                        "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod",
                        "-hls_segment_filename", os.path.join(out_dir, "seg-%03d.ts"),
                        os.path.join(out_dir, "index.m3u8")], check=True)

    cut_hls(full, os.path.join(ROOT, "demux", "video"), "-an", "-c", "copy")
    cut_hls(full, os.path.join(ROOT, "demux", "audio"), "-vn", "-c", "copy")
    cut_hls(full, os.path.join(ROOT, "variants", "hi"), "-c", "copy")
    cut_hls(full, os.path.join(ROOT, "variants", "lo"),
            "-vf", "scale=160:120", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "copy")
    with open(os.path.join(ROOT, "demux", "master.m3u8"), "w", encoding="utf-8") as handle:
        handle.write('#EXTM3U\n'
                     '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="audio",DEFAULT=YES,AUTOSELECT=YES,URI="audio/index.m3u8"\n'
                     '#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=320x240,AUDIO="aud"\n'
                     'video/index.m3u8\n')
    with open(os.path.join(ROOT, "variants", "master.m3u8"), "w", encoding="utf-8") as handle:
        handle.write('#EXTM3U\n'
                     '#EXT-X-STREAM-INF:BANDWIDTH=600000,RESOLUTION=320x240\n'
                     'hi/index.m3u8\n'
                     '#EXT-X-STREAM-INF:BANDWIDTH=200000,RESOLUTION=160x120\n'
                     'lo/index.m3u8\n')
    sample_dir = os.path.join(ROOT, "sampleaes")
    os.makedirs(sample_dir, exist_ok=True)
    for name in os.listdir(os.path.join(ROOT, "hls", "aaa")):
        shutil.copy(os.path.join(ROOT, "hls", "aaa", name), os.path.join(sample_dir, name))
    playlist = open(os.path.join(ROOT, "hls", "aaa", "index.m3u8"), encoding="utf-8").read()
    with open(os.path.join(sample_dir, "index.m3u8"), "w", encoding="utf-8") as handle:
        handle.write(playlist.replace("#EXTINF", '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin"\n#EXTINF', 1))

    os.makedirs(os.path.join(ROOT, "ads"))
    shutil.copy(os.path.join(ROOT, "clips", "ccc.mp4"), os.path.join(ROOT, "ads", "preroll.mp4"))
    shutil.copy(os.path.join(ROOT, "clips", "ccc.mp4"), os.path.join(ROOT, "ads", "300x250.medium.mp4"))


PLAYER_JS = """
// 像真实播放器：逐个 fetch 播放列表与分片（被页面嗅探脚本记录为媒体资源）。
async function loadStream(prefix, count) {
  await fetch(prefix + 'index.m3u8');
  for (let i = 0; i < count; i++) {
    await fetch(prefix + 'seg-' + String(i).padStart(3, '0') + '.ts');
  }
  await fetch(prefix + 'thumb.ts').catch(() => {});
}
"""

SINGLE_PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>AAA-001 测试正片 第一部</title>
<script>var hlsUrl = '/hls/aaa/index.m3u8';</script></head>
<body><h1>AAA-001 测试正片</h1>
<video id="player" src="/hls/aaa/index.m3u8" controls muted width="640"></video>
<div class="related"><video src="/clips/zzz_preview.mp4" muted loop autoplay playsinline width="160"></video></div>
<script src="/player.js"></script>
<script>
(async () => {
  await loadStream('/hls/aaa/', 6);
  await fetch('/clips/zzz_preview.mp4');
  await fetch('/ads/preroll.mp4');
  await fetch('/ads/300x250.medium.mp4').catch(() => {});
})();
</script></body></html>"""

MULTI_PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>BBB-002 测试合集</title>
<script src="/player.js"></script></head>
<body><h1>BBB-002 测试合集（三部）</h1>
<section class="ep" style="height:900px" data-src="/hls/bbb-ep1/index.m3u8"><h2>第 1 集</h2><video muted playsinline width="640"></video></section>
<section class="ep" style="height:900px" data-src="/hls/bbb-ep2/index.m3u8"><h2>第 2 集</h2><video muted playsinline width="640"></video></section>
<section class="ep" style="height:900px" data-src="/clips/ccc-1080p.mp4" data-alt="/clips/ccc-720p.mp4"><h2>第 3 集</h2><video muted playsinline width="640"></video></section>
<script>
// 滚动进视口才加载：解析器必须滚动 + 起播才能看到全部三部。
const io = new IntersectionObserver((entries) => {
  for (const e of entries) {
    if (!e.isIntersecting) return;
    const v = e.target.querySelector('video');
    v.src = e.target.dataset.src;
    v.play().catch(() => {});
    if (e.target.dataset.alt) fetch(e.target.dataset.alt);
    io.unobserve(e.target);
  }
}, {threshold: 0.3});
document.querySelectorAll('.ep').forEach(s => io.observe(s));
fetch('/clips/zzz_preview.mp4');   // 悬停预览噪声
</script></body></html>"""

NOISY_PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>CCC-003 测试正片 第三部</title>
<script>var hlsUrl = '/hls/ccc/index.m3u8';</script></head>
<body><h1>CCC-003 测试正片</h1>
<video src="/hls/ccc/index.m3u8" controls muted width="640"></video>
<video src="/clips/zzz_preview.mp4" muted loop autoplay playsinline width="120"></video>
<script src="/player.js"></script>
<script>loadStream('/hls/ccc/', 6);</script>
</body></html>"""

# 规则提取不到的页面：有播放器，但没有站点规则要找的内联变量 → 规则落空、回退通用识别。
RULE_MISS_PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>DDD-004 测试正片 第四部</title></head>
<body><h1>DDD-004 测试正片</h1>
<video src="/clips/ccc-720p.mp4" controls muted width="640"></video>
</body></html>"""

# 流地址会"中途过期"的页面：规则能从内联变量取到地址，但分片先 403、重新解析后才正常。
# 播放器 preload="none"：页面自己不去取分片，"过期"只发生在批量引擎的下载里。
EXPIRING_PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>EEE-005 测试正片 第五部</title>
<script>var hlsUrl = '/expire/hls/aaa/index.m3u8';</script></head>
<body><h1>EEE-005 测试正片</h1>
<video src="/expire/hls/aaa/index.m3u8" preload="none" controls muted width="640"></video>
</body></html>"""

LIST_PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>测试合集列表</title></head>
<body><h1>测试列表</h1>
<a href="/videos/aaa-001/">AAA-001 第一部</a><br>
<a href="/videos/bbb-002/">BBB-002 合集</a><br>
<a href="/videos/ccc-003/">CCC-003 第三部</a>
</body></html>"""


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def log_message(self, *args):
        pass

    def guess_type(self, path):
        ext = os.path.splitext(path)[1].lower()
        return TYPES.get(ext) or super().guess_type(path)

    def long_playlist(self):
        """24 个分片的点播列表（6 个分片重复 4 轮，轮间 DISCONTINUITY）。"""
        source = open(os.path.join(ROOT, "hls", "aaa", "index.m3u8"), encoding="utf-8").read()
        rounds = []
        for _ in range(4):
            rounds.append("#EXT-X-DISCONTINUITY\n" + "\n".join(
                line for line in source.splitlines() if not line.startswith(("#EXTM3U", "#EXT-X-"))))
        return "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n" \
            + "\n".join(rounds) + "\n#EXT-X-ENDLIST\n"

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/stats":
            body = json.dumps(STATE).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/_reset":
            # 复位过期状态与请求计数（同一夹具进程上重复跑时用）
            with threading.Lock():
                STATE.update({"expireSaw403": False, "expireRefreshed": False,
                              "expireRefreshes": 0, "hits": {}})
            body = b'{"ok": true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        with threading.Lock():
            STATE["hits"][path] = STATE["hits"].get(path, 0) + 1
        slow = re.match(r"^/slow(?:-[0-9a-f]{8})?(/.*)$", path)
        if slow:
            if path.lower().endswith((".ts", ".m4s")):
                time.sleep(SLOW_DELAY)
            self.path = slow.group(1)
        elif path.startswith("/expire/"):
            match = re.search(r"seg-(\d+)\.ts$", path)
            with threading.Lock():
                if path.endswith(".m3u8") and STATE["expireSaw403"] and not STATE["expireRefreshed"]:
                    # 出现过 403 之后播放列表又被请求 = 重新解析拿到了新签名
                    STATE["expireRefreshed"] = True
                    STATE["expireRefreshes"] += 1
                expired = (match is not None and int(match.group(1)) >= EXPIRE_AFTER
                           and not STATE["expireRefreshed"])
                if expired:
                    STATE["expireSaw403"] = True
            if expired:
                self.send_response(403)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.path = self.path[len("/expire"):]
        path = self.path.split("?")[0]
        if path == "/hls/aaa/long.m3u8":
            data = self.long_playlist().encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", TYPES[".m3u8"])
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)
            return
        pages = {
            "/videos/aaa-001/": ("text/html", SINGLE_PAGE),
            "/videos/bbb-002/": ("text/html", MULTI_PAGE),
            "/videos/ccc-003/": ("text/html", NOISY_PAGE),
            "/videos/ddd-004/": ("text/html", RULE_MISS_PAGE),
            "/videos/eee-005/": ("text/html", EXPIRING_PAGE),
            "/models/actor/": ("text/html", LIST_PAGE),
            "/player.js": ("text/javascript", PLAYER_JS),
        }
        if path in pages:
            ctype, body = pages[path]
            data = body.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)
            return
        super().do_GET()


if __name__ == "__main__":
    build_media()
    print(json.dumps({"root": ROOT, "port": PORT, "streams": STREAMS, "run": RUN}), flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
