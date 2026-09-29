#!/usr/bin/env python3
"""校验 website/index.html 的 FAQPage JSON-LD 与可见 FAQ 逐字一致。

可见侧以 <details class="faq-item"> 为准：<summary> 即问题、<p> 去掉
<code> 等行内标签后即答案。任何一侧改动都必须同步另一侧（改完跑本脚本）。

用法：python3 tools/check_faq_sync.py   （在仓库根目录）
"""
import json
import re
import sys
from html import unescape
from pathlib import Path

root = Path(__file__).resolve().parent.parent
html = (root / "website" / "index.html").read_text(encoding="utf-8")

m = re.search(r'<script type="application/ld\+json">\s*(\{.*?\})\s*</script>', html, re.S)
if not m:
    sys.exit("✗ 找不到 JSON-LD")
graph = json.loads(m.group(1))["@graph"]
faq_ld = [x for x in graph if x.get("@type") == "FAQPage"]
if not faq_ld:
    sys.exit("✗ JSON-LD 里没有 FAQPage")
ld_items = [(q["name"], q["acceptedAnswer"]["text"]) for q in faq_ld[0]["mainEntity"]]

visible = []
for block in re.findall(r'<details class="faq-item[^"]*"[^>]*>(.*?)</details>', html, re.S):
    sm = re.search(r"<summary>(.*?)</summary>", block, re.S)
    pm = re.search(r"<p>(.*?)</p>", block, re.S)
    if not (sm and pm):
        sys.exit(f"✗ 可见 FAQ 缺 summary/p：{block[:60]}")
    q = unescape(re.sub(r"<[^>]+>", "", sm.group(1))).strip()
    a = unescape(re.sub(r"<[^>]+>", "", pm.group(1))).strip()
    visible.append((q, a))

errors = []
if len(ld_items) != len(visible):
    errors.append(f"条数不一致：JSON-LD {len(ld_items)} vs 可见 {len(visible)}")
for i, ((lq, la), (vq, va)) in enumerate(zip(ld_items, visible), 1):
    if lq != vq:
        errors.append(f"Q{i} 问题不一致：\n  ld = {lq!r}\n  web = {vq!r}")
    if la != va:
        errors.append(f"Q{i} 答案不一致：\n  ld  = {la!r}\n  web = {va!r}")

if errors:
    print("✗ FAQ 双向不一致：")
    for e in errors:
        print(" ", e)
    sys.exit(1)
print(f"✓ FAQ 双向逐字一致（{len(visible)} 条）")
