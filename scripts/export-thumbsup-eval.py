#!/usr/bin/env python3
"""导出 👍 回合成评估素材（个性化 7：评估集回归的语料端）。

扫描全部会话轨迹，提取用户点过 👍 的回合（goal + answer + 会话标题），
生成 agent-eval.py --fixtures 可消费的 JSON。

**⚠️ 输出含真实会话内容——默认写到 agent 工作区（仓库外），绝不要提交进仓库。**
脱敏：常见凭据模式（sk-…/Bearer/AKIA…/password=…）一律掩码；--redact-hosts
再把 http(s) URL 的 host 换成 <host>（会失真，站点 scope 类断言别开）。

用法：
  python3 scripts/export-thumbsup-eval.py            # 全部会话
  python3 scripts/export-thumbsup-eval.py --limit 30
  python3 scripts/export-thumbsup-eval.py --redact-hosts --out /tmp/t.json
"""
import argparse
import json
import re
import sys
import urllib.request

BRIDGE = "http://127.0.0.1:8799"
DEFAULT_OUT = "/Users/mankong/Documents/DesireAgent/eval/thumbsup-fixtures.json"

SECRET_PATTERNS = [
    re.compile(r"sk-[A-Za-z0-9_-]{8,}"),
    re.compile(r"Bearer\s+[A-Za-z0-9._-]{8,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"(?i)(password|passwd|token|secret)\s*[=:]\s*\S+"),
]
HOST_RE = re.compile(r"(https?://)([^/\s\"']+)")


def bridge_get(path):
    with urllib.request.urlopen(BRIDGE + path, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def redact(text, redact_hosts):
    if not text:
        return text
    for pattern in SECRET_PATTERNS:
        text = pattern.sub("[REDACTED]", text)
    if redact_hosts:
        text = HOST_RE.sub(r"\1<host>", text)
    return text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=200, help="扫描的会话数上限")
    parser.add_argument("--max-items", type=int, default=50, help="导出条目上限")
    parser.add_argument("--redact-hosts", action="store_true", help="URL host 泛化为 <host>")
    parser.add_argument("--out", default=DEFAULT_OUT)
    args, _ = parser.parse_known_args()

    conversations = bridge_get(f"/conversations?limit={args.limit}").get("conversations", [])
    print(f"扫描 {len(conversations)} 个会话 …")
    items = []
    seen_goals = set()
    for conv in conversations:
        cid = conv.get("id")
        title = conv.get("title") or ""
        try:
            trace = bridge_get(f"/agent/trace?conversation={cid}&limit=200")
        except Exception as exc:
            print(f"  跳过 {cid[:8]} ({exc})")
            continue
        for line in (trace.get("jsonl") or "").split("\n"):
            line = line.strip()
            if not line:
                continue
            try:
                turn = json.loads(line)
            except Exception:
                continue
            if turn.get("feedback") != "up":
                continue
            goal = redact(turn.get("goal"), args.redact_hosts) or ""
            if not goal or goal in seen_goals:
                continue
            seen_goals.add(goal)
            items.append({
                "goal": goal[:500],
                "answer": (redact(turn.get("answer"), args.redact_hosts) or "")[:2000],
                "title": redact(title, args.redact_hosts),
            })
            if len(items) >= args.max_items:
                break
        if len(items) >= args.max_items:
            break

    out = {
        "warning": "Contains real conversation content — do NOT commit this file.",
        "exportedAt": __import__("datetime").datetime.now().isoformat(),
        "count": len(items),
        "fixtures": items,
    }
    import os
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(f"导出 {len(items)} 条 👍 回合 → {args.out}")
    print("（含真实会话内容，勿提交仓库；agent-eval.py --fixtures 可消费）")
    return 0 if items else 1


if __name__ == "__main__":
    sys.exit(main())
