#!/usr/bin/env python3
"""双设备同步冲突 E2E（v0.8.83 批 3）。

用两个独立 data-dir 的 Desire 实例（同一台机器、顺序启动）模拟两台设备：
A 建两条书签 → B 拉取后改标题 → A 再推（LWW 输掉）→ 冲突卡出现 →
一条“采用本地”、一条“采用远端” → A 重推 / B 再拉，两端收敛；最后检查
冲突审计记录。

依赖：本机 MySQL/Redis + 本地 API（默认 http://127.0.0.1:18090）。
无 API / 无 DB 时明确 SKIP（退出码 0，不假绿）。

用法：
  python3 tests/sync-conflict-e2e.py [--server URL] [--keep]

注意：脚本会启动/退出开发实例（只按 DerivedData 路径匹配，不碰安装版）；
用户正在用机器时不要跑。测试账号在本地开发库，唯一用户名避免冲突。
"""

import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
BRIDGE = "http://127.0.0.1:8799"
DEFAULT_SERVER = "http://127.0.0.1:18090"


def http(method, url, body=None, timeout=30):
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode()
    return json.loads(raw) if raw else {}


def bridge(method, path, body=None, timeout=60):
    return http(method, BRIDGE + path, body, timeout=timeout)


def wait_bridge(data_dir, timeout=40):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            state = bridge("GET", "/state", timeout=2)
            startup = state.get("startup") or {}
            if startup.get("dataDir") == data_dir:
                return state
        except Exception:
            pass
        time.sleep(0.4)
    raise RuntimeError(f"bridge did not come up for {data_dir}")


def launch(data_dir):
    subprocess.run([str(ROOT / "tools/launch-hermetic.sh"), data_dir, "--activate"],
                   check=True, stdout=subprocess.DEVNULL)
    return wait_bridge(data_dir)


def quit_app():
    try:
        bridge("POST", "/app/quit", {}, timeout=5)
    except Exception:
        pass
    deadline = time.time() + 15
    while time.time() < deadline:
        try:
            bridge("GET", "/state", timeout=1)
        except Exception:
            return
        time.sleep(0.3)
    raise RuntimeError("app did not quit")


def wait_condition(label, fn, timeout=20, interval=0.5):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = fn()
        if last:
            return last
        time.sleep(interval)
    raise AssertionError(f"{label} timed out (last={last!r})")


def sync_now(label):
    """显式同步两轮：第一轮可能被自动同步挡回（guard 返回时并不报错），
    等它落地后再推一次，确保本轮本地改动已经上送。"""
    status = {}
    for attempt in range(2):
        deadline = time.time() + 60
        while time.time() < deadline:
            result = bridge("POST", "/sync/now", {})
            if not result.get("error"):
                break
            time.sleep(0.8)
        else:
            raise AssertionError(f"{label}: /sync/now did not start")
        while time.time() < deadline:
            status = bridge("GET", "/sync/status")
            if not status.get("syncing"):
                break
            time.sleep(0.5)
        if attempt == 0:
            time.sleep(1.0)
    return status


def bookmark_tree():
    return bridge("GET", "/bookmarks?tree=1").get("tree") or []


def flatten(nodes):
    out = []
    for node in nodes:
        out.append(node)
        out.extend(flatten(node.get("children") or []))
    return out


def bookmark_by_url(url):
    return next((b for b in flatten(bookmark_tree()) if b.get("url") == url), None)


