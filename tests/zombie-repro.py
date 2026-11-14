#!/usr/bin/env python3
"""主 actor 僵尸复现器（v0.8.58 批 1）。

序列 = 0.8.57 活体复现：重启 dev 实例 → 装评估档案 → E9 场景（41KB 工具结果
大文本回合）→ 纯 HTTP 探活 → E16 场景（send）→ lldb 主 actor 探针判定。

用法：python3 tests/zombie-repro.py [--rounds N] [--keep-on-hit]
判定：lldb 投 Task { @MainActor in NSLog("...") }，3s 后日志无该标记 = 僵尸。
复现时抓 exceptions/ 目录（ExceptionTrap）+ sample 全线程，然后停（--keep-on-hit
保留实例供现场排查）。
"""
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

APP = os.environ.get("ZOMBIE_APP") or os.path.expanduser(
    "~/Library/Developer/Xcode/DerivedData/Desire-ddprtuvezivjpldsjxuxsotbutyu/"
    "Build/Products/Debug/Desire.app")
BRIDGE = "http://127.0.0.1:8799"
FIXTURE_PORT = 8881
MARKER = "ZOMBIE-PROBE-MARKER"


def br(method, path, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BRIDGE + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def log_marker_to_logfile() -> None:
    """lldb 表达式输出的标记走 NSLog → 统一日志；判定读日志计数。"""
    pass


def actor_alive_lldb_unreliable(pid: int) -> bool:
    """lldb 投 @MainActor Task；3s 后日志里有 MARKER = 活。"""
    script = (
        f'expr -l swift -- import Foundation; '
        f'Task {{ @MainActor in Foundation.NSLog("{MARKER}") }}'
    )
    subprocess.run(["lldb", "-b", "-p", str(pid), "-o", script,
                    "-o", "detach", "-o", "quit"],
                   capture_output=True, timeout=60)
    time.sleep(3)
    out = subprocess.run(
        ["/usr/bin/log", "show", "--last", "10s", "--info", "--debug",
         "--predicate", 'process == "Desire"', "--style", "compact"],
        capture_output=True, text=True, timeout=120)
    return MARKER in out.stdout


def relaunch_app() -> int:
    subprocess.run(["pkill", "-9", "-x", "Desire"], capture_output=True)
    time.sleep(2)
    subprocess.run(["defaults", "write", "me.siwi.Desire",
                    "app.launchWindowHealAttempts", "0"], capture_output=True)
    subprocess.run(["open", APP, "--args", "--automation"], capture_output=True)
    for _ in range(35):
        time.sleep(1)
        try:
            state = br("GET", "/state", timeout=5)
            if len(state.get("tabs", [])) >= 1:
                return int(subprocess.run(["pgrep", "-x", "Desire"], capture_output=True,
                                          text=True).stdout.split()[0])
        except Exception:
            pass
    raise RuntimeError("app did not come up with a window in 35s")


def start_fixture() -> subprocess.Popen:
    """抽出 agent-eval 的 FIXTURE_SOURCE 起在 8881。"""
    src = open("tests/agent-eval.py").read()
    match = re.search(r"FIXTURE_SOURCE = r'''(.*?)'''", src, re.S)
    workdir = pathlib.Path("/tmp/zombie-repro")  # 脚本/日志可留 /tmp
    workdir.mkdir(exist_ok=True)
    script = workdir / "fixture.py"
    script.write_text(match.group(1))
    # fixture 文件必须放 **Agent 工作区**（readFile 免审批；/tmp 会被拒读——
    # 七条硬约束之一）。
    workspace = pathlib.Path(os.environ.get(
        "ZOMBIE_WORKSPACE",
        os.path.expanduser("~/Documents/DesireAgent/zombie-repro")))
    workspace.mkdir(parents=True, exist_ok=True)
    big = workspace / "big.txt"
    big.write_text("这是一段很长的纯文本。" * 1200)  # 与 big_plain 同款 ~41KB
    env = dict(os.environ, EVAL_PORT=str(FIXTURE_PORT), EVAL_BIG_PATH=str(big),
               EVAL_SECRET_PATH=str(workspace / "secret.txt"),
               EVAL_SECRET2_PATH=str(workspace / "secret2.txt"),
               EVAL_MISSING_PATH=str(workspace / "missing.txt"))
    for p in ("secret.txt", "secret2.txt"):
        (workspace / p).write_text("gateway-token: abc123\naws: AKIAIOSFODNN7EXAMPLE\n")
    proc = subprocess.Popen(["python3", str(script)], env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.5)
    return proc


def install_profile():
    created = br("POST", "/ai/profiles", body={
        "name": "zombie-repro",
        "endpoint": f"http://127.0.0.1:{FIXTURE_PORT}/v1/chat/completions",
        "model": "fake-1", "key": "zombie-key-1234567890"})
    br("POST", "/ai/profiles/activate", body={"id": created["id"]})
    # 预算关断（MUSCLE17 残留会吞回合——0.8.57 教训）
    budget = (br("GET", "/agent/budget") or {}).get("budget", 0)
    if budget:
        br("POST", "/agent/budget", body={"tokens": 0})
    return created["id"], budget


def restore_profile(profile_id, budget):
    try:
        profiles = br("GET", "/ai/profiles")
        if profiles.get("active") == profile_id:
            # 恢复到档案列表里第一个非 eval 档案
            for p in profiles.get("profiles", []):
                if p.get("id") != profile_id:
                    br("POST", "/ai/profiles/activate", body={"id": p["id"]})
                    break
        br("POST", "/ai/profiles/delete", body={"id": profile_id})
        if budget:
            br("POST", "/agent/budget", body={"tokens": budget})
    except Exception as exc:
        print(f"⚠️ 恢复失败（请手工检查）：{exc}")


def run_round(round_no: int) -> bool:
    """跑一轮序列。返回 True = 僵尸复现。"""
    pid = relaunch_app()
    print(f"  round {round_no}: pid={pid}")
    profile_id, budget = install_profile()
    try:
        # E9 场景：41KB 工具结果
        br("POST", "/agent/new", body={})
        br("POST", "/agent/send", body={"text": "EVAL-BIG 请读取并确认大文件内容"})
        e9_ok = False
        deadline = time.time() + 90
        while time.time() < deadline:
            msgs = br("GET", "/agent/messages").get("messages", [])
            # E9DONE-* 任意形态都算完成（full/partial 取决于 fixture 分支推进，
            # 与僵尸判定无关——僵尸看的是 E16 send 之后主 actor 还活不活）。
            if any(m.get("role") == "assistant" and "E9DONE-" in str(m.get("content"))
                   for m in msgs):
                e9_ok = True
                break
            time.sleep(1)
        print(f"    E9: {'done' if e9_ok else 'TIMEOUT'}")
        if not e9_ok:
            print(f"    E9 未完成（未到 E16 挂点，本轮不算）")
            return False
        # E16 场景：send 后行为级判定（lldb 求值上下文的 Task 是伪信号——
        # 健康实例同样 enqueued 不执行；改看"回合有没有真的跑"）。
        before = {m.get("id") for m in br("GET", "/agent/messages").get("messages", [])}
        br("POST", "/agent/send", body={"text": "EVAL-IMGTOOLTEST 合并两张不存在的图"})
        replied = False
        deadline = time.time() + 45
        while time.time() < deadline:
            msgs = br("GET", "/agent/messages").get("messages", [])
            fresh = [m for m in msgs if m.get("id") not in before
                     and m.get("role") == "assistant" and (m.get("content") or "")]
            if fresh and not br("GET", "/agent/messages").get("busy"):
                replied = True
                break
            time.sleep(2)
        print(f"    E16 replied: {replied}")
        if replied:
            return False
        return True
    finally:
        restore_profile(profile_id, budget)


def capture_evidence(round_no: int, pid: int) -> None:
    out_dir = pathlib.Path(f"/tmp/zombie-repro/hit-{round_no}")
    out_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run(["sample", str(pid), "3", "-file", str(out_dir / "sample.txt")],
                   capture_output=True, timeout=60)
    exc_dir = pathlib.Path.home() / "Library/Application Support/Desire/exceptions"
    if exc_dir.exists():
        for f in exc_dir.glob("*.log"):
            shutil.copy(f, out_dir / f.name)
    print(f"    evidence → {out_dir}")


def main():
    rounds = int(sys.argv[sys.argv.index("--rounds") + 1]) if "--rounds" in sys.argv else 6
    keep = "--keep-on-hit" in sys.argv
    fixture = start_fixture()
    hit = False
    try:
        for i in range(1, rounds + 1):
            try:
                if run_round(i):
                    print(f"\n🧟 ZOMBIE REPRODUCED on round {i}")
                    pid = int(subprocess.run(["pgrep", "-x", "Desire"], capture_output=True,
                                             text=True).stdout.split()[0])
                    capture_evidence(i, pid)
                    hit = True
                    break
            except Exception as exc:
                print(f"  round {i}: infra error — {exc}")
        if not hit:
            print(f"\n{rounds} rounds, no zombie — 序列未复现（概率性；换分块时序再试）")
    finally:
        fixture.send_signal(signal.SIGTERM)
        if hit and not keep:
            subprocess.run(["pkill", "-9", "-x", "Desire"], capture_output=True)
    sys.exit(1 if hit else 0)


if __name__ == "__main__":
    main()
