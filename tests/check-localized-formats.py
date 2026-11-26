#!/usr/bin/env python3
"""检查本地化格式串的参数顺序（v0.8.79 事故驱动）。

真实崩溃：`String(format: String(localized: "…%@…%@…%lld…%lld…"), 字符串, 字符串, Int, Int)`
的简体中文译文把格式符顺序改成了 `%@ %lld %@ %lld`——运行时把 Int 当对象发给
`objc_msgSend`，主线程 SIGSEGV。翻译可以改措辞，**不能改格式符的顺序/类型**。

规则：同一个键，en / zh-Hans / zh-Hant 的格式符序列（转换字符 + 位置）必须完全一致。
支持位置参数（%1$@）；不带位置的按出现顺序。`%%` 不算参数。

用法：python3 tests/check-localized-formats.py [path/to/Localizable.xcstrings]
"""
import json
import os
import re
import sys

# %[position$][flags][width][.precision][length]conversion
# `(?<![\w\d])` / `(?!\s)`：排除字面百分号（"80% and"、"%lld% success" 的第二个 %）。
SPEC = re.compile(
    r"%(?![\s%])(?:(\d+)\$)?[-+ #0']*(?:\d+|\*)?(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA])")


def specifiers(text):
    """格式符序列；有位置参数时按位置排序，否则按出现顺序。"""
    tokens = []
    positional = False
    for match in SPEC.finditer(text or ""):
        position, conversion = match.groups()
        if position:
            positional = True
            tokens.append((int(position), conversion.lower()))
        else:
            tokens.append((len(tokens) + 1, conversion.lower()))
    if positional:
        # 位置参数：按声明的位置排序，缺号不猜（交给调用方报数量差异）。
        tokens.sort(key=lambda item: item[0])
    return [conversion for _, conversion in tokens]


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "apps/macos/Desire/Localizable.xcstrings")
    catalog = json.loads(open(path, encoding="utf-8").read())
    problems = []
    checked = 0
    for key, entry in catalog.get("strings", {}).items():
        locals_ = entry.get("localizations") or {}
        source = (locals_.get("en", {}).get("stringUnit") or {}).get("value", key)
        expected = specifiers(source)
        if not expected:
            continue
        checked += 1
        for language in ("zh-Hans", "zh-Hant"):
            unit = (locals_.get(language, {}).get("stringUnit") or {}).get("value")
            if unit is None:
                continue
            actual = specifiers(unit)
            if actual != expected:
                problems.append((key, language, expected, actual, unit))
    for key, language, expected, actual, unit in problems:
        print("✗ %s [%s]: 期望 %s，实际 %s\n    %s" % (key, language, expected, actual, unit))
    print("\n本地化格式串：检查 %d 个键，问题 %d 个" % (checked, len(problems)))
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
