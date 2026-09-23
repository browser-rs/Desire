#!/usr/bin/env python3
"""Agent 评估脚本：固定 prompt 集 → 假端点 → 断言轨迹与消息（优化清单 P1-⑤）。

把"发一条消息 → 肉眼看回复"的产品化：全部用例**确定性**（假端点，不需要真模型），
断言打在桥端点（/agent/messages、/agent/trace）上，覆盖：

  E1 plain-echo       系统提示契约：system 只有一条且在开头（sysCount=1、sysAt=[0]）
  E2 fail-convention  工具失败 → 结果以 Error: 开头、模型所见一致、轨迹 threwError、机械核验触发
  E3 redaction        读凭据文件 → 工具结果与模型所见都是 [redacted]，原文不出现在对话里
  E4 overflow-retry   首次请求报 context length → 应用自动减半预算重试并完成回合

用法：
  前置：应用以 --automation 启动、桥可达（默认 http://127.0.0.1:8799）。
  运行：python3 tests/agent-eval.py [--base URL] [--cleanup] [--keep-fixture]
    --cleanup  结束时删除评估写入的会话（按脚本记录的精确 id）。默认保留。
    --keep-fixture 结束后不删除临时模型档案（默认删除并恢复原档案）。

退出码：全部通过 = 0；任何失败 = 1。
"""

import argparse
import json
import pathlib
import subprocess
import sys
import time
import urllib.request

BRIDGE = "http://127.0.0.1:8799"
FIXTURE_SCRIPT = "/tmp/desire-fixture/fake_openai.py"
FIXTURE_PORT = 8880
FIXTURE_ENDPOINT = f"http://127.0.0.1:{FIXTURE_PORT}/v1/chat/completions"
POLL_TIMEOUT = 90


def bridge(method, path, body=None):
    req = urllib.request.Request(BRIDGE + path, method=method)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, data=data, timeout=15) as resp:
        return json.loads(resp.read().decode())


