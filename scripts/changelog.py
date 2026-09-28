#!/usr/bin/env python3
"""CHANGELOG 唯一合法的写入工具（2026-09-29 立）。

背景：[Unreleased] 的条目追加曾三次出事故——全部同一机制：用 sed/python
对 `## [Unreleased]` 头做 replace 插条目，条目文本忘带回头/锚点已被上一次
编辑吃掉/条目落错段。后果：吃头、版本假头重复、重建丢条目（险些带残缺
正文发版）。规范（见 AGENTS.md「CHANGELOG 规范」）：

  加条目 **只用本工具**，禁止手工/脚本直接改 `## [Unreleased]` 头。

用法：
  python3 scripts/changelog.py add Fixed <<'EOF'
  - **某修复**：说明……
  EOF
  python3 scripts/changelog.py verify          # 结构校验（release.sh prep 会跑）

行为：
  - `## [Unreleased]` 不存在（刚发过版）→ 自动在文件头新建；
  - `### <Type>` 段不存在 → 在 Unreleased 下新建；存在 → 条目**追加到段尾**；
  - 永不触碰已发布版本段、永不重排整个文件。
"""
import sys
import re
from pathlib import Path

PATH = Path(__file__).resolve().parent.parent / "CHANGELOG.md"
TYPES = ("Added", "Changed", "Fixed", "Deprecated", "Removed", "Security")
UNRELEASED = "## [Unreleased]"


def fail(msg: str) -> None:
    print(f"✗ {msg}")
    sys.exit(1)


def verify() -> None:
    text = PATH.read_text()
    lines = text.split("\n")
    problems = []

    # ① 版本头唯一
    headers = [l for l in lines if re.match(r"^## \[v\d+\.\d+\.\d+\]", l)]
    seen = set()
    for h in headers:
        if h in seen:
            problems.append(f"版本头重复: {h}")
        seen.add(h)

    # ② Unreleased 若存在必须是第一个头，且最多一个
    unreleased_idx = [i for i, l in enumerate(lines) if l.strip() == UNRELEASED]
    if len(unreleased_idx) > 1:
        problems.append(f"{UNRELEASED} 出现 {len(unreleased_idx)} 次")
    first_header = next((i for i, l in enumerate(lines) if l.startswith("## ")), None)
    if unreleased_idx and first_header is not None and unreleased_idx[0] != first_header:
        problems.append(f"{UNRELEASED} 不是第一个版本头（在行 {unreleased_idx[0] + 1}，第一个头在行 {first_header + 1}）")

    # ③ 版本头严格降序（新→旧）：提取 (major, minor, patch) 比较
    versions = []
    for l in headers:
        m = re.match(r"^## \[v(\d+)\.(\d+)\.(\d+)\]", l)
        if m:
            versions.append(tuple(int(x) for x in m.groups()))
    for a, b in zip(versions, versions[1:]):
        if a <= b:
            problems.append(f"版本头顺序错误: {a} 应晚于 {b}")

    # ④ Unreleased 存在时其下必须紧跟类别段或空行（不允许空 Unreleased 超过
    #    一个段落——空壳头让"加条目"失去落点判断）。
    if unreleased_idx:
        nxt = next((l for l in lines[unreleased_idx[0] + 1:] if l.startswith("## ")), "")
        block = lines[unreleased_idx[0] + 1:lines.index(nxt) if nxt in lines else len(lines)]
        if not any(l.startswith("### ") for l in block):
            problems.append(f"{UNRELEASED} 下没有任何条目段落（空壳头）")

    if problems:
        for p in problems:
            print(f"✗ {p}")
        sys.exit(1)
    print(f"✓ CHANGELOG 结构正常（{len(headers)} 个版本段，顺序正确）")


def add(etype: str, entry: str) -> None:
    if etype not in TYPES:
        fail(f"未知类型 {etype}（可选: {'/'.join(TYPES)}）")
    entry = entry.strip("\n")
    if not entry.strip():
        fail("条目内容为空")

    text = PATH.read_text()
    lines = text.split("\n")

    # ① 确保 Unreleased 头存在（刚发过版 → 自动新建在文件头，并提示）
    if not any(l.strip() == UNRELEASED for l in lines):
        lines.insert(0, "")
        lines.insert(0, UNRELEASED)
        print("ℹ 无 [Unreleased] 段（刚发过版）——已在文件头新建")

    # ② 定位 Unreleased 块的边界（头 → 下一个 ## 头）
    uidx = next(i for i, l in enumerate(lines) if l.strip() == UNRELEASED)
    uend = next((i for i in range(uidx + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    block = lines[uidx + 1:uend]

    # ③ 在块内找 `### <etype>` 段：条目追加到该段末尾；没有则新建段
    sec = None
    for i, l in enumerate(block):
        if l.strip() == f"### {etype}":
            sec = i
            break
    entry_lines = entry.split("\n") + [""]
    if sec is None:
        # 插入位置：Unreleased 头后（跳过紧跟的空行），新段放最前
        insert_at = 0
        block = [f"### {etype}", ""] + entry_lines + block
        print(f"ℹ 新建 ### {etype} 段")
    else:
        # 段尾 = 下一个 ### 或块尾之前（去掉尾部空行再补一个）
        end = sec + 1
        while end < len(block) and not block[end].startswith("### "):
            end += 1
        while end > sec + 1 and block[end - 1].strip() == "":
            end -= 1
        block = block[:end] + entry_lines + block[end:]

    lines = lines[:uidx + 1] + block + lines[uend:]
    PATH.write_text("\n".join(lines))
    print(f"✓ 条目已加入 [Unreleased] › {etype}（{len(entry.splitlines())} 行）")
    verify()


def main() -> None:
    if len(sys.argv) < 2:
        fail(__doc__)
    cmd = sys.argv[1]
    if cmd == "verify":
        verify()
    elif cmd == "add":
        if len(sys.argv) < 3:
            fail("用法: changelog.py add <Type>（条目从 stdin 读）")
        add(sys.argv[2], sys.stdin.read())
    else:
        fail(f"未知命令 {cmd}")


if __name__ == "__main__":
    main()
