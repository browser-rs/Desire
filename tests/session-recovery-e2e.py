#!/usr/bin/env python3
"""会话恢复 / 无窗自愈 E2E（v0.8.49 批 1）。

**会强杀应用进程**（`pkill -9`）——只在本地、且用户同意的时间窗内跑：

    python3 tests/session-recovery-e2e.py --force

流程（默认 3 轮）：
  1. 应用以 --automation 运行，桥可达；
  2. 开 3 个自有测试标签（example.com），等 20s（15s 周期快照 + 余量）；
  3. `pkill -9` → 重新 `open` 同一份 bundle（保留 --automation）；
  4. 10s 内断言：桥可达、`/state` 的 tabs ≥ 1、`/diag/startup` 的
     `abnormalExit=true`、且测试标签的 URL 仍在（恢复成功）；
  5. 收尾：关闭测试标签，保留用户标签。

它只创建/关闭自己的标签；强杀本身会让用户标签经历一次"崩溃恢复"，请提前告知。
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_guard import guard_single_dev_instance

BASE = os.environ.get("DESIRE_BASE", "http://127.0.0.1:8799")
TEST_URLS = [f"https://example.com/?desire-session-test={i}" for i in range(3)]


def call(path, payload=None, timeout=15):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response)


def wait_bridge(seconds=10):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            return call("/state", timeout=3)
        except Exception:
            time.sleep(0.5)
    return None


def app_bundle_path():
    pid = subprocess.run(["pgrep", "-x", "Desire"], capture_output=True, text=True).stdout.strip().split("\n")[0]
    if not pid:
        return None
    command = subprocess.run(["ps", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
    # .../Desire.app/Contents/MacOS/Desire
    marker = ".app/Contents/MacOS/"
    index = command.find(marker)
    if index < 0:
        return None
    return command[:index + len(".app")]


def test_tab_urls():
    state = call("/state")
    return [t.get("url") for t in state.get("tabs", [])]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true", help="confirm the app may be force-killed")
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    if not args.force:
        print("refusing to kill the app without --force")
        return 2
    if not guard_single_dev_instance():
        return 2
    bundle = app_bundle_path()
    if not bundle:
        print("Desire is not running — launch it with --automation first")
        return 2

    failures = []
    for round_index in range(1, args.rounds + 1):
        print(f"round {round_index}: opening test tabs")
        for url in TEST_URLS:
            call("/new-tab", {"url": url})
        time.sleep(20)  # 15s 周期快照 + 余量
        print(f"round {round_index}: pkill -9")
        subprocess.run(["pkill", "-9", "-x", "Desire"])
        time.sleep(2)
        subprocess.run(["open", bundle, "--args", "--automation"])
        state = wait_bridge(12)
        if state is None:
            failures.append(f"round {round_index}: bridge did not come back")
            continue
        urls = test_tab_urls()
        restored = sum(1 for u in urls if u in TEST_URLS)
        tabs = len(state.get("tabs", []))
        try:
            diag = call("/diag/startup", timeout=5)
        except Exception:
            diag = {}
        print(f"round {round_index}: tabs={tabs} restored_tests={restored} abnormalExit={diag.get('abnormalExit')}")
        if tabs < 1:
            failures.append(f"round {round_index}: no tabs after relaunch")
        if restored < len(TEST_URLS):
            failures.append(f"round {round_index}: only {restored}/{len(TEST_URLS)} test tabs restored")
        if diag.get("abnormalExit") is not True:
            failures.append(f"round {round_index}: abnormalExit flag missing")
        # 清掉本轮测试标签
        for url in TEST_URLS:
            state = call("/state")
            index = next((t.get("index") for t in state.get("tabs", []) if t.get("url") == url), None)
            if index is not None:
                call("/close-tab", {"index": index})

    if failures:
        for line in failures:
            print("FAIL", line)
        print(f"RESULT {args.rounds - len(failures)}/{args.rounds}")
        return 1
    print(f"RESULT {args.rounds}/{args.rounds}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
