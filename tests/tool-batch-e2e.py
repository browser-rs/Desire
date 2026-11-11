#!/usr/bin/env python3
"""批量纯工具 E2E（v0.8.51 批 4）：正则替换 / 哈希 / 编码转换走 Jobs。

fixture 全部在 /tmp 自建自清，不碰用户文件。前置：应用以 --automation 运行。
用法：python3 tests/tool-batch-e2e.py
"""
import hashlib
import json
import os
import shutil
import sys
import tempfile
import time
import urllib.request

BASE = os.environ.get("DESIRE_BASE", "http://127.0.0.1:8799")
res = []


def call(path, payload=None, timeout=60):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response)


def check(name, ok, detail=""):
    res.append((name, bool(ok)))
    print(("PASS " if ok else "FAIL ") + name + (" — " + str(detail) if detail else ""))


def wait(**kwargs):
    deadline = time.time() + 90
    while time.time() < deadline:
        state = call("/tools/batch")
        if not state.get("running"):
            return state
        time.sleep(0.3)
    return call("/tools/batch")


def main():
    try:
        call("/state", timeout=5)
    except Exception as exc:
        print("app is not running with --automation:", exc)
        return 2

    root = tempfile.mkdtemp(prefix="desire-batch-e2e-")
    try:
        a = os.path.join(root, "a.txt")
        b = os.path.join(root, "b.txt")
        with open(a, "w", encoding="utf-8") as fh:
            fh.write("hello foo world foo")
        with open(b, "w", encoding="utf-8") as fh:
            fh.write("hello")

        # 1) 正则替换
        started = call("/tools/batch", {"action": "regexReplace", "paths": [a],
                                        "pattern": "foo", "template": "bar"})
        check("正则：返回 job id", bool(started.get("jobID")), started)
        state = wait()
        check("正则：完成", not state.get("running") and state.get("results"))
        with open(a, encoding="utf-8") as fh:
            check("正则：源文件未改", fh.read() == "hello foo world foo")
        out = os.path.join(root, "a.batch.txt")
        check("正则：输出文件存在", os.path.exists(out), out)
        if os.path.exists(out):
            with open(out, encoding="utf-8") as fh:
                check("正则：输出内容", fh.read() == "hello bar world bar")
        summary = state.get("summary", "")
        check("正则：回执带文件名", "a.txt" in summary, summary[:120])

        # 2) 哈希（已知值）
        started = call("/tools/batch", {"action": "hash", "paths": [b],
                                        "algorithm": "sha256"})
        check("哈希：返回 job id", bool(started.get("jobID")), started)
        state = wait()
        digest = (state.get("results") or [{}])[0].get("value", "")
        expected = hashlib.sha256(b"hello").hexdigest()
        check("哈希：sha256 正确", digest == expected, digest)
        check("哈希：不写文件", not (state.get("results") or [{}])[0].get("output"))

        # 3) 编码转换 utf-8 → utf-16
        started = call("/tools/batch", {"action": "encoding", "paths": [b],
                                        "fromEncoding": "utf-8", "toEncoding": "utf-16"})
        check("编码：返回 job id", bool(started.get("jobID")), started)
        state = wait()
        out16 = os.path.join(root, "b.utf-16.txt")
        check("编码：输出文件存在", os.path.exists(out16), out16)
        if os.path.exists(out16):
            with open(out16, "rb") as fh:
                check("编码：UTF-16 内容", fh.read().decode("utf-16") == "hello")

        # 4) 目录展开（非递归）
        started = call("/tools/batch", {"action": "hash", "paths": [root],
                                        "algorithm": "md5"})
        state = wait()
        files = [item.get("file") for item in state.get("results", [])]
        check("目录：展开 4 个文件（a/b + 两个输出）", len(files) == 4, files)

        # 5) 参数校验
        bad = call("/tools/batch", {"action": "regexReplace", "paths": [a]})
        check("校验：缺 pattern 报错", "pattern" in bad.get("error", "").lower(), bad)
        bad = call("/tools/batch", {"action": "hash", "paths": ["/tmp/does-not-exist-xyz"]})
        check("校验：无文件报错", bool(bad.get("error")), bad)

        # 6) 取消端点（空闲时为幂等成功）
        cancel = call("/tools/batch/cancel", {})
        check("取消：端点可用", cancel.get("ok") is True, cancel)
    finally:
        shutil.rmtree(root, ignore_errors=True)

    failed = [item for item in res if not item[1]]
    print("\nRESULT %d/%d" % (len(res) - len(failed), len(res)))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
