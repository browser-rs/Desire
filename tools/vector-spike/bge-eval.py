#!/usr/bin/env python3
# 0.7.1 阶段二前置评测：bge-small-zh-v1.5 (GGUF, llama.cpp) 能否超越 BM25？
# 对照集与 tools/vector-spike/hybrid-probe.swift 完全一致（30 事实 × 15 查询）；
# BM25 参照值 = Swift 探针实测（产品码 MemoryRetrieval.rank）。
# **结论（2026-10-07 实测，f16 与 q8_0 一致）：门槛通过**——带 bge 官方查询
# 指令前缀 top-1 13/15、top-3 15/15（BM25 为 8/15、9/15），零重叠子集 4/6
# （BM25/NLE 均 0/6）；单条 ~4ms、30 条批量 ~37ms。数据见
# docs/VECTOR-MEMORY-SPIKE.md「阶段二门槛评测」。
# 运行（仓库根；stdlib-only，无第三方依赖）：
#   curl -L -o /tmp/bge-small-zh-v1.5-q8_0.gguf \
#     https://huggingface.co/CompendiumLabs/bge-small-zh-v1.5-gguf/resolve/main/bge-small-zh-v1.5-q8_0.gguf
#   llama-server -m /tmp/bge-small-zh-v1.5-q8_0.gguf --embeddings --port 8891 --ctx-size 512
#   python3 tools/vector-spike/bge-eval.py          # 端口可经 BGE_BASE 覆盖
import json
import math
import os
import urllib.request

BASE = os.environ.get("BGE_BASE", "http://127.0.0.1:8891/v1/embeddings")
BGE_QUERY_PREFIX = "为这个句子生成表示以用于检索相关文章："  # bge v1.5 官方查询指令

fact_defs = [
    ("回答要简洁直接不要啰嗦", "preference"),
    ("下载画质优先选择最高清晰度", "preference"),
    ("下载失败时应该自动重试", "correction"),
    ("用户经常批量下载视频文件", "habit"),
    ("用户偏好用中文回答问题", "preference"),
    ("界面喜欢深色主题", "preference"),
    ("书签需要按文件夹分类整理", "habit"),
    ("每周清理一次浏览历史", "habit"),
    ("标签页不要自动刷新", "preference"),
    ("关闭窗口前要提醒保存会话", "preference"),
    ("下载完成后发系统通知", "preference"),
    ("视频广告必须自动拦截", "preference"),
    ("弹窗一律阻止不要询问", "preference"),
    ("搜索引擎保持默认不要改", "preference"),
    ("新标签页打开空白页", "preference"),
    ("阅读列表的文章要定期看完", "habit"),
    ("截图统一保存到桌面文件夹", "habit"),
    ("快捷键保持默认不要自定义", "preference"),
    ("密码自动填充保持开启", "preference"),
    ("无痕模式下的下载不进历史", "fact"),
    ("长回答分段输出", "preference"),
    ("代码块要标注语言", "preference"),
    ("工具执行前先说明意图", "preference"),
    ("失败的工具不要连续重试超过三次", "correction"),
    ("用户时区是东八区", "fact"),
    ("邮件类通知一律忽略", "preference"),
    ("会话标题自动生成就好", "preference"),
    ("记忆条目保持精简不要囤积", "preference"),
    ("翻译目标语言是英文", "preference"),
    ("用户习惯清晨处理长任务", "habit"),
]
queries = [
    ("下载失败要怎么处理", 2),
    ("高清画质在哪设置", 1),
    ("广告拦截在哪里开关", 11),
    ("截图默认存到哪里", 16),
    ("翻译功能设置成什么语言", 28),
    ("弹窗拦截要不要开", 12),
    ("浏览历史多久清理一次", 7),
    ("密码填充开关在哪", 18),
    ("回复风格简短一点", 0),
    ("他希望回复用什么语言", 4),
    ("片子都是好几部一起存", 3),
    ("屏幕太亮看着难受", 5),
    ("动手以前讲一下你准备干什么", 22),
    ("内容多的话切几条消息发", 20),
    ("一大早跑耗时活儿", 29),
]

# BM25 参照（hybrid-probe.swift 实测，产品码）
BM25_TOP1, BM25_TOP3 = 8, 9


def is_cjk(ch):
    o = ord(ch)
    return (0x4E00 <= o <= 0x9FFF) or (0x3040 <= o <= 0x30FF)


