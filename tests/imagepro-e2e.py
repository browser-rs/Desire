#!/usr/bin/env python3
"""ImagePro 回归套件（v0.8.85 批 1 第 19 件）。

11k 行编辑器的护栏：合成真实事件链 + 命令 API + **保存后读落盘像素**。
历次 E2E（工具矩阵 23/23、路由 15、文本 14、还原 13）都散在 /tmp 已丢——
本套件把它们收进仓库，并按批扩展。

用法：
  python3 tests/imagepro-e2e.py [--section tools|color|adjustments|all]
                                [--require-pending] [--data-dir DIR] [--keep]
  tests/run-imagepro.sh            # 标准入口（fresh + activate + 全量）

节：tools（工具矩阵，基线）｜color（色彩管线，件 1 先红后绿）｜
    adjustments（HSL/色阶/分离色调，件 2）｜layers/transform/brush/select/
    project/agent（随批 2–3/下版实现，暂 skip）。
封闭性：实例必须带 --data-dir（/state.startup 三项 prefs=isolated、secrets=file）；
否则拒绝运行。像素断言一律读落盘文件（tests/tools/imagepro-probe.swift）。
"""

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
BRIDGE = "http://127.0.0.1:8799"
WORK = pathlib.Path(tempfile.mkdtemp(prefix="imagepro-e2e-"))
PROBE = WORK / "imagepro-probe"
RESULTS = []  # (section, name, status, detail) status: ok/fail/pending/skip


# ── 基础设施 ───────────────────────────────────────────────

def http(method, url, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if body else {})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode()
    return json.loads(raw) if raw else {}


def bridge(method, path, body=None, timeout=60):
    return http(method, BRIDGE + path, body, timeout)


def wait_bridge(timeout=40):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            return bridge("GET", "/state", timeout=2)
        except Exception:
            time.sleep(0.4)
    raise RuntimeError("bridge did not come up")


def ensure_instance(data_dir=None):
    """桥不可达时自启封闭实例；可达时必须已是封闭实例且前台激活。"""
    try:
        st = bridge("GET", "/state", timeout=2)
    except Exception:
        cmd = [str(ROOT / "tools/launch-hermetic.sh")]
        cmd.append(data_dir or "--fresh")
        cmd.append("--activate")
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
        st = wait_bridge()
    startup = st.get("startup") or {}
    if startup.get("prefs") != "isolated" or startup.get("secrets") != "file":
        raise RuntimeError(f"拒绝运行：实例不是封闭实例（startup={startup}）")
    if not st.get("isActive"):
        subprocess.run(["osascript", "-e", 'tell application "Desire" to activate'],
                       capture_output=True)
        time.sleep(2)
        st = bridge("GET", "/state")
        if not st.get("isActive"):
            raise RuntimeError("实例未激活——浏览器/编辑器端点与合成事件不可用")
    if not (st.get("tabs") or []):
        raise RuntimeError("实例没有标签页（先 quit 再 open）")
    return st


def build_probe():
    src = ROOT / "tests/tools/imagepro-probe.swift"
    subprocess.run(["swiftc", "-O", str(src), "-o", str(PROBE)],
                   check=True, capture_output=True)
    return PROBE


def probe(*args, timeout=120):
    out = subprocess.run([str(PROBE), *map(str, args)], capture_output=True, timeout=timeout)
    raw = out.stdout.decode().strip()
    try:
        return json.loads(raw)
    except Exception:
        raise RuntimeError(f"probe {args[0]} failed: {out.stderr.decode()[:400]} {raw[:200]}")


def make_fixture(name, **kwargs):
    path = WORK / name
    args = ["make", str(path)]
    for key, value in kwargs.items():
        args += [f"--{key}", str(value)]
    res = probe(*args)
    assert res.get("ok"), res
    return path


def read_pixels(path, points, space="sRGB"):
    pts = ";".join(f"{x},{y}" for x, y in points)
    return probe("read", str(path), "--points", pts, "--space", space)


def pixel(path, x, y):
    res = read_pixels(path, [(x, y)])
    sample = (res.get("samples") or [{}])[0]
    return sample.get("rgba")


