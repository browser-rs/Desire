#!/usr/bin/env python3
"""DPP 声明自检器（站点作者 + CI 用，无第三方依赖）。

校验一份 DPP 声明是否合法、是否会踩已知陷阱。输入可以是：
  - 一个 HTML 文件（提取其中的 x-desire+json 块）——默认校验 website/index.html
  - 一个 JSON 文件（纯声明）
  - 一个 URL（抓取后提取声明块）

规则与 docs/dpp-schema.json 一致；在它之上再检查**运行时陷阱**
（应用是容错解码：坏字段会被丢并记 warning，本工具把 warning 提前给你）：
  - 未知 profile / 未知 run 步骤操作 / fields 值非字符串（会被丢）
  - events 对象形态（合法，会展平取 watch；`on` 当前被忽略）
  - context 值带数组（合法，逗号连接）——提醒
  - 选择器为空字符串（必然匹配不到）
  - actions 里 effects=outbound/danger 未标注（安全默认建议显式标注）

退出码：0 = 无 FAIL（可有 WARN）；1 = 有 FAIL。
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

KNOWN_OPS = {"fill", "click", "select", "waitForText", "waitFor", "hover", "pressKey", "upload", "navigate"}
KNOWN_PROFILES = {"chat", "catalog", "forms", "checkout", "monitor", "workbench"}
KNOWN_EFFECTS = {"local", "persist", "outbound"}

fails: list[str] = []
warns: list[str] = []


def fail(msg: str) -> None:
    fails.append(msg)


def warn(msg: str) -> None:
    warns.append(msg)


def extract_declaration(text: str) -> dict:
    m = re.search(r'<script type="application/x-desire\+json">\s*(\{.*?\})\s*</script>', text, re.S)
    if m:
        return json.loads(m.group(1))
    stripped = text.strip()
    if stripped.startswith("{"):
        return json.loads(stripped)
    raise ValueError("未找到声明块（<script type=\"application/x-desire+json\">）也不是 JSON")


def validate(d: dict) -> None:
    if not isinstance(d, dict):
        fail("顶层必须是对象")
        return
    if "protocol" not in d and "protocolVersion" not in d:
        warn("未声明 protocol（建议 \"desire/1\"）")
    elif isinstance(d.get("protocol"), str) and not re.fullmatch(r"desire/\d+", d["protocol"]):
        fail(f"protocol 版本格式非法：{d['protocol']!r}（应形如 desire/1）")

    profile = d.get("profile")
    if profile is not None:
        if not isinstance(profile, str):
            fail("profile 必须是字符串")
        elif profile not in KNOWN_PROFILES:
            warn(f"未知 profile {profile!r}（运行时透传，但无标准约定可依）")

    content = d.get("content", {})
    if content and not isinstance(content, dict):
        fail("content 必须是对象")
    elif isinstance(content, dict):
        ignore = content.get("ignore")
        if ignore is not None and not (isinstance(ignore, list) and all(isinstance(x, str) for x in ignore)):
            fail("content.ignore 必须是字符串数组")

    for name, view in (d.get("views") or {}).items():
        if not isinstance(view, dict):
            fail(f"view {name!r} 必须是对象")
            continue
        item = view.get("item")
        if not isinstance(item, str) or not item.strip():
            fail(f"view {name!r} 缺 item（或为空选择器）")
        for fname, fpath in (view.get("fields") or {}).items():
            if isinstance(fpath, str):
                continue
            if isinstance(fpath, dict):
                if not isinstance(fpath.get("selector", ""), str) or not isinstance(fpath.get("attr", ""), str):
                    fail(f"view {name!r} 字段 {fname!r} 对象形态的 selector/attr 必须是字符串")
                ftype = fpath.get("type")
                if ftype is not None and ftype not in {"string", "number", "price", "url", "date", "bool"}:
                    warn(f"view {name!r} 字段 {fname!r} 未知类型 {ftype!r}（运行时回退字符串）")
            else:
                fail(f"view {name!r} 字段 {fname!r} 的值必须是字符串或 {{selector/attr/type}} 对象")
        pag = view.get("pagination")
        if pag is not None:
            if not isinstance(pag, dict) or pag.get("type") not in {"paged", "infinite", "none", None}:
                fail(f"view {name!r} pagination.type 须为 paged/infinite/none")

    for i, action in enumerate(d.get("actions") or []):
        if not isinstance(action, dict) or not isinstance(action.get("name"), str) or not action["name"]:
            fail(f"actions[{i}] 缺 name")
            continue
        an = action["name"]
        if action.get("effects") is not None and action["effects"] not in KNOWN_EFFECTS:
            fail(f"action {an!r} effects 须为 local/persist/outbound（当前 {action['effects']!r}）")
        run = action.get("run")
        if run is not None:
            if not isinstance(run, list):
                fail(f"action {an!r} run 必须是步骤数组")
            else:
                for j, step in enumerate(run):
                    if not isinstance(step, dict) or len(step) != 1:
                        fail(f"action {an!r} 步骤 {j} 必须是单键对象（如 {{\"click\": \".x\"}}）")
                        continue
                    op = next(iter(step))
                    if op not in KNOWN_OPS:
                        fail(f"action {an!r} 步骤 {j} 未知操作 {op!r}（运行时该步会失败）——"
                             f"支持：{', '.join(sorted(KNOWN_OPS))}")
        if action.get("effects") == "outbound" and action.get("danger") is not True:
            warn(f"action {an!r} 标了 outbound 但未标 danger —— 两者都会强制逐次审批，"
                 "但显式标注 danger 语义更清楚")

    for name, ev in (d.get("events") or {}).items():
        if isinstance(ev, str):
            if not ev.strip():
                fail(f"event {name!r} 选择器为空")
        elif isinstance(ev, dict):
            if not isinstance(ev.get("watch"), str) or not ev["watch"].strip():
                fail(f"event {name!r} 对象形态缺 watch 选择器")
            if "on" in ev:
                warn(f"event {name!r} 的 on={ev['on']!r} 当前被运行时忽略（宿主统一按出现跳变监听）")
        else:
            fail(f"event {name!r} 的值必须是选择器字符串或 {{watch}} 对象")

    ctx = d.get("context")
    if ctx is not None and not isinstance(ctx, dict):
        fail("context 必须是对象")
    elif isinstance(ctx, dict):
        for key, value in ctx.items():
            if isinstance(value, list):
                warn(f"context.{key} 是数组——运行时会逗号连接为字符串")

    pages = d.get("pages")
    if pages is not None:
        if not isinstance(pages, dict):
            fail("pages 必须是对象（路径模式 → 提示）")
        else:
            for pattern, entry in pages.items():
                if not isinstance(entry, dict):
                    fail(f"pages[{pattern!r}] 必须是对象")
                elif entry.get("profile") and entry["profile"] not in KNOWN_PROFILES:
                    warn(f"pages[{pattern!r}].profile 未知：{entry['profile']!r}")


def main() -> None:
    target = sys.argv[1] if len(sys.argv) > 1 else "website/index.html"
    source = target
    if target.startswith("http://") or target.startswith("https://"):
        with urllib.request.urlopen(target, timeout=15) as r:  # noqa: S310
            text = r.read().decode("utf-8", errors="replace")
    else:
        path = Path(target)
        if not path.exists():
            print(f"✗ 找不到 {target}")
            sys.exit(1)
        text = path.read_text(encoding="utf-8")

    try:
        declaration = extract_declaration(text)
    except (ValueError, json.JSONDecodeError) as e:
        print(f"✗ 声明解析失败：{e}")
        sys.exit(1)

    validate(declaration)

    print(f"DPP 声明校验：{source}")
    views = declaration.get("views") or {}
    actions = declaration.get("actions") or []
    print(f"  profile={declaration.get('profile') or '(未声明)'} views={len(views)} "
          f"actions={len(actions)} events={len(declaration.get('events') or {})}")
    for w in warns:
        print(f"  ⚠ {w}")
    for f in fails:
        print(f"  ✗ {f}")
    if fails:
        print(f"\n✗ {len(fails)} 项失败，{len(warns)} 项警告")
        sys.exit(1)
    print(f"\n✓ 通过（{len(warns)} 项警告）")


if __name__ == "__main__":
    main()
