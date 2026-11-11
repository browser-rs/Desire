#!/usr/bin/env python3
"""整窗重开 E2E（v0.8.52 批 2）。

**会开关应用窗口**（测试窗口自建自清，不碰用户标签），--force 才跑：

    python3 tests/closed-window-restore-e2e.py --force

流程：
  1. AX 菜单「新建窗口」→ 测试窗口加载标记 URL；
  2. AX「关闭窗口」关掉它 → 断言 closed-windows 账本记录到该 URL；
  3. 桥命令 reopenClosedWindow（= File 菜单项 / ⌘⇧T 回退）→ 断言新窗带回标记 URL；
  4. 收尾：关掉测试窗口，退出应用清掉测试会话/归档/账本条目，重启。

前置：应用以 --automation 运行；终端有辅助功能权限。
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request

BASE = os.environ.get("DESIRE_BASE", "http://127.0.0.1:8799")
TEST_URL = "https://example.com/?desire-closed-window-test=1"
AX_TOOL = "/tmp/desire-axmenupress"
CHECKS = []
STORAGE = os.path.expanduser("~/Library/Application Support/Desire/storage")


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


def press_menu(*labels):
    subprocess.run(["osascript", "-e", 'tell application "Desire" to activate'],
                   capture_output=True)
    time.sleep(0.5)
    p = pid()
    for label in labels:
        result = subprocess.run([AX_TOOL, str(p), label], capture_output=True, text=True)
        if result.returncode == 0:
            return True
    return False


def quit_app():
    subprocess.run(["osascript", "-e", 'tell application "Desire" to quit'], capture_output=True)
    deadline = time.time() + 15
    while time.time() < deadline:
        if pid() is None:
            return True
        time.sleep(0.5)
    return pid() is None


def launch(bundle):
    subprocess.run(["open", bundle, "--args", "--automation"], capture_output=True)
    return wait_bridge(30) is not None


def closed_book_records():
    path = os.path.join(STORAGE, "closed-windows.json")
    if not os.path.exists(path):
        return []
    try:
        return json.load(open(path, encoding="utf-8"))
    except Exception:
        return []


def contains_test_url(record):
    for tab in record.get("session", {}).get("tabs", []):
        if tab.get("url") and "desire-closed-window-test" in tab.get("url", ""):
            return True
    return False


def strip_test_sessions():
    """删掉测试窗口的会话文件与索引/归档条目、账本条目（应用已退出）。"""
    test_keys = []
    for name in sorted(os.listdir(STORAGE)):
        if not name.startswith("session-") or not name.endswith(".json"):
            continue
        path = os.path.join(STORAGE, name)
        try:
            data = json.load(open(path, encoding="utf-8"))
        except Exception:
            continue
        tabs = data.get("tabs", []) if isinstance(data, dict) else data
        if any(isinstance(tab, dict) and "desire-closed-window-test" in (tab.get("url") or "")
               for tab in tabs):
            test_keys.append(name[:-5])
    for key in test_keys:
        for suffix in (".json", ".json.bak"):
            path = os.path.join(STORAGE, key + suffix)
            if os.path.exists(path):
                os.remove(path)
    for index_name in ("session-index.json", "window-index-v2.json"):
        path = os.path.join(STORAGE, index_name)
        if not os.path.exists(path):
            continue
        data = json.load(open(path, encoding="utf-8"))
        if index_name == "session-index.json":
            data = [k for k in data if k not in test_keys]
        else:
            data = [s for s in data if s.get("sessionKey") not in test_keys]
        json.dump(data, open(path, "w", encoding="utf-8"), ensure_ascii=False)
    # 归档文件
    archive_dir = os.path.expanduser("~/Library/Application Support/Desire/session-archives")
    if os.path.isdir(archive_dir):
        for name in os.listdir(archive_dir):
            path = os.path.join(archive_dir, name)
            try:
                data = json.load(open(path, encoding="utf-8"))
            except Exception:
                continue
            tabs = data.get("tabs", []) if isinstance(data, dict) else data
            if any(isinstance(tab, dict) and "desire-closed-window-test" in (tab.get("url") or "")
                   for tab in tabs):
                os.remove(path)
                idx = os.path.join(STORAGE, "session-archive-index.json")
                if os.path.exists(idx):
                    entries = json.load(open(idx, encoding="utf-8"))
                    entries = [e for e in entries if e != name]
                    json.dump(entries, open(idx, "w", encoding="utf-8"))
    # 账本条目
    book = os.path.join(STORAGE, "closed-windows.json")
    if os.path.exists(book):
        records = [r for r in closed_book_records() if not contains_test_url(r)]
        json.dump(records, open(book, "w", encoding="utf-8"), ensure_ascii=False)
    return test_keys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true", help="确认可开关窗口并重启应用")
    args = parser.parse_args()
    if not args.force:
        print("拒绝执行：会开关窗口并重启应用。确认后加 --force。")
        return 2
    try:
        call("/state", timeout=5)
    except Exception as exc:
        print("应用未以 --automation 运行:", exc)
        return 2
    bundle = app_bundle_path()
    before = keyed_windows()
    try:
        ok("AX：新建窗口", press_menu("新建窗口", "New Window"))
        deadline = time.time() + 12
        test_key = None
        while time.time() < deadline:
            after = keyed_windows()
            new_keys = [k for k in after if k not in before]
            if new_keys:
                test_key = new_keys[0]
                break
            time.sleep(0.4)
        ok("测试窗口已注册", test_key is not None, test_key)
        if not test_key:
            return 1
        call("/navigate", {"url": TEST_URL})
        time.sleep(2.5)

        keyed_key = next((k for k, w in keyed_windows().items() if w.get("isKey")), None)
        ok("测试窗口是 key 窗口（避免误关用户窗口）", keyed_key == test_key, keyed_key)
        if keyed_key != test_key:
            return 1
        ok("AX：关闭窗口", press_menu("关闭窗口", "Close Window"))
        # 记录是延迟 1.5s 判定 + DiskStore 500ms 防抖：等落盘再断言账本。
        time.sleep(4)
        remaining = keyed_windows()
        ok("测试窗口已关闭", test_key not in remaining, list(remaining.keys()))
        records = closed_book_records()
        ok("整窗账本已记录测试窗口", any(contains_test_url(r) for r in records),
           [(r.get("title"), r.get("closedAt")) for r in records][:3])

        call("/command", {"name": "reopenClosedWindow"})
        deadline = time.time() + 15
        reopened_key = None
        while time.time() < deadline:
            now = keyed_windows()
            for key, window in now.items():
                if key not in remaining and TEST_URL in (window.get("url") or ""):
                    reopened_key = key
                    break
            if reopened_key:
                break
            time.sleep(0.5)
        ok("整窗重开带回标签", reopened_key is not None,
           {k: (w.get("url") or "")[:60] for k, w in keyed_windows().items()})
        if reopened_key:
            keyed_key = next((k for k, w in keyed_windows().items() if w.get("isKey")), None)
            if keyed_key == reopened_key:
                press_menu("关闭窗口", "Close Window")
                time.sleep(1.5)
    finally:
        if quit_app():
            removed = strip_test_sessions()
            print("清理测试会话:", removed)
        launch(bundle)
        deadline = time.time() + 20
        clean = False
        while time.time() < deadline:
            if not any("desire-closed-window-test" in (w.get("url") or "")
                       for w in keyed_windows().values()):
                clean = True
                break
            time.sleep(0.5)
        ok("清理：无测试窗口残留", clean)

    failed = [item for item in CHECKS if not item[1]]
    print("\nRESULT %d/%d" % (len(CHECKS) - len(failed), len(CHECKS)))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
