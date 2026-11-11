#!/usr/bin/env python3
"""多窗口恢复 E2E（v0.8.52 批 1）。

**会优雅退出并重启应用两次**（不动用户标签内容），只在本地、用户同意时跑：

    python3 tests/multi-window-restore-e2e.py --force

流程：
  1. 记录现有窗口 key；用 AX 菜单「新建窗口」开一扇测试窗口；
  2. 在测试窗口导航 example.com 标记 URL，记录两窗 frame；
  3. 优雅退出 → 重新 open；断言两扇窗口都回来（标签/URL/frame 一致）；
  4. 收尾：退出 → 只删除测试窗口的会话文件与索引条目 → 重启，
     断言测试窗口不再出现（用户窗口保留）。

前置：应用以 --automation 运行；终端已获辅助功能权限（AX 菜单用）。
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request

BASE = os.environ.get("DESIRE_BASE", "http://127.0.0.1:8799")
TEST_URL = "https://example.com/?desire-multiwindow-restore=1"
AX_TOOL = "/tmp/desire-axmenupress"
CHECKS = []


def call(path, payload=None, timeout=20):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response)


def ok(label, cond, detail=""):
    CHECKS.append((label, bool(cond)))
    print(("PASS " if cond else "FAIL ") + label + (" — " + str(detail) if detail else ""))


def wait_bridge(seconds=25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            state = call("/state", timeout=3)
            if state.get("tabs") is not None:
                return state
        except Exception:
            pass
        time.sleep(0.5)
    return None


def pid():
    out = subprocess.run(["pgrep", "-x", "Desire"], capture_output=True, text=True).stdout
    return int(out.strip().split("\n")[0]) if out.strip() else None


def app_bundle_path():
    p = pid()
    if not p:
        return None
    command = subprocess.run(["ps", "-o", "command=", "-p", str(p)],
                             capture_output=True, text=True).stdout
    marker = ".app/Contents/MacOS/"
    index = command.find(marker)
    return command[:index + len(".app")] if index > -1 else None


def keyed_windows():
    state = call("/diag/windows")
    return {w.get("sessionKey"): w for w in state.get("windows", []) if w.get("sessionKey")}


def quit_app():
    subprocess.run(["osascript", "-e", 'tell application "Desire" to quit'],
                   capture_output=True)
    deadline = time.time() + 15
    while time.time() < deadline:
        if pid() is None:
            return True
        time.sleep(0.5)
    return pid() is None


def launch(bundle):
    subprocess.run(["open", bundle, "--args", "--automation"], capture_output=True)
    return wait_bridge(30) is not None


def ensure_ax_tool(repo):
    src = os.path.join(repo, "tools", "axmenupress.swift")
    if os.path.exists(AX_TOOL):
        return True
    build = subprocess.run(["swiftc", "-O", src, "-o", AX_TOOL],
                           capture_output=True, text=True)
    return build.returncode == 0 and os.path.exists(AX_TOOL)


def press_new_window():
    subprocess.run(["osascript", "-e", 'tell application "Desire" to activate'],
                   capture_output=True)
    time.sleep(0.6)
    p = pid()
    for label in ("新建窗口", "New Window"):
        result = subprocess.run([AX_TOOL, str(p), label],
                                capture_output=True, text=True)
        if result.returncode == 0:
            return True
    return False


def strip_test_session(key):
    base = os.path.expanduser("~/Library/Application Support/Desire/storage")
    for suffix in (".json", ".json.bak"):
        path = os.path.join(base, key + suffix)
        if os.path.exists(path):
            os.remove(path)
    for name in ("session-index.json", "window-index-v2.json"):
        path = os.path.join(base, name)
        if not os.path.exists(path):
            continue
        data = json.load(open(path, encoding="utf-8"))
        if name == "session-index.json":
            data = [item for item in data if item != key]
        else:
            data = [item for item in data if item.get("sessionKey") != key]
        json.dump(data, open(path, "w", encoding="utf-8"), ensure_ascii=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true",
                        help="确认可以重启应用（默认拒绝，避免误跑）")
    args = parser.parse_args()
    if not args.force:
        print("拒绝执行：会退出并重启应用两次。确认后加 --force。")
        return 2
    try:
        call("/state", timeout=5)
    except Exception as exc:
        print("应用未以 --automation 运行:", exc)
        return 2

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if not ensure_ax_tool(repo):
        print("AX 工具编译失败（需要 swiftc 与辅助功能权限）")
        return 2
    bundle = app_bundle_path()
    if not bundle:
        print("找不到应用 bundle 路径")
        return 2

    before = keyed_windows()
    test_key = None
    try:
        # 窗口诊断与桥探针（v0.8.52 批 3/4）：不改变任何标签。
        diag = call("/diag/windows")
        ok("诊断含 windowIndex 与恢复策略",
           "windowIndex" in diag and "restoreMode" in diag)
        bad = call("/windows/organize", {"mode": "nope"})
        ok("organize 非法模式报错", "error" in bad, bad)
        focus_key = next((k for k, w in before.items() if w.get("isKey")), None) \
            or next(iter(before), None)
        if focus_key:
            focus = call("/windows/focus", {"window": focus_key[8:16]})
            ok("focusWindow 命中窗口", focus.get("ok") is True, focus)
        ok("AX：新建窗口", press_new_window())
        deadline = time.time() + 12
        while time.time() < deadline:
            after = keyed_windows()
            new_keys = [k for k in after if k not in before]
            if new_keys:
                test_key = new_keys[0]
                break
            time.sleep(0.4)
        ok("新窗口已注册会话", test_key is not None, test_key)
        if not test_key:
            return 1

        call("/navigate", {"url": TEST_URL})
        time.sleep(3)
        windows = keyed_windows()
        saved = {key: (w.get("frame") or {}, w.get("url") or "")
                 for key, w in windows.items()}
        ok("测试窗口 URL 正确",
           TEST_URL in (windows.get(test_key, {}).get("url") or ""),
           windows.get(test_key, {}).get("url"))

        ok("优雅退出", quit_app())
        ok("重启后桥可达", launch(bundle))

        deadline = time.time() + 30
        restored = {}
        while time.time() < deadline:
            restored = keyed_windows()
            if test_key in restored and len(restored) >= len(before) + 1:
                break
            time.sleep(0.7)
        ok("两扇窗口都恢复", test_key in restored and len(restored) >= len(before) + 1,
           list(restored.keys()))
        ok("测试窗口标签恢复",
           TEST_URL in (restored.get(test_key, {}).get("url") or ""),
           restored.get(test_key, {}).get("url"))

        frame_ok = True
        frame_detail = []
        # frame 还原在窗口挂载后最多校正 ~4s（SwiftUI 多窗会晚一次级联），
        # 所以这里轮询到稳定或 8s 超时。
        deadline = time.time() + 8
        last = restored
        while time.time() < deadline:
            last = keyed_windows()
            frame_ok = True
            frame_detail = []
            for key in set(saved) & set(last):
                old = saved[key][0] or {}
                new = last[key].get("frame") or {}
                for dim in ("x", "y"):
                    if old.get(dim) is not None and new.get(dim) is not None \
                            and abs(float(old[dim]) - float(new[dim])) > 3:
                        frame_ok = False
                        frame_detail.append((key, dim, old.get(dim), new.get(dim)))
            if frame_ok:
                break
            time.sleep(0.6)
        ok("窗口位置恢复（≤3pt）", frame_ok, frame_detail)
        index = call("/diag/windows").get("windowIndex", [])
        ok("window-index-v2 含测试窗口",
           any(item.get("sessionKey") == test_key for item in index),
           [item.get("sessionKey") for item in index])
    finally:
        # 收尾：退出 → 只删测试窗口会话 → 重启（用户窗口照常恢复）
        if test_key:
            if quit_app():
                strip_test_session(test_key)
            launch(bundle)
            deadline = time.time() + 20
            gone = False
            while time.time() < deadline:
                remaining = keyed_windows()
                if test_key not in remaining:
                    gone = True
                    break
                time.sleep(0.6)
            ok("清理：测试窗口不再恢复", gone, list(keyed_windows().keys()))

    failed = [item for item in CHECKS if not item[1]]
    print("\nRESULT %d/%d" % (len(CHECKS) - len(failed), len(CHECKS)))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
