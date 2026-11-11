#!/usr/bin/env python3
"""工具执行策略 E2E（v0.8.51 批 3）：超时竞速 + 工具统计端点。**只读**。

前置：应用以 --automation 运行（Debug 构建；/diag/* 仅 DEBUG）。
用法：python3 tests/tool-policy-e2e.py
"""
import json
import os
import sys
import urllib.request

BASE = os.environ.get("DESIRE_BASE", "http://127.0.0.1:8799")
res = []


def call(path, payload=None, timeout=30):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response)


def check(name, ok, detail=""):
    res.append((name, bool(ok)))
    print(("PASS " if ok else "FAIL ") + name + (" — " + str(detail) if detail else ""))


def main():
    try:
        call("/state", timeout=5)
    except Exception as exc:
        print("app is not running with --automation:", exc)
        return 2

    # 超时竞速：工作慢于超时 → 超时结果，且**不等**工作跑完
    r = call("/diag/tool-timeout-probe", {"seconds": 1, "workSeconds": 3})
    check("超时触发", r.get("result", "").startswith("Error: timed out after 1s"), r.get("result"))
    check("超时不等工作完成", r.get("elapsed", 99) < 2.0, r.get("elapsed"))

    # 工作快于超时 → 正常结果
    r = call("/diag/tool-timeout-probe", {"seconds": 3, "workSeconds": 0.2})
    check("未超时正常返回", r.get("result") == "done", r.get("result"))
    check("未超时耗时接近工作用时", r.get("elapsed", 99) < 1.5, r.get("elapsed"))

    # 工具统计端点：与统计页同源（ToolUsageStats）
    stats = call("/agent/tool-stats")
    totals = stats.get("totals", {})
    check("统计端点含 totals", all(k in totals for k in ("tools", "calls", "failures")), totals)
    tools = stats.get("tools", [])
    check("统计条目字段齐全",
          all(all(k in t for k in ("tool", "calls", "failures", "failureRate", "averageMs"))
              for t in tools), tools[:2])
    check("调用数按降序", all(tools[i]["calls"] >= tools[i + 1]["calls"]
                            for i in range(len(tools) - 1)))
    windowed = call("/agent/tool-stats?sinceDays=7")
    check("sinceDays 过滤后调用数不增",
          windowed.get("totals", {}).get("calls", 0) <= totals.get("calls", 0),
          (windowed.get("totals", {}).get("calls"), totals.get("calls")))

    failed = [item for item in res if not item[1]]
    print("\nRESULT %d/%d" % (len(res) - len(failed), len(res)))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