def bookmark_title(url):
    node = bookmark_by_url(url)
    return (node or {}).get("title")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", default=DEFAULT_SERVER)
    parser.add_argument("--keep", action="store_true", help="keep data dirs for debugging")
    args = parser.parse_args()

    try:
        health = http("GET", args.server + "/health", timeout=3)
        if not (health.get("data") or {}).get("db"):
            print(f"SKIP: sync API has no DB at {args.server}")
            return 0
    except Exception as exc:
        print(f"SKIP: sync API unavailable at {args.server} ({exc})")
        return 0

    tag = uuid.uuid4().hex[:8]
    username = f"SyncE2E{tag}"
    password = f"SyncE2E{tag}9"
    dir_a = tempfile.mkdtemp(prefix="desire-sync-a-")
    dir_b = tempfile.mkdtemp(prefix="desire-sync-b-")
    url_a = f"https://sync-e2e.example/{tag}/a"
    url_b = f"https://sync-e2e.example/{tag}/b"
    checks = []

    def check(name, condition, detail=""):
        checks.append((name, bool(condition)))
        print(("✓ " if condition else "✗ ") + name + (f"  {detail}" if detail and not condition else ""))

    try:
        # ---------- 设备 A：建两条书签并同步 ----------
        launch(dir_a)
        # 同一份隔离偏好会被历史运行留下冲突/审计记录——先清干净，
        # 否则本次的条数断言会把上一轮的记录算进来。
        bridge("POST", "/sync/conflicts/clear", {})
        bridge("POST", "/sync/conflicts/audit/clear", {})
        bridge("POST", "/sync/server", {"baseURL": args.server})
        registered = bridge("POST", "/sync/register",
                            {"username": username, "password": password}, timeout=90)
        check("A 注册成功", not registered.get("error")
              and registered.get("auth") == username, str(registered))
        if registered.get("error"):
            return 1
        bridge("POST", "/sync/domain", {"domain": "bookmarks", "enabled": True})
        bridge("POST", "/bookmarks/add", {"title": "Sync A1", "url": url_a})
        bridge("POST", "/bookmarks/add", {"title": "Sync A2", "url": url_b})
        first_sync = sync_now("A initial")
        check("A 首轮同步无错误", not first_sync.get("lastError"), str(first_sync.get("lastError") or ""))
        bridge("POST", "/sync/cursors/reset", {})
        quit_app()

        # ---------- 设备 B：拉取后改标题并推 ----------
        launch(dir_b)
        bridge("POST", "/sync/server", {"baseURL": args.server})
        logged_in = bridge("POST", "/sync/login",
                           {"username": username, "password": password}, timeout=90)
        check("B 登录成功", not logged_in.get("error")
              and logged_in.get("auth") == username, str(logged_in))
        if logged_in.get("error"):
            return 1
        bridge("POST", "/sync/domain", {"domain": "bookmarks", "enabled": True})
        sync_now("B pull")
        try:
            wait_condition("B 收到 A 的书签",
                           lambda: bookmark_title(url_a) == "Sync A1"
                           and bookmark_title(url_b) == "Sync A2")
        except AssertionError:
            print("[debug] B sync status:", bridge("GET", "/sync/status"))
            print("[debug] B bookmarks:", [b.get("title") for b in flatten(bookmark_tree())])
            raise
        check("B 拉到 A 的书签", True)

        for url, title in ((url_a, "Sync B1"), (url_b, "Sync B2")):
            node = bookmark_by_url(url)
            bridge("POST", "/bookmarks/update", {"id": node["id"], "title": title})
        pushed = sync_now("B push")
        check("B 推送无错误", not pushed.get("lastError"), str(pushed.get("lastError") or ""))
        # 同一份隔离偏好被两个实例继承：清游标让 A 启动时从头对账（推本地旧版）。
        bridge("POST", "/sync/cursors/reset", {})
        quit_app()

        # ---------- A 再推：输掉 LWW，出现两条冲突 ----------
        launch(dir_a)
        # 封闭实例的密钥异步就绪，"启动首轮全脏"可能没跑到；显式补脏标记，
        # 模拟离线设备带着旧内容上线（这是冲突产生的前提）。
        bridge("POST", "/sync/dirty/mark-all", {})
        sync_now("A conflict")
        def bookmark_conflicts():
            return [c for c in bridge("GET", "/sync/conflicts").get("conflicts") or []
                    if c.get("domain") == "bookmarks"]

        conflicts = wait_condition(
            "A 冲突卡出现",
            lambda: bookmark_conflicts() if len(bookmark_conflicts()) >= 2 else None,
            timeout=25)
        check("A 出现两条书签冲突", len(conflicts) == 2, str(conflicts))
        check("冲突记录带本地快照",
              all(c.get("hasLocal") for c in conflicts), str(conflicts))
        labels = sorted(c.get("label") or "" for c in conflicts)
        check("冲突标签可读",
              len(labels) == 2 and "Sync B1" in labels[0] and "Sync B2" in labels[1],
              str(labels))

        note_local = next(c for c in conflicts if "Sync B1" in (c.get("label") or ""))
        note_remote = next(c for c in conflicts if "Sync B2" in (c.get("label") or ""))

        # 手机走 remote 帧（与 iPhone 同步健康页同一处理函数），不是桥的直连动作。
        bad = bridge("POST", "/remote/dispatch", {"json": json.dumps(
            {"t": "syncConflict", "id": "not-a-uuid", "flag": True})})
        check("Remote 非法 id 不改变冲突", len(bookmark_conflicts()) == 2, str(bad))

        resolved = bridge("POST", "/remote/dispatch", {"json": json.dumps(
            {"t": "syncConflict", "id": note_local["id"], "flag": True})})
        frames = resolved.get("frames") or []
        check("Remote 采用本地被接受", resolved.get("ok") is True
              and any(f.get("t") == "syncHealth" for f in frames), str(resolved))
        resolved = bridge("POST", "/remote/dispatch", {"json": json.dumps(
            {"t": "syncConflict", "id": note_remote["id"], "flag": False})})
        frames = resolved.get("frames") or []
        check("Remote 采用远端被接受", resolved.get("ok") is True
              and any(f.get("t") == "syncHealth" for f in frames), str(resolved))

        wait_condition("A 采用本地后标题恢复",
                       lambda: bookmark_title(url_a) == "Sync A1")
        check("A 采用本地恢复原内容", bookmark_title(url_a) == "Sync A1")
        check("A 采用远端保留服务端内容", bookmark_title(url_b) == "Sync B2")
        audit = bridge("GET", "/sync/conflicts/audit")
        entries = audit.get("audit") or []
        check("审计记录两条", len(entries) == 2, str(entries))
        check("审计含本地/远端与结果",
              {(e.get("resolution"), e.get("result")) for e in entries}
              == {("local", "applied"), ("remote", "kept-remote")}, str(entries))
        sync_now("A resolve push")
        # 游标在共享隔离偏好里：清掉让 B 启动后从头拉取（否则继承 A 的游标会漏）。
        bridge("POST", "/sync/cursors/reset", {})
        quit_app()

        # ---------- B 再拉：两端收敛 ----------
        launch(dir_b)
        sync_now("B converge")
        wait_condition("B 收敛到 A",
                       lambda: bookmark_title(url_a) == "Sync A1"
                       and bookmark_title(url_b) == "Sync B2")
        check("B 拉取后采用本地的条目已更新", bookmark_title(url_a) == "Sync A1")
        check("B 采用远端的条目保持不变", bookmark_title(url_b) == "Sync B2")
    finally:
        try:
            quit_app()
        except Exception:
            pass
        if not args.keep:
            shutil.rmtree(dir_a, ignore_errors=True)
            shutil.rmtree(dir_b, ignore_errors=True)
        else:
            print(f"kept data dirs: {dir_a} {dir_b}")

    failed = [name for name, ok in checks if not ok]
    print(f"\n同步冲突 E2E：{len(checks) - len(failed)}/{len(checks)} 通过")
    for name in failed:
        print("  ✗", name)
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
