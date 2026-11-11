#!/usr/bin/env python3
"""工具链 E2E（v0.8.51 批 2）：顺序执行、失败语义、嵌套守卫、后台 Jobs。

前置：应用以 --automation 运行（Debug 构建；/diag/tool-chain 仅 DEBUG）。
全部步骤只读（listTools / getPageTitle），不碰用户数据。
用法：python3 tests/tool-chain-e2e.py
"""
import json
import os
import sys
import time
import urllib.request

BASE = os.environ.get("DESIRE_BASE", "http://127.0.0.1:8799")
res = []


def call(path, payload=None, timeout=60):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json"}) if data else None
    if req is None:
        req = BASE + path
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response)


def chain(steps, on_error=None, background=None, timeout=60):
    payload = {"steps": steps}
    if on_error:
        payload["onError"] = on_error
    if background is not None:
        payload["background"] = background
    return call("/diag/tool-chain", payload, timeout=timeout)


def check(name, ok, detail=""):
    res.append((name, bool(ok)))
    print(("PASS " if ok else "FAIL ") + name + (" — " + str(detail) if detail else ""))


def main():
    try:
        call("/state", timeout=5)
    except Exception as exc:
        print("app is not running with --automation:", exc)
        return 2

    # 1) 顺序执行（只读三件）
    r = chain([
        {"tool": "listTools", "args": {"query": "read file"}},
        {"tool": "getPageTitle"},
        {"tool": "listTools", "args": {"group": "sync"}},
    ])
    text = r.get("text", "")
    check("三步链完成", "[1] listTools ✓" in text and "[2] getPageTitle ✓" in text
          and "[3] listTools ✓" in text, text[:200])
    check("三步链汇总", "3 succeeded" in text)
    check("成功链不以 Error 开头", not text.startswith("Error:"))
    check("顺序摘要带耗时", "✓ 0." in text)

    # 2) 失败 + stop：在失败步停下，整体 Error:
    r = chain([{"tool": "notARealTool"}, {"tool": "listTools", "args": {"group": "sync"}}],
              on_error="stop")
    text = r.get("text", "")
    check("stop 链整体 Error", text.startswith("Error: chain stopped"), text[:80])
    check("stop 链停在第一步", "[1] notARealTool ✗" in text and "[2] listTools" not in text)
    check("stop 链汇总", "stopped at step 1" in text)

    # 3) 失败 + continue：继续跑完，整体不是 Error:
    r = chain([{"tool": "notARealTool"}, {"tool": "listTools", "args": {"group": "sync"}}],
              on_error="continue")
    text = r.get("text", "")
    check("continue 链继续执行", "[2] listTools ✓" in text, text[:200])
    check("continue 链汇总", "1 succeeded, 1 failed (continued)" in text)
    check("continue 链不以 Error 开头", not text.startswith("Error:"))

    # 4) 嵌套守卫
    r = chain([{"tool": "runToolChain", "args": {"steps": []}}])
    text = r.get("text", "")
    check("嵌套链被拒", "nested" in text and text.startswith("Error:"), text[:120])

    # 5) 非法参数
    r = chain("nope")
    check("steps 非数组报错", r.get("text", "").startswith("Error: steps required"), r.get("text", "")[:80])

    # 6) 后台链 → Jobs
    r = chain([{"tool": "listTools", "args": {"group": "sync"}}], background=True)
    text = r.get("text", "")
    check("后台链返回 job id", "started as job" in text, text[:120])
    deadline = time.time() + 60
    done = None
    while time.time() < deadline:
        jobs = call("/jobs", timeout=15).get("jobs", [])
        candidates = [j for j in jobs if j.get("source") == "toolChain"]
        done = next((j for j in candidates if j.get("state") == "done"), None)
        if done:
            break
        time.sleep(1)
    check("后台链进 Jobs 且完成", done is not None,
          [(j.get("source"), j.get("state")) for j in call("/jobs").get("jobs", [])[:5]])

    failed = [item for item in res if not item[1]]
    print("\nRESULT %d/%d" % (len(res) - len(failed), len(res)))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