def fixture_bridge(method, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{FIXTURE_PORT}{path}", timeout=10) as resp:
        return resp.read().decode()


# ---------- 假端点与档案管理 ----------

fixture_proc = None


def start_fixture():
    global fixture_proc
    fixture_proc = subprocess.Popen(
        [sys.executable, FIXTURE_SCRIPT],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 10
    while time.time() < deadline:
        try:
            fixture_bridge("GET", "/reset")
            return
        except Exception:
            time.sleep(0.3)
    raise RuntimeError("fixture endpoint did not come up on port 8880")


def stop_fixture():
    if fixture_proc:
        fixture_proc.terminate()


previous_active = None
eval_profile_id = None


def install_profile():
    global previous_active, eval_profile_id
    profiles = bridge("GET", "/ai/profiles")
    previous_active = profiles.get("active")
    created = bridge("POST", "/ai/profiles", body={
        "name": "eval-fixture",
        "endpoint": FIXTURE_ENDPOINT,
        "model": "fake-1",
        "key": "eval-key-1234567890",
    })
    eval_profile_id = created["id"]
    bridge("POST", "/ai/profiles/activate", body={"id": eval_profile_id})


def restore_profile():
    try:
        if previous_active:
            bridge("POST", "/ai/profiles/activate", body={"id": previous_active})
        if eval_profile_id:
            bridge("POST", "/ai/profiles/delete", body={"id": eval_profile_id})
    except Exception as exc:
        print(f"⚠️ 恢复档案失败（请手工检查）：{exc}")


# ---------- 轮次驱动与断言 ----------

eval_conversations = []


def run_case(prompt):
    """发一条消息并等回合结束。返回 (messages, last_turn)。"""
    before = len(bridge("GET", "/agent/messages").get("messages", []))
    bridge("POST", "/agent/send", body={"text": prompt})
    deadline = time.time() + POLL_TIMEOUT
    while time.time() < deadline:
        state = bridge("GET", "/agent/messages")
        msgs = state.get("messages", [])
        # 本地假端点的回合可能快于轮询间隔（busy 从未被观察到也算完成）：
        # 判据 = 出现了新消息且不再忙碌；复核一次防抖。
        if len(msgs) > before and not state.get("busy"):
            time.sleep(0.5)
            state = bridge("GET", "/agent/messages")
            msgs = state.get("messages", [])
            if len(msgs) > before and not state.get("busy"):
                trace = bridge("GET", "/agent/trace")
                eval_conversations.append(trace["conversation"])
                return msgs
        time.sleep(0.5)
    raise TimeoutError(f"回合超时未完成：{prompt}")


def last_exchange(msgs):
    """最后一个回合的 (user, assistant, tool 消息列表)。"""
    tail = list(reversed(msgs))
    assistant = next(m for m in tail if m["role"] == "assistant")
    tools = [m for m in msgs if m["role"] == "tool"]
    user = next(m for m in reversed(msgs) if m["role"] == "user")
    return user, assistant, tools


# ---------- 用例 ----------

def case_plain_echo():
    msgs = run_case("EVAL-PLAIN 请用一句话回应")
    _, assistant, _ = last_exchange(msgs)
    text = assistant.get("content") or ""
    check("E1 system 只有一条且在开头", "sysCount=1" in text and "sysAt=[0]" in text)


def case_fail_convention():
    msgs = run_case("EVAL-TOOLSECRET 读取 /tmp/desire-fixture/does-not-exist.txt")
    _, assistant, tools = last_exchange(msgs)
    turn = json.loads(bridge("GET", "/agent/trace")["jsonl"].split("\n")[-1])
    step = (turn.get("steps") or [{}])[0]
    check("E2 工具被调用", step.get("action") == "readFile")
    check("E2 工具结果以 Error: 开头", (step.get("result") or "").startswith("Error:"))
    check("E2 轨迹标记 threwError", step.get("threwError") is True)
    seen = assistant.get("content") or ""
    check("E2 模型看到的也是失败（Error:）", seen.startswith("MODEL-SAW>>>Error:"))
    check("E2 机械核验触发（全部失败 → 提示）", bool(assistant.get("verificationNote")))


def case_redaction():
    msgs = run_case("EVAL-READSECRET 读取凭据文件")
    _, assistant, tools = last_exchange(msgs)
    tool_text = "\n".join(m.get("content") or "" for m in tools)
    check("E3 工具结果无原始密钥", "sk-abcdefghijklmnopqrstuvwx1234" not in tool_text)
    check("E3 工具结果有掩码", "[redacted]" in tool_text)
    seen = assistant.get("content") or ""
    check("E3 模型所见无原始密钥", "sk-abcdefghijklmnopqrstuvwx1234" not in seen)
    check("E3 模型所见有掩码", "[redacted]" in seen)


def case_overflow_retry():
    fixture_bridge("GET", "/reset")   # 清计数：保证本用例确定性地先收到一次超限错误
    msgs = run_case("EVAL-OVERFLOWTEST 请简短回答")
    _, assistant, _ = last_exchange(msgs)
    text = assistant.get("content") or ""
    check("E4 超限后自动重试并完成回合", text.startswith("auth="))
    check("E4 未把超限当失败丢弃", "⚠️" not in text)


# ---------- 主流程 ----------

CASES = [("E1 plain-echo", case_plain_echo),
         ("E2 fail-convention", case_fail_convention),
         ("E3 redaction", case_redaction),
         ("E4 overflow-retry", case_overflow_retry)]

results = []


def check(name, condition):
    results.append((name, bool(condition), "" if condition else "断言不成立"))


def main():
    global BRIDGE
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default=BRIDGE)
    parser.add_argument("--cleanup", action="store_true",
                        help="删除评估写入的会话（按脚本记录的精确 id）")
    parser.add_argument("--keep-fixture", action="store_true")
    args, _ = parser.parse_known_args()
    BRIDGE = args.base

    bridge("GET", "/state")   # 桥健康检查；不可达会直接抛错
    start_fixture()
    install_profile()
    try:
        for name, case in CASES:
            try:
                case()
                results.append((name, True, ""))
                print(f"✓ {name}")
            except Exception as exc:
                results.append((name, False, str(exc)))
                print(f"✗ {name}: {exc}")
    finally:
        restore_profile()
        stop_fixture()
        if args.cleanup and eval_conversations:
            ids = sorted(set(eval_conversations))
            bridge("POST", "/conversations/delete", body={"ids": ids})
            print(f"已删除评估会话：{len(ids)} 个")

    print(f"\n评估结果：{sum(1 for _, ok, _ in results if ok)}/{len(results)} 通过")
    if any(not ok for _, ok, _ in results):
        sys.exit(1)


if __name__ == "__main__":
    main()
