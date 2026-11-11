#!/usr/bin/env python3
"""工具目录 3.0 E2E（v0.8.51 批 1）：分组摘要压缩比 + listTools 展开。**只读**。

前置：应用以 --automation 运行（Debug 构建；/diag/* 端点仅 DEBUG）。
用法：python3 tests/tool-catalog-e2e.py
"""
import json
import os
import sys
import urllib.parse
import urllib.request

BASE = os.environ.get("DESIRE_BASE", "http://127.0.0.1:8799")
res = []


def call(path, timeout=15):
    with urllib.request.urlopen(BASE + path, timeout=timeout) as response:
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

    stats = call("/agent/tool-catalog")
    count = stats.get("count", 0)
    ratio = stats.get("ratio", 1)
    groups = stats.get("groups", [])
    check("工具数 ≥ 250", count >= 250, count)
    check("分组摘要压缩比 < 40%", ratio < 0.40, "%.3f" % ratio)
    check("分组数 ≥ 10", len(groups) >= 10, len(groups))
    names = {g.get("group") for g in groups}
    check("组名可读（browse/page/files/media/documents）",
          {"browse", "page", "files", "media", "documents"} <= names, sorted(names))
    check("other 占比 < 15%",
          next((g["count"] for g in groups if g["group"] == "other"), 0) / max(1, count) < 0.15)

    section = call("/diag/tools-section")
    text = section.get("text", "")
    check("提示词 <tools> 用分组索引", "GROUPED index" in text and "listTools" in text)
    check("<tools> 体积 < 4KB", section.get("chars", 9999) < 4000, section.get("chars"))
    tool_lines = [line for line in text.splitlines() if line.startswith("- ")]
    check("<tools> 分组行数 < 25", len(tool_lines) < 25, len(tool_lines))

    q = urllib.parse.quote("read file")
    expanded = call(f"/diag/list-tools?query={q}").get("text", "")
    first = expanded.splitlines()[0] if expanded else ""
    check("query 命中排第一（readFile）", first.startswith("readFile —"), first[:60])
    check("展开带参数签名", "params: path:string" in expanded)

    files = call("/diag/list-tools?group=files").get("text", "")
    check("group=files 展开 readFile", "readFile —" in files and "params:" in files)
    check("group=files 含 writeFile", "writeFile —" in files)

    listing = call("/diag/list-tools").get("text", "")
    check("无参列出所有组", "Tool groups" in listing and "browse (" in listing)

    unknown = call("/diag/list-tools?group=nope").get("text", "")
    check("未知组给出可用组名", unknown.startswith("Unknown group") and "browse" in unknown)

    missing = call("/diag/list-tools?query=zzzznotatool").get("text", "")
    check("无命中不是 Error（成功但为空）", missing.startswith("No tools matched"), missing[:60])

    failed = [item for item in res if not item[1]]
    print("\nRESULT %d/%d" % (len(res) - len(failed), len(res)))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
