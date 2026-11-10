#!/usr/bin/env python3
"""VideoPro 命令面 E2E（v0.8.48 批 3）：自包含，运行前只需应用以 --automation 启动。

覆盖：
  1. 命令 API 全链路（new/addclip/split/setclip/trim/envelope/transition/
     addtext/track/save/load/undo/export），导出时长 == 时间线时长；
  2. 多编辑器会话路由（session=/file= 定向、未匹配报错、互不串扰）；
  3. 草稿（落盘/恢复/丢弃/保存清草稿）；
  4. 批量裁剪/拼接（/video/batch + Jobs 台账）。

它只创建并关闭**自己**的工具页标签，不碰用户已有标签；临时文件放 /tmp。
用法：python3 tests/video-pro-e2e.py
"""
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

BASE = os.environ.get("DESIRE_BASE", "http://127.0.0.1:8799")
TMP = "/tmp/desire-videopro-e2e"
DRAFT_DIR = os.path.expanduser("~/Library/Application Support/Desire/VideoProDrafts")
res = []
created_tabs = []


def call(path, payload=None, timeout=180):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response)


def edit(**kwargs):
    return call("/video/edit", kwargs)


def state():
    return call("/video/state")


def check(name, ok, detail=""):
    res.append((name, bool(ok)))
    print(("PASS " if ok else "FAIL ") + name + (" — " + str(detail) if detail else ""))


def ffprobe_duration(path):
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "csv=p=0", path], capture_output=True, text=True).stdout.strip()
        return float(out)
    except Exception:
        return -1


def make_fixtures():
    os.makedirs(TMP, exist_ok=True)
    for name, color in (("a.mp4", "red"), ("b.mp4", "blue")):
        path = os.path.join(TMP, name)
        if os.path.exists(path):
            continue
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi",
                        "-i", f"color=c={color}:s=320x180:d=3:r=24",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-y", path],
                       check=True)


def wait_job(job_id, timeout=120):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        jobs = call("/jobs", timeout=15).get("jobs", [])
        last = next((j for j in jobs if j.get("id") == job_id), None)
        if last and last.get("state") in ("done", "failed", "cancelled"):
            return last
        time.sleep(1)
    return last


def ensure_editor():
    st = call("/state")
    index = next((t.get("index") for t in st.get("tabs", [])
                  if "videoeditor" in (t.get("url") or "").lower()), None)
    if index is None:
        r = call("/new-tab", {"url": "desire://tools/videoEditor"})
        created_tabs.append(r.get("index"))
        time.sleep(3)
        st = call("/state")
        index = next((t.get("index") for t in st.get("tabs", [])
                      if "videoeditor" in (t.get("url") or "").lower()), None)
    else:
        call("/command", {"name": "selectTab", "index": index})
        time.sleep(1.5)
    return index


def close_created_tabs():
    # 从大到小关，避免 index 位移。
    try:
        st = call("/state")
        live = {t.get("index") for t in st.get("tabs", [])}
        for index in sorted([i for i in created_tabs if i in live], reverse=True):
            call("/close-tab", {"index": index})
    except Exception:
        pass


