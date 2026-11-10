#!/usr/bin/env python3
"""VideoPro 命令面漂移对账（v0.8.48 批 3）：实现 vs 文档，静态检查，不需要跑应用。

对比三处：
  - VideoProCommands.apply 顶层 switch 的 case（唯一实现）；
  - Agent 工具 editVideoPro 的 description 里 "Actions: …" 列表；
  - 桥 POST /video/edit 的端点描述里 "Actions: …" 列表。
任何一处多出/漏掉动作都判失败（新增动作记得三处同步）。

用法：python3 tests/video-pro-actions.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMMANDS = ROOT / "apps/macos/Desire/Features/VideoPro/VideoProCommands.swift"
DEFINITIONS = ROOT / "apps/macos/Desire/Features/Agent/BrowserToolProvider+Definitions.swift"
SERVER = ROOT / "apps/macos/Desire/App/AutomationServer.swift"


def implemented_actions() -> set[str]:
    text = COMMANDS.read_text(encoding="utf-8")
    # 顶层动作 case 缩进 12 空格；嵌套（draft 的 op/track 的 op）缩进更深。
    return set(re.findall(r'^            case "([a-z]+)":', text, re.MULTILINE))


def documented_actions(text: str, anchor: str) -> set[str]:
    index = text.find(anchor)
    if index < 0:
        return set()
    tail = text[index:]
    match = re.search(r"Actions:([^\"\n]*)", tail)
    if not match:
        return set()
    actions = set()
    for chunk in match.group(1).split(";"):
        token = chunk.strip().split()[0] if chunk.strip() else ""
        token = token.strip("{}[](),.")
        for part in token.split("/"):
            if part and re.fullmatch(r"[a-z]+", part):
                actions.add(part)
    return actions


def main() -> int:
    implemented = implemented_actions()
    tool = documented_actions(DEFINITIONS.read_text(encoding="utf-8"), 'name: "editVideoPro"')
    bridge = documented_actions(SERVER.read_text(encoding="utf-8"), '"/video/edit"')
    failures = []
    if not implemented:
        failures.append("could not parse implemented actions")
    for label, documented in (("tool description", tool), ("bridge doc", bridge)):
        missing = sorted(implemented - documented)
        extra = sorted(documented - implemented)
        if missing:
            failures.append(f"{label} missing: {missing}")
        if extra:
            failures.append(f"{label} extra: {extra}")
    print("implemented:", len(implemented), "tool:", len(tool), "bridge:", len(bridge))
    if failures:
        for line in failures:
            print("FAIL", line)
        return 1
    print("PASS action surface is in sync")
    return 0


if __name__ == "__main__":
    sys.exit(main())
