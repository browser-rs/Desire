#!/usr/bin/env python3
# DPP 文档站生成器（0.7.2 C 收尾）：docs/DPP-PROTOCOL.md → website/dpp/spec.html。
# 单一真相 = 仓库里的规范 md；本页是它的公开渲染（改规范后重跑本脚本再部署）。
# 用法：python3 tools/gen-dpp-spec-page.py   （仓库根执行）
import html
import re
from pathlib import Path

SRC = Path("docs/DPP-PROTOCOL.md")
OUT = Path("website/dpp/spec.html")

md = SRC.read_text(encoding="utf-8")

# ---------- 极简 md → HTML（覆盖本规范用到的子集） ----------

def inline(s: str) -> str:
    s = html.escape(s, quote=False)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"\*([^*]+)\*", r"<em>\1</em>", s)
    s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', s)
    return s


def render(md: str) -> str:
    out: list[str] = []
    lines = md.split("\n")
    i = 0
    in_code = False
    code_lang = ""
    code_buf: list[str] = []
    list_stack: list[str] = []  # "ul" | "ol"

    def close_lists():
        while list_stack:
            out.append(f"</{list_stack.pop()}>")

    while i < len(lines):
        line = lines[i]
        if in_code:
            if line.strip().startswith("```"):
                out.append("</code></pre>")
                in_code = False
            else:
                out.append(line)
            i += 1
            continue
        if line.strip().startswith("```"):
            close_lists()
            lang = line.strip()[3:].strip()
            out.append(f'<pre><code class="lang-{html.escape(lang or "text")}">')
            in_code = True
            i += 1
            continue
        # 表格：当前行含 | 且下一行是分隔行
        if "|" in line and i + 1 < len(lines) and re.match(r"^\s*\|?[\s:|-]+\|?\s*$", lines[i + 1]) and "-" in lines[i + 1]:
            close_lists()
            header = [c.strip() for c in line.strip().strip("|").split("|")]
            out.append("<table><thead><tr>" + "".join(f"<th>{inline(c)}</th>" for c in header) + "</tr></thead><tbody>")
            i += 2
            while i < len(lines) and "|" in lines[i] and lines[i].strip():
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                out.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in cells) + "</tr>")
                i += 1
            out.append("</tbody></table>")
            continue
        m = re.match(r"^(#{1,4})\s+(.*)$", line)
        if m:
            close_lists()
            level = len(m.group(1))
            text = m.group(2).strip()
            anchor = re.sub(r"[^\w\u4e00-\u9fff]+", "-", text).strip("-").lower()
            out.append(f'<h{level} id="{html.escape(anchor)}">{inline(text)}</h{level}>')
            i += 1
            continue
        if line.strip() == "---":
            close_lists()
            out.append("<hr>")
            i += 1
            continue
        if line.startswith(">"):
            close_lists()
            quote: list[str] = []
            while i < len(lines) and lines[i].startswith(">"):
                quote.append(lines[i].lstrip(">").strip())
                i += 1
            out.append("<blockquote>" + "".join(f"<p>{inline(q)}</p>" for q in quote if q) + "</blockquote>")
            continue
        m = re.match(r"^(\s*)[-*]\s+(.*)$", line)
        if m:
            want = "ul"
            if not list_stack or list_stack[-1] != want:
                close_lists()
                list_stack.append(want)
                out.append(f"<{want}>")
            out.append(f"<li>{inline(m.group(2))}</li>")
            i += 1
            continue
        m = re.match(r"^\s*\d+\.\s+(.*)$", line)
        if m:
            want = "ol"
            if not list_stack or list_stack[-1] != want:
                close_lists()
                list_stack.append(want)
                out.append(f"<{want}>")
            out.append(f"<li>{inline(m.group(1))}</li>")
            i += 1
            continue
        if not line.strip():
            close_lists()
            i += 1
            continue
        # 普通段落（连续非空行合一段）
        para = [line.strip()]
        i += 1
        while i < len(lines) and lines[i].strip() and not re.match(r"^(#{1,4}\s|```|\||>|\s*[-*]\s|\s*\d+\.\s)", lines[i]) and lines[i].strip() != "---":
            para.append(lines[i].strip())
            i += 1
        out.append(f"<p>{inline(' '.join(para))}</p>")
    close_lists()
    if in_code:
        out.append("</code></pre>")
    return "\n".join(out)


body = render(md)
toc = "".join(
    f'<a href="#{html.escape(re.sub(chr(92)+"w"+chr(92)+"u4e00-"+chr(92)+"u9fff]+", "-", m.group(2)).strip("-").lower())}">{html.escape(m.group(2))}</a>'
    for m in (re.match(r"^(#{2})\s+(.*)$", l) for l in md.split("\n")) if m
)

