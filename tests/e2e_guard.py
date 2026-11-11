#!/usr/bin/env python3
"""破坏性 E2E 的公共守卫（v0.8.53 回归迭代）。

2026-11-12 事故：回归套件运行期间，用户同时打开了 /Applications 的正式版——
机器上出现两个同名 Desire 实例。后果：① AppleScript/AX 的目标有歧义
（菜单/activate 可能按到用户的正式版）；② 两个实例共用同一份
~/Library/Application Support/Desire 用户数据，互相覆盖会话文件。

规矩：所有会退出/重启/驱动应用的 E2E，跑之前必须调用
`guard_single_dev_instance()`——多实例或"跑的是已安装版"一律拒绝执行。
"""

import subprocess

INSTALLED_APP_MARKER = "/Applications/Desire.app/"


def desire_pids() -> list[int]:
    out = subprocess.run(["pgrep", "-x", "Desire"], capture_output=True, text=True).stdout
    return [int(x) for x in out.split()] if out.strip() else []


def process_bundle(pid: int) -> str:
    command = subprocess.run(["ps", "-o", "command=", "-p", str(pid)],
                             capture_output=True, text=True).stdout
    marker = ".app/Contents/MacOS/"
    index = command.find(marker)
    return command[:index + len(".app")] if index > -1 else command


def guard_single_dev_instance() -> bool:
    """返回 True = 可以继续；False = 打印原因并拒绝。"""
    pids = desire_pids()
    if len(pids) > 1:
        print(f"拒绝执行：检测到 {len(pids)} 个 Desire 实例（{pids}）。"
              "多实例会让 AppleScript/AX 目标产生歧义，且共用同一份用户数据——"
              "请先只保留一个实例（建议保留开发构建）再跑。")
        return False
    if pids and INSTALLED_APP_MARKER in process_bundle(pids[0]):
        print("拒绝执行：当前运行的是用户已安装的正式版（/Applications）——"
              "测试绝不允许驱动/退出它。请改用开发构建（xcodebuild 产物）跑套件。")
        return False
    return True
