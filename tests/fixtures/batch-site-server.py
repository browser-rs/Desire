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

HLS 素材在启动时用 ffmpeg 现生成（12 秒测试图案、2 秒分片），每个流一份独立目录
——分片必须落在各自播放列表目录之下，才能验证"分片归并进所属播放列表"。
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8895
ROOT = tempfile.mkdtemp(prefix="desire-batch-site-")
STREAMS = {"aaa": 6, "bbb-ep1": 6, "bbb-ep2": 6, "ccc": 6}   # id → 分片数（每片 2 秒）

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
    first = True
    for stream in STREAMS:
        d = os.path.join(ROOT, "hls", stream)
        os.makedirs(d)
        if first:
            subprocess.run([ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=12:size=320x240:rate=15",
                            "-f", "lavfi", "-i", "sine=frequency=440:duration=12", "-c:v", "libx264", "-preset", "ultrafast",
                            "-g", "30", "-c:a", "aac", "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod",
                            "-hls_segment_filename", os.path.join(d, "seg-%03d.ts"),
                            os.path.join(d, "index.m3u8")], check=True)
            first = False
        else:
            for name in os.listdir(os.path.join(ROOT, "hls", "aaa")):
                shutil.copy(os.path.join(ROOT, "hls", "aaa", name), os.path.join(d, name))
    os.makedirs(os.path.join(ROOT, "clips"))
    for name in ("ccc", "ccc-720p", "ccc-1080p", "zzz_preview"):
        src = os.path.join(ROOT, "hls", "ccc", "index.m3u8")
        out = os.path.join(ROOT, "clips", f"{name}.mp4")
        subprocess.run([ffmpeg, "-v", "error", "-y", "-allowed_extensions", "ALL", "-i", src, "-c", "copy", out], check=True)
    for stream in STREAMS:   # 每个流目录一个缩略图分片（真实站点有 thumb.ts 这类噪声）
        shutil.copy(os.path.join(ROOT, "hls", stream, "seg-000.ts"), os.path.join(ROOT, "hls", stream, "thumb.ts"))
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

NOISY_PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>CCC-003 测试正片 第三部</title></head>
<body><h1>CCC-003 测试正片</h1>
<video src="/hls/ccc/index.m3u8" controls muted width="640"></video>
<video src="/clips/zzz_preview.mp4" muted loop autoplay playsinline width="120"></video>
<script src="/player.js"></script>
<script>loadStream('/hls/ccc/', 6);</script>
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

    def do_GET(self):
        path = self.path.split("?")[0]
        pages = {
            "/videos/aaa-001/": ("text/html", SINGLE_PAGE),
            "/videos/bbb-002/": ("text/html", MULTI_PAGE),
            "/videos/ccc-003/": ("text/html", NOISY_PAGE),
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
    print(json.dumps({"root": ROOT, "port": PORT, "streams": STREAMS}), flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