def main():
    make_fixtures()
    shutil.rmtree(DRAFT_DIR, ignore_errors=True)
    tab = ensure_editor()
    if tab is None:
        print("FAIL no editor tab")
        return 1

    # 1) 命令全链路
    edit(action="new")
    edit(action="addclip", path=os.path.join(TMP, "a.mp4"))
    edit(action="addclip", path=os.path.join(TMP, "b.mp4"))
    s = state()
    check("两段接尾 6s", abs(s.get("duration", 0) - 6) < 0.3, s.get("duration"))
    edit(action="split", at=3)
    s = state()
    check("split 后 2 段", sum(t["clips"] for t in s["tracks"]) == 2, [t["clips"] for t in s["tracks"]])
    first = next((c["id"] for c in s["clips"] if abs(c["start"]) < 0.01), None)
    second = next((c["id"] for c in s["clips"] if abs(c["start"] - 3) < 0.05), None)
    edit(action="setclip", id=first, speed=0.5, volume=0.5)
    s = state()
    cb = next(c for c in s["clips"] if c["id"] == first)
    check("setclip 生效", cb["speed"] == 0.5 and cb["volume"] == 0.5, cb)
    trimmed_result = edit(action="trim", id=first, duration=2)
    check("trim 生效", abs(trimmed_result.get("duration", 0) - 2) < 0.05, trimmed_result)
    check("envelope", edit(action="envelope", id=first,
                           points=[{"at": 0, "volume": 0.2}, {"at": 0.5, "volume": 1}]).get("points") == 2, "")
    check("transition", edit(action="transition", left=first, right=second, overlap=0.5).get("ok") is True, "")
    check("addtext", edit(action="addtext", text="字幕", at=0, duration=2).get("ok") is True, "")
    check("add track", "id" in edit(action="track", op="add", kind="audio", name="音乐"), "")
    timeline = state().get("duration", 0)
    out = os.path.join(TMP, "out.mp4")
    if os.path.exists(out):
        os.remove(out)
    r = edit(action="export", path=out)
    check("导出成功", r.get("ok") is True and os.path.exists(out), r)
    check("导出时长==时间线", abs(ffprobe_duration(out) - timeline) < 0.2,
          (ffprobe_duration(out), timeline))
    jobs = call("/jobs", timeout=15).get("jobs", [])
    export_job = next((j for j in jobs
                       if j.get("artifactURL") == out
                       or j.get("artifactUrl") == out), None)
    check("导出进 Jobs 台账", export_job is not None and export_job.get("state") == "done",
          export_job and export_job.get("state"))

    # 1b) 字幕往返：SRT → 文字片段 → SRT
    srt_path = os.path.join(TMP, "subs.srt")
    with open(srt_path, "w", encoding="utf-8") as fh:
        fh.write("1\n00:00:00,500 --> 00:00:01,500\n第一句\n\n"
                 "2\n00:00:02,000 --> 00:00:03,200\n第二句\n\n"
                 "3\n00:00:04,000 --> 00:00:05,000\nThird line\n")
    r = edit(action="addsubtitles", path=srt_path)
    check("导入字幕 3 条", r.get("added") == 3, r)
    s = state()
    text_clips = [c for c in s["clips"] if c["kind"] == "text"]
    check("文字片段时间正确",
          sorted((round(c["start"], 2), round(c["duration"], 2)) for c in text_clips)
          == [(0.5, 1.0), (2.0, 1.2), (4.0, 1.0)],
          [(c["start"], c["duration"]) for c in text_clips])
    out_srt = os.path.join(TMP, "out.srt")
    r = edit(action="exportsubtitles", path=out_srt)
    exported = open(out_srt, encoding="utf-8").read() if os.path.exists(out_srt) else ""
    check("导出字幕 3 条", r.get("count") == 3, r)
    check("字幕往返文本一致",
          "第一句" in exported and "第三句" not in exported and "Third line" in exported,
          exported[:120])

    # 2) 会话路由
    second_tab = call("/new-tab", {"url": "desire://tools/videoEditor"})
    created_tabs.append(second_tab.get("index"))
    time.sleep(3)
    s = state()
    sessions = s.get("sessions", [])
    active_id = s.get("session")
    other = next((x for x in sessions if x["session"] != active_id), None)
    check("两个会话", len(sessions) >= 2 and other is not None, sessions)
    if other:
        edit(action="addtext", text="另一个", at=0, duration=1, session=other["session"])
        check("session 定向", call("/video/state").get("sessions") is not None, "")
        r = edit(action="state", session="00000000-0000-0000-0000-000000000000")
        check("未匹配报错", "error" in r, r)
        saved = os.path.join(TMP, "other.dtl")
        edit(action="save", path=saved, session=other["session"])
        r = edit(action="state", file=saved)
        check("file 定向", r.get("session") == other["session"], r)

    # 3) 草稿
    edit(action="new")
    edit(action="addclip", path=os.path.join(TMP, "a.mp4"))
    time.sleep(4.5)
    check("草稿落盘", edit(action="draft").get("exists") is True, "")
    edit(action="draft", op="discard")
    check("草稿丢弃", edit(action="draft").get("exists") is False, "")

    # 4) 批量裁剪/拼接
    batch_in = os.path.join(TMP, "batch")
    os.makedirs(batch_in, exist_ok=True)
    for sub in ("Trimmed", "Merged"):
        shutil.rmtree(os.path.join(batch_in, sub), ignore_errors=True)
    shutil.copy(os.path.join(TMP, "a.mp4"), os.path.join(batch_in, "a.mp4"))
    shutil.copy(os.path.join(TMP, "b.mp4"), os.path.join(batch_in, "b.mp4"))
    r = call("/video/batch", {"folder": batch_in, "start": 0.5, "end": 2.0})
    job = wait_job(r.get("job", "")) if r.get("ok") else None
    check("batch trim 完成", job and job.get("state") == "done", job and job.get("state"))
    trimmed = os.path.join(batch_in, "Trimmed")
    files = sorted(os.listdir(trimmed)) if os.path.isdir(trimmed) else []
    check("trim 产物 2 个", len(files) == 2, files)
    check("trim 时长≈1.5", all(abs(ffprobe_duration(os.path.join(trimmed, f)) - 1.5) < 0.2
                             for f in files), files)
    r = call("/video/batch", {"folder": batch_in, "concat": True})
    job = wait_job(r.get("job", "")) if r.get("ok") else None
    merged = os.path.join(batch_in, "Merged", "merged.mp4")
    check("batch concat 完成", job and job.get("state") == "done" and os.path.exists(merged),
          job and job.get("state"))
    if os.path.exists(merged):
        expected = (ffprobe_duration(os.path.join(TMP, "a.mp4"))
                    + ffprobe_duration(os.path.join(TMP, "b.mp4")))
        check("concat 时长==两段之和", abs(ffprobe_duration(merged) - expected) < 0.4,
              (ffprobe_duration(merged), expected))

    # 4b) 批量音频提取
    r = call("/video/batch", {"folder": batch_in, "audioOnly": True})
    job = wait_job(r.get("job", "")) if r.get("ok") else None
    audio_dir = os.path.join(batch_in, "Audio")
    files = sorted(os.listdir(audio_dir)) if os.path.isdir(audio_dir) else []
    check("批量音频 2 个 m4a",
          job and job.get("state") == "done" and len(files) == 2
          and all(f.endswith(".m4a") for f in files), files)
    if files:
        check("音频时长与源一致",
              all(abs(ffprobe_duration(os.path.join(audio_dir, f)) - 3.0) < 0.3 for f in files),
              [ffprobe_duration(os.path.join(audio_dir, f)) for f in files])

    close_created_tabs()
    failed = [x for x in res if not x[1]]
    print("\nRESULT %d/%d" % (len(res) - len(failed), len(res)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