def diff_pixels(a, b, tol=0, exclude=None, space="sRGB"):
    args = ["diff", str(a), str(b), "--tol", str(tol), "--space", space]
    if exclude:
        args += ["--exclude", ",".join(str(v) for v in exclude)]
    return probe(*args)


# ── 编辑器驱动 ─────────────────────────────────────────────

SESSIONS = {}  # basename -> session id


def open_editor(path):
    res = bridge("POST", "/open-file", {"path": str(path)})
    if res.get("error"):
        raise RuntimeError(f"open-file: {res['error']}")
    name = os.path.basename(str(path))
    deadline = time.time() + 25
    while time.time() < deadline:
        st = bridge("GET", "/image/state")
        if st.get("ok"):
            f = st.get("file") or ""
            if os.path.basename(f) == name and st.get("width"):
                for entry in st.get("sessions") or []:
                    if os.path.basename(entry.get("file") or "") == name:
                        SESSIONS[name] = entry["id"]
                        return st
        time.sleep(0.35)
    raise RuntimeError(f"editor did not come up for {name}")


def sid(path):
    return SESSIONS.get(os.path.basename(str(path)))


def state_of(path, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        res = bridge("GET", "/image/state?" + urllib.parse.urlencode({"session": sid(path)}))
        if res.get("ok"):
            return res
        time.sleep(0.2)
    raise RuntimeError(f"state failed for {os.path.basename(str(path))}: {res}")


def edit(doc, **body):
    payload = dict(body)
    payload["session"] = sid(doc)
    res = bridge("POST", "/image/edit", payload)
    if res.get("error") or res.get("ok") is False:
        raise RuntimeError(f"edit {body.get('action')}: {res}")
    return res


def save(path):
    edit(path, action="save")
    time.sleep(0.15)
    return pathlib.Path(str(path))


def synth(**body):
    res = bridge("POST", "/editor/synthetic", body)
    if res.get("error"):
        raise RuntimeError(f"synthetic {body.get('action')}: {res['error']}")
    return res


def probe_state():
    return synth(action="state").get("state") or {}


def wait_probe(expected_width=None, timeout=15):
    deadline = time.time() + timeout
    last = {}
    while time.time() < deadline:
        last = probe_state()
        if last.get("catcherRectW", 0) > 0:
            if expected_width is None or abs(last.get("baseW", 0) - expected_width) < 1:
                return last
        time.sleep(0.25)
    raise RuntimeError(f"canvas probe not ready: {last}")


def base_to_window(ps, bx, by):
    """base 像素（左上原点 y 向下）→ 窗口基点（左下原点）。
    先经 transform：canvas = origin + base × (contentW/baseW)（display 降采样
    也成立——syncProbe 的 dispW = contentSize），再叠 catcherRect 并翻转 y。"""
    scale = ps["dispW"] / ps["baseW"]
    cx = ps["originX"] + bx * scale
    cy = ps["originY"] + by * scale
    return (ps["catcherRectX"] + cx, ps["catcherRectY"] + ps["catcherRectH"] - cy)


def synth_drag(path, from_base, to_base):
    ps = wait_probe(state_of(path)["width"])
    x1, y1 = base_to_window(ps, *from_base)
    x2, y2 = base_to_window(ps, *to_base)
    synth(action="drag", x1=x1, y1=y1, x2=x2, y2=y2)
    time.sleep(0.25)


def synth_path(path, points):
    ps = wait_probe(state_of(path)["width"])
    pairs = []
    for bx, by in points:
        x, y = base_to_window(ps, bx, by)
        pairs.append([x, y])
    synth(action="path", points=pairs)
    time.sleep(0.25)


def synth_click(path, base_point):
    ps = wait_probe(state_of(path)["width"])
    x, y = base_to_window(ps, *base_point)
    synth(action="click", x1=x, y=y)
    time.sleep(0.25)


def mask_bounds(path, name="mask.png"):
    """dumpmask 落盘 + bbox（绕开 UI 探针的刷新时机）。"""
    target = WORK / name
    edit(path, action="dumpmask", path=str(target))
    res = probe("bbox", str(target))
    if res.get("empty"):
        return None
    return [res["x"], res["y"], res["w"], res["h"]]


def parse_rect_describe(describe):
    """'100 × 80 @ 300,300' → [x, y, w, h]；其它形态 None。"""
    import re
    m = re.match(r"^(\d+) × (\d+) @ (-?\d+),(-?\d+)$", describe or "")
    if not m:
        return None
    w, h, x, y = (int(v) for v in m.groups())
    return [x, y, w, h]


def synth_key(key, **mods):
    synth(action="key", key=key, **mods)
    time.sleep(0.2)


def pending_case(section, name, fn):
    """待实现用例：异常/断言不过都记 pending（红），不打断节内后续。"""
    try:
        ok, detail = fn()
        check(section, name, ok, detail, pending=True)
    except Exception as exc:
        check(section, name, False, str(exc)[:200], pending=True)


def near(a, b, tol):
    return abs(a - b) <= tol


def gray_of(rgba):
    return sum(rgba[:3]) / 3 if rgba else -1


# ── 断言 ───────────────────────────────────────────────────

def check(section, name, ok, detail="", pending=False):
    status = "pending" if (pending and not ok) else ("ok" if ok else "fail")
    RESULTS.append((section, name, status, detail))
    mark = {"ok": "✓", "fail": "✗", "pending": "…"}[status]
    line = f"{mark} {name}"
    if detail and status != "ok":
        line += f" — {detail}"
    print(line)


# ── tools 节（基线：对当前代码必须全绿）────────────────────

def section_tools():
    S = "tools"
    blocks = make_fixture("t_blocks.png", pattern="blocks")

    st = open_editor(blocks)
    check(S, "打开 800×600 PNG → 编辑器就绪",
          st["width"] == 800 and st["height"] == 600 and len(st["layers"]) == 1,
          f"state={st.get('width')}x{st.get('height')} layers={len(st.get('layers', []))}")

    edit(blocks, action="select", kind="rect", rect=[300, 300, 100, 80])
    b = parse_rect_describe(state_of(blocks)["selection"])
    check(S, "选区：矩形命令 → bounds 精确",
          b is not None and near(b[0], 300, 2) and near(b[1], 300, 2)
          and near(b[2], 100, 2) and near(b[3], 80, 2), f"describe={state_of(blocks)['selection']}")

    edit(blocks, action="select", kind="rect", rect=[350, 340, 60, 40], mode="subtract")
    edit(blocks, action="select", kind="invert")
    edit(blocks, action="select", kind="clear")
    st = state_of(blocks)
    check(S, "选区：减选/反选/清除链路", st["selectionEmpty"] is True)

    edit(blocks, action="select", kind="wand", at=[200, 175], tolerance=32)
    b = mask_bounds(blocks, "t_wand_mask.png")
    check(S, "魔棒：红块整块选中（bounds≈100,100,200,150）",
          b is not None and near(b[0], 100, 4) and near(b[1], 100, 4)
          and near(b[2], 200, 4) and near(b[3], 150, 4), f"bounds={b}")

    edit(blocks, action="select", kind="lasso", points=[[350, 60], [500, 60], [430, 180]])
    b = mask_bounds(blocks, "t_lasso_mask.png")
    check(S, "套索：三角形顶点链 → bounds≈150×120",
          b is not None and near(b[0], 350, 6) and near(b[1], 60, 6)
          and near(b[2], 150, 8) and near(b[3], 120, 8), f"bounds={b}")
    edit(blocks, action="select", kind="clear")

    edit(blocks, action="brush", points=[[400, 50]], size=40, color="#FF0000")
    save(blocks)
    center = pixel(blocks, 400, 50)
    outside = pixel(blocks, 400, 100)
    check(S, "画笔（命令）：落点红 / 半径外白",
          center and center[0] > 230 and center[1] < 60
          and outside and outside[0] > 240 and outside[1] > 240,
          f"center={center} outside={outside}")

    edit(blocks, action="eraser", points=[[200, 175]], size=60)
    save(blocks)
    erased = pixel(blocks, 200, 175)
    check(S, "橡皮（命令）：中心 alpha=0", erased and erased[3] < 10, f"rgba={erased}")

    edit(blocks, action="undo")
    save(blocks)
    check(S, "撤销：橡皮撤销后红块恢复", (pixel(blocks, 200, 175) or [0])[0] > 230)
    edit(blocks, action="redo")
    save(blocks)
    check(S, "重做：再次擦除", (pixel(blocks, 200, 175) or [255])[3] < 10)

    fill_fixture = make_fixture("t_fill.png", pattern="blocks")
    open_editor(fill_fixture)
    edit(fill_fixture, action="fill", color="#00FF00")
    save(fill_fixture)
    g = pixel(fill_fixture, 400, 50)
    check(S, "填充：整层变绿", g and g[1] > 230 and g[0] < 30, f"rgba={g}")

    grad = make_fixture("t_grad.png", pattern="blocks")
    open_editor(grad)
    edit(grad, action="gradient", **{"from": [0, 300], "to": [799, 300]},
         start="#000000", end="#FFFFFF")
    save(grad)
    left = gray_of(pixel(grad, 10, 300) or [255] * 4)
    right = gray_of(pixel(grad, 780, 300) or [0] * 4)
    check(S, "渐变：左黑右白", left < 60 and right > 200, f"left={left} right={right}")

    shape_fixture = make_fixture("t_shape.png", pattern="blocks")
    open_editor(shape_fixture)
    edit(shape_fixture, action="shape", kind="rectangle",
         **{"from": [600, 300], "to": [700, 380]}, stroke="#FF00FF", width=8)
    save(shape_fixture)
    border = pixel(shape_fixture, 602, 340)
    inner = pixel(shape_fixture, 650, 340)
    check(S, "形状：矩形描边品红 / 内部白",
          border and border[0] > 200 and border[2] > 200 and border[1] < 80
          and inner and inner[0] > 240 and inner[1] > 240, f"border={border} inner={inner}")

    text_fixture = make_fixture("t_text.png", pattern="blocks")
    open_editor(text_fixture)
    edit(text_fixture, action="text", text="AB", at=[350, 300], size=48)
    st = state_of(text_fixture)
    check(S, "文字：新建文字图层", len(st["layers"]) == 2 and st["layers"][-1]["text"] is True,
          f"layers={[(l['name'], l['text']) for l in st['layers']]}")

    adj_fixture = make_fixture("t_adj.png", pattern="blocks")
    open_editor(adj_fixture)
    edit(adj_fixture, action="adjust", exposure=-1.5)
    save(adj_fixture)
    dark = gray_of(pixel(adj_fixture, 600, 475) or [255] * 4)
    check(S, "调整：曝光 -1.5 灰块变暗（<100）", 0 <= dark < 100, f"gray={dark}")

    filt_fixture = make_fixture("t_filter.png", pattern="blocks")
    open_editor(filt_fixture)
    edit(filt_fixture, action="filter", name="mono")
    save(filt_fixture)
    mono = pixel(filt_fixture, 200, 175)
    check(S, "滤镜：mono 后红块变灰（r≈g≈b）",
          mono and abs(mono[0] - mono[1]) < 20 and abs(mono[1] - mono[2]) < 20,
          f"rgba={mono}")

    layer_fixture = make_fixture("t_layers.png", pattern="blocks")
    open_editor(layer_fixture)
    edit(layer_fixture, action="layer", op="add")
    edit(layer_fixture, action="layer", op="duplicate")
    n3 = len(state_of(layer_fixture)["layers"])
    edit(layer_fixture, action="layer", op="delete")
    n2 = len(state_of(layer_fixture)["layers"])
    edit(layer_fixture, action="layer", op="merge")
    n1 = len(state_of(layer_fixture)["layers"])
    check(S, "图层：增/复制/删/向下合并计数",
          n3 == 3 and n2 == 2 and n1 == 1, f"n3={n3} n2={n2} n1={n1}")

    move_fixture = make_fixture("t_move.png", pattern="blocks")
    open_editor(move_fixture)
    edit(move_fixture, action="move", dx=50, dy=30)
    st = state_of(move_fixture)
    save(move_fixture)
    at_120 = pixel(move_fixture, 120, 120)
    check(S, "移动：offset=[50,30] 且内容位移",
          near(st["layerOffset"][0], 50, 1) and near(st["layerOffset"][1], 30, 1)
          and at_120 and at_120[0] > 240 and at_120[1] > 240,
          f"offset={st['layerOffset']} rgba={at_120}")

    rot_fixture = make_fixture("t_rot.png", pattern="blocks")
    open_editor(rot_fixture)
    edit(rot_fixture, action="rotate", direction="cw")
    st = state_of(rot_fixture)
    check(S, "旋转：800×600 → 600×800", st["width"] == 600 and st["height"] == 800,
          f"{st['width']}x{st['height']}")

    flip_fixture = make_fixture("t_flip.png", pattern="blocks")
    open_editor(flip_fixture)
    edit(flip_fixture, action="flip", axis="h")
    save(flip_fixture)
    mirrored = pixel(flip_fixture, 600, 175)
    check(S, "翻转：水平翻转后红块到右侧", mirrored and mirrored[0] > 230 and mirrored[1] < 60,
          f"rgba={mirrored}")

    crop_fixture = make_fixture("t_crop.png", pattern="blocks")
    open_editor(crop_fixture)
    edit(crop_fixture, action="crop", rect=[100, 100, 400, 300])
    st = state_of(crop_fixture)
    save(crop_fixture)
    info = probe("read", str(crop_fixture))
    check(S, "裁剪：画布与落盘尺寸 400×300",
          st["width"] == 400 and st["height"] == 300
          and info["w"] == 400 and info["h"] == 300,
          f"state={st['width']}x{st['height']} file={info['w']}x{info['h']}")

    restore_fixture = make_fixture("t_restore.png", pattern="blocks")
    open_editor(restore_fixture)
    edit(restore_fixture, action="fill", color="#123456")
    avail = state_of(restore_fixture)["originalAvailable"]
    edit(restore_fixture, action="restoreall")
    save(restore_fixture)
    restored = pixel(restore_fixture, 200, 175)
    check(S, "还原全部：originalAvailable → 红块回来",
          avail is True and restored and restored[0] > 230 and restored[1] < 60,
          f"avail={avail} rgba={restored}")

    synth_fixture = make_fixture("t_synth.png", pattern="blocks")
    open_editor(synth_fixture)
    edit(synth_fixture, action="settool", tool="marquee")
    time.sleep(0.3)
    synth_drag(synth_fixture, (350, 60), (500, 160))
    b = probe_state().get("selectionBounds") or []
    check(S, "合成事件：拖拽选框 → bounds≈150×100",
          len(b) == 4 and near(b[2], 150, 10) and near(b[3], 100, 10), f"bounds={b}")

    edit(synth_fixture, action="select", kind="clear")  # 上一条选框的选区会裁剪画笔
    edit(synth_fixture, action="settool", tool="brush")
    time.sleep(0.3)
    synth_path(synth_fixture, [(50, 300), (750, 300)])
    save(synth_fixture)
    stroke = pixel(synth_fixture, 400, 300)
    check(S, "合成事件：画笔画线 → 中点非白",
          stroke and not (stroke[0] > 240 and stroke[1] > 240 and stroke[2] > 240),
          f"rgba={stroke}")

    crop_synth = make_fixture("t_cropsynth.png", pattern="blocks")
    open_editor(crop_synth)
    edit(crop_synth, action="settool", tool="crop")
    time.sleep(0.3)
    synth_drag(crop_synth, (150, 120), (700, 520))
    synth_key("return")
    time.sleep(0.4)
    st = state_of(crop_synth)
    check(S, "合成事件：裁剪框拖拽 + ⏎ → ≈550×400",
          near(st["width"], 550, 12) and near(st["height"], 400, 12),
          f"{st['width']}x{st['height']}")

    synth_key("b")
    t1 = state_of(crop_synth)["tool"]
    synth_key("v")
    t2 = state_of(crop_synth)["tool"]
    check(S, "键盘：b→brush / v→move", t1 == "brush" and t2 == "move", f"{t1}/{t2}")


# ── color 节（件 1：先红后绿）──────────────────────────────

def section_color():
    S = "color"
    fixture = make_fixture("c_blocks16p3.png", pattern="blocks", depth=16, space="p3")
    info = probe("read", str(fixture))
    check(S, "fixture 自检：16 bpc + Display P3",
          info["bpc"] == 16 and "P3" in (info.get("cs") or ""), f"{info['bpc']}bpc {info.get('cs')}")

    st = open_editor(fixture)

    def source_format_recorded():
        pf = state_of(fixture).get("pixelFormat") or {}
        return (pf.get("bitDepth") == 16 and "P3" in str(pf.get("sourceProfile", "")),
                f"pixelFormat={pf}")
    pending_case(S, "打开后文档记录源位深/配置（pixelFormat.bitDepth=16, sourceProfile≈P3）",
                 source_format_recorded)

    def stroke_keeps_depth():
        edit(fixture, action="brush", points=[[400, 300]], size=40, color="#FF0000")
        save(fixture)
        saved = probe("read", str(fixture))
        return (saved["bpc"] == 16 and "P3" in (saved.get("cs") or ""),
                f"{saved['bpc']}bpc {saved.get('cs')}")
    pending_case(S, "落一笔保存：文件仍 16 bpc + Display P3", stroke_keeps_depth)

    def outside_untouched():
        # 在 P3 空间比：sRGB 空间会把广色域裁剪（P3 纯红 → 裁剪后 sRGB 红）
        # 掩盖掉，8 位 sRGB 对比恒等——只有同空间才看得出色域是否保住。
        bak = fixture.with_suffix(".png.bak")
        if not bak.exists():
            return False, "missing .bak"
        d = diff_pixels(bak, fixture, tol=0, exclude=(375, 275, 50, 50), space="p3")
        return d["diff"] == 0, f"p3-diff={d['diff']}"
    pending_case(S, "笔画区域外逐像素不变（P3 空间 diff=0）", outside_untouched)

    def export_srgb():
        jpg = WORK / "c_export_srgb.jpg"
        edit(fixture, action="export", path=str(jpg), format="jpg", quality=0.95,
             profile="srgb")
        j = probe("read", str(jpg))
        gray = gray_of(pixel(jpg, 600, 475) or [0] * 4)
        return ("srgb" in (j.get("cs") or "").lower() and near(gray, 128, 2),
                f"cs={j.get('cs')} gray={gray}")
    # 现状已带 sRGB 标记（kCGColorSpaceSRGB）——当回归项，不标 pending。
    try:
        ok, detail = export_srgb()
        check(S, "导出 sRGB JPEG：嵌入 sRGB、灰块≈128", ok, detail)
    except Exception as exc:
        check(S, "导出 sRGB JPEG：嵌入 sRGB、灰块≈128", False, str(exc)[:200])

    def export_8bit():
        png8 = WORK / "c_export_8.png"
        edit(fixture, action="export", path=str(png8), format="png", depth=8, profile="srgb")
        p8 = probe("read", str(png8))
        return p8["bpc"] == 8, f"bpc={p8['bpc']}"
    try:
        ok, detail = export_8bit()
        check(S, "导出 8 位 PNG：bpc=8（现状回归项）", ok, detail)
    except Exception as exc:
        check(S, "导出 8 位 PNG：bpc=8（现状回归项）", False, str(exc)[:200])

    def export_16p3():
        png16 = WORK / "c_export_16p3.png"
        edit(fixture, action="export", path=str(png16), format="png", depth=16, profile="p3")
        p16 = probe("read", str(png16))
        return (p16["bpc"] == 16 and "P3" in (p16.get("cs") or ""),
                f"{p16['bpc']}bpc {p16.get('cs')}")
    pending_case(S, "导出 16 位 P3 PNG：bpc=16 + P3", export_16p3)


# ── adjustments 节（件 2：HSL/色阶/分离色调）───────────────

def section_adjustments():
    S = "adjustments"
    fixture = make_fixture("a_blocks.png", pattern="blocks")
    open_editor(fixture)

    def hsl_case():
        edit(fixture, action="adjust",
             hsl=[{"range": "red", "hue": 0, "saturation": -100, "luminance": 0}])
        save(fixture)
        red = pixel(fixture, 200, 175)
        blue = pixel(fixture, 200, 475)
        ok = (red and abs(red[0] - red[1]) < 24 and abs(red[1] - red[2]) < 24
              and blue and blue[2] > 200 and blue[0] < 40)
        return ok, f"red={red} blue={blue}"
    pending_case(S, "HSL：红块去饱和变灰、蓝块不动", hsl_case)

    levels_fixture = make_fixture("a_grad.png", pattern="gradient")
    open_editor(levels_fixture)

    def levels_case():
        edit(levels_fixture, action="adjust", levelsBlack=0.25)
        save(levels_fixture)
        mid = gray_of(pixel(levels_fixture, 400, 300) or [255] * 4)
        return 0 <= mid < 110, f"gray={mid}"
    pending_case(S, "色阶：输入黑场 0.25 → 中灰变暗（<110）", levels_case)

    split_fixture = make_fixture("a_split.png", pattern="gradient")
    open_editor(split_fixture)

    def split_case():
        edit(split_fixture, action="adjust", splitShadowHue=30, splitShadowAmount=60)
        save(split_fixture)
        dark = pixel(split_fixture, 10, 300)
        return (dark and dark[0] > dark[2] + 15), f"rgba={dark}"
    pending_case(S, "分离色调：暗部偏暖（r > b）", split_case)


# ── 未实现节（随批 2–3 / 下版）─────────────────────────────

def section_skip(name, when):
    RESULTS.append((name, f"（{when} 实现）", "skip", ""))
    print(f"- {name} 节：{when} 实现，本次跳过")


# ── 主流程 ─────────────────────────────────────────────────

SECTIONS = {
    "tools": section_tools,
    "color": section_color,
    "adjustments": section_adjustments,
    "layers": lambda: section_skip("layers", "批 2（调整图层/矢量形状/工程文件）"),
    "transform": lambda: section_skip("transform", "批 3（自由变换）"),
    "brush": lambda: section_skip("brush", "批 3（画笔引擎）"),
    "select": lambda: section_skip("select", "v0.8.86（智能选区）"),
    "project": lambda: section_skip("project", "批 2（.desimage）"),
    "agent": lambda: section_skip("agent", "v0.8.86（Agent 契约同步）"),
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--section", default="all",
                        help="tools|color|adjustments|all（其余节随批实现）")
    parser.add_argument("--require-pending", action="store_true",
                        help="待实现（红）也判失败——批次收尾/发版闸门用")
    parser.add_argument("--data-dir", default=None)
    parser.add_argument("--keep", action="store_true", help="保留临时工作目录")
    args = parser.parse_args()

    build_probe()
    try:
        ensure_instance(args.data_dir)
        names = list(SECTIONS) if args.section == "all" else [args.section]
        for name in names:
            if name not in SECTIONS:
                raise SystemExit(f"unknown section {name!r}")
            print(f"\n── {name} ──")
            try:
                SECTIONS[name]()
            except Exception as exc:  # 节内崩了记失败，继续下一节
                check(name, f"{name} 节异常", False, str(exc)[:300])
    finally:
        ok = sum(1 for r in RESULTS if r[2] == "ok")
        fail = [r for r in RESULTS if r[2] == "fail"]
        pending = [r for r in RESULTS if r[2] == "pending"]
        skip = [r for r in RESULTS if r[2] == "skip"]
        print(f"\nimagepro-e2e：{ok} 过 / {len(fail)} 失败 / "
              f"{len(pending)} 待实现（红） / {len(skip)} 节跳过")
        for section, name, _, detail in fail:
            print(f"  ✗ [{section}] {name} — {detail}")
        if pending:
            print("  待实现：" + ", ".join(f"[{s}] {n}" for s, n, _, _ in pending))
        if not args.keep:
            shutil.rmtree(WORK, ignore_errors=True)
        strict_fail = bool(fail) or (args.require_pending and bool(pending))
        sys.exit(1 if strict_fail else 0)


if __name__ == "__main__":
    main()