page = f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DPP 规范全文 — Desire Page Protocol v1.1</title>
<meta name="description" content="Desire Page Protocol（DPP）v1.1 规范全文：设计原则、协议分层、接入形态、核心 Schema、Profile 契约、安全模型与运行时实现。">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='10' fill='%23c03a1a'/%3E%3Ctext x='32' y='44' font-size='36' text-anchor='middle' fill='%23f6f1e7' font-family='Kaiti SC, STKaiti, serif'%3E%E6%AC%B2%3C/text%3E%3C/svg%3E">
<style>
  :root {{
    --paper: #f6f1e7; --paper-2: #eee7d7; --ink: #211b13; --ink-soft: #6a6150;
    --cinnabar: #c03a1a; --cinnabar-d: #93290e; --hairline: rgba(33,27,19,0.16);
    --font-display: "Hoefler Text", "Songti SC", "Georgia", serif;
    --font-body: -apple-system, "PingFang SC", "Hiragino Sans GB", sans-serif;
    --font-mono: "SF Mono", "Menlo", "Consolas", monospace;
  }}
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  body {{ background: var(--paper); color: var(--ink); font-family: var(--font-body); font-size: 15.5px; line-height: 1.75; }}
  a {{ color: var(--cinnabar-d); text-underline-offset: 3px; }}
  header {{ padding: 26px 0 0; }}
  .wrap {{ max-width: 920px; margin: 0 auto; padding: 0 4vw; }}
  .crumbs {{ font-size: 14px; }}
  h1 {{ font-family: var(--font-display); font-size: 34px; margin: 26px 0 8px; }}
  .srcnote {{ color: var(--ink-soft); font-size: 13.5px; margin-bottom: 18px; }}
  nav.toc {{ background: var(--paper-2); border: 1px solid var(--hairline); border-radius: 10px; padding: 14px 18px; margin: 18px 0 8px; font-size: 13.5px; line-height: 2; }}
  nav.toc a {{ margin-right: 14px; white-space: nowrap; }}
  main {{ padding: 12px 0 40px; }}
  h2 {{ font-family: var(--font-display); font-size: 25px; margin: 40px 0 10px; border-bottom: 1px solid var(--hairline); padding-bottom: 8px; }}
  h3 {{ font-size: 19px; margin: 28px 0 8px; }}
  h4 {{ font-size: 16px; margin: 22px 0 6px; color: var(--cinnabar-d); }}
  p {{ margin: 10px 0; }}
  ul, ol {{ margin: 10px 0 10px 24px; }}
  li {{ margin: 4px 0; }}
  blockquote {{ border-left: 3px solid var(--cinnabar); background: var(--paper-2); border-radius: 0 8px 8px 0; padding: 10px 16px; margin: 14px 0; }}
  blockquote p {{ margin: 6px 0; }}
  pre {{ background: var(--ink); color: #ece3cd; border-radius: 10px; padding: 16px 18px; overflow-x: auto;
    font-family: var(--font-mono); font-size: 12.5px; line-height: 1.6; margin: 14px 0; }}
  code {{ font-family: var(--font-mono); font-size: 0.9em; background: var(--paper-2); border-radius: 4px; padding: 1px 5px; }}
  pre code {{ background: none; padding: 0; }}
  table {{ border-collapse: collapse; margin: 14px 0; font-size: 13.5px; max-width: 100%; }}
  th, td {{ border: 1px solid var(--hairline); padding: 6px 12px; text-align: left; vertical-align: top; }}
  th {{ background: var(--paper-2); font-weight: 700; }}
  hr {{ border: none; border-top: 1px solid var(--hairline); margin: 26px 0; }}
  footer {{ padding: 26px 0 46px; color: var(--ink-soft); font-size: 13px; border-top: 1px solid var(--hairline); }}
</style>
</head>
<body>
<header><div class="wrap">
  <div class="crumbs"><a href="./">← DPP 首页</a> · <a href="./sdk.html">SDK 参考</a> · <a href="https://github.com/browser-rs/Desire/blob/main/docs/DPP-PROTOCOL.md">规范源文件</a></div>
  <h1>DPP 规范全文（v1.1）</h1>
  <div class="srcnote">由 <code>docs/DPP-PROTOCOL.md</code> 生成（<code>tools/gen-dpp-spec-page.py</code>）；规范以仓库源文件为准。</div>
  <nav class="toc">{toc}</nav>
</div></header>
<main><div class="wrap">
{body}
</div></main>
<footer><div class="wrap">DPP 由 <a href="https://desire.mankong.icu/">Desire 浏览器</a>实现与维护 · 本页零外部依赖</div></footer>
</body>
</html>
"""

OUT.write_text(page, encoding="utf-8")
print(f"written {OUT} ({len(page)} bytes)")