def tokenize(text):
    # 与 MemoryRetrieval.tokenize 同口径：latin 连串一词、CJK bigram（单字 run 保留）。
    tokens = []
    latin = ""
    cjk = []

    def flush_latin():
        nonlocal latin
        if latin:
            tokens.append(latin)
            latin = ""

    def flush_cjk():
        nonlocal cjk
        if len(cjk) == 1:
            tokens.append(cjk[0])
        else:
            for i in range(len(cjk) - 1):
                tokens.append(cjk[i] + cjk[i + 1])
        cjk.clear()

    for ch in text.lower():
        if ch.isalnum():
            if is_cjk(ch):
                flush_latin()
                cjk.append(ch)
            else:
                flush_cjk()
                latin += ch
        else:
            flush_latin()
            flush_cjk()
    flush_latin()
    flush_cjk()
    return tokens


def has_lexical_overlap(q, docs):
    qt = set(tokenize(q))
    return any(not qt.isdisjoint(tokenize(doc)) for doc in docs)


def embed(texts, prefix=""):
    body = json.dumps({"input": [prefix + t for t in texts]}).encode()
    req = urllib.request.Request(
        BASE, data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.load(resp)
    return [e["embedding"] for e in data["data"]]


def cos(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    return dot / (na * nb) if na > 0 and nb > 0 else 0.0


def center(vecs):
    dim = len(vecs[0])
    mean = [sum(v[i] for v in vecs) / len(vecs) for i in range(dim)]
    return [[v[i] - mean[i] for i in range(dim)] for v in vecs], mean


def rank_order(qv, fvecs):
    sims = [cos(qv, fv) for fv in fvecs]
    return sorted(range(len(sims)), key=lambda i: -sims[i]), sims


def run_eval(name, qvecs, fvecs):
    top1 = top3 = 0
    nolex = [i for i, (q, _) in enumerate(queries) if not has_lexical_overlap(q, docs)]
    nolex_top1 = 0
    lex_top1 = 0
    lex_count = 0
    print(f"\n== {name} ==")
    for qi, (q, expect) in enumerate(queries):
        order, sims = rank_order(qvecs[qi], fvecs)
        pos = order.index(expect) + 1
        if pos == 1:
            top1 += 1
        if pos <= 3:
            top3 += 1
        lexical = has_lexical_overlap(q, docs)
        if lexical:
            lex_count += 1
            if pos == 1:
                lex_top1 += 1
        else:
            if pos == 1:
                nolex_top1 += 1
        print(
            "Q%-2d[%s] 「%s」→ 期望F%-2d | 排位 第%-2d (%.3f) %s"
            % (
                qi + 1,
                "词法" if lexical else "改写",
                q,
                expect + 1,
                pos,
                sims[expect],
                "✓" if pos == 1 else "✗",
            )
        )
    print("top1 %d/%d  top3 %d/%d  (词法子集 %d/%d, 零重叠子集 %d/%d)"
          % (top1, len(queries), top3, len(queries), lex_top1, lex_count,
             nolex_top1, len(nolex)))
    return top1, top3, nolex_top1, len(nolex)


docs = [c + " " + cat for c, cat in fact_defs]
contents = [c for c, _ in fact_defs]

fact_vecs = embed(contents)
q_vecs_plain = embed([q for q, _ in queries])
q_vecs_instr = embed([q for q, _ in queries], prefix=BGE_QUERY_PREFIX)

print("== bge-small-zh-v1.5 f16（%d 维）| BM25 参照 top1 %d/15 top3 %d/15 =="
      % (len(fact_vecs[0]), BM25_TOP1, BM25_TOP3))

t1a = run_eval("查询原文（无指令前缀）", q_vecs_plain, fact_vecs)
cfvecs, cmean = center(fact_vecs)
cqvecs = [[v[i] - cmean[i] for i in range(len(cmean))] for v in q_vecs_plain]
t1b = run_eval("查询原文 + 居中化", cqvecs, cfvecs)
t1c = run_eval("查询带 bge 官方指令前缀", q_vecs_instr, fact_vecs)

print("\n---- 验收（阶段二门槛：真增益才谈捆绑）----")
for name, (top1, top3, nl1, nn) in [
    ("无前缀", t1a), ("居中化", t1b), ("带指令前缀", t1c),
]:
    gap = top1 - BM25_TOP1
    print("%s: top1 %d/15 (%+d vs BM25)  零重叠 %d" % (name, top1, gap, nl1))
best = max(t1a[0], t1b[0], t1c[0])
if best > BM25_TOP1:
    print("结论：bge 最优形态 %d/15 > BM25 %d/15 —— 存在真增益，捆绑可谈（体积/延迟/Core ML 转换另评）" % (best, BM25_TOP1))
elif best == BM25_TOP1:
    print("结论：bge 最优形态 %d/15 == BM25 %d/15 —— 无增益，向量路线整体关闭" % (best, BM25_TOP1))
else:
    print("结论：bge 最优形态 %d/15 < BM25 %d/15 —— 无增益，向量路线整体关闭" % (best, BM25_TOP1))
