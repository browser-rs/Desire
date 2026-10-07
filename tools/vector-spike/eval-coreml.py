#!/usr/bin/env python3
# 0.7.1 阶段二：CoreML 转换质量闸门（fp16 vs int8 vs GGUF 参照）。
# 同一 30×15 验收集（与 hybrid-probe.swift / bge-eval.py 同源，数据冻结）；
# 分词用 HF BertTokenizer（转换同源），模型用 coremltools 直接 predict。
# GGUF 参照（llama.cpp，带查询指令前缀）：top1 13/15 top3 15/15。
# 运行：/tmp/mlconv/bin/python tools/vector-spike/eval-coreml.py /tmp/bge-hf /tmp/bge-out
import sys
from pathlib import Path

import numpy as np
import coremltools as ct
from transformers import AutoTokenizer

SRC = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/bge-hf")
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("/tmp/bge-out")
MAX_LEN = 512
BGE_QUERY_PREFIX = "为这个句子生成表示以用于检索相关文章："

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
BM25_TOP1 = 8

contents = [c for c, _ in fact_defs]


def cos(a, b):
    d = float(np.dot(a, b))
    return d / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12)


def embed_batch(model, tokenizer, texts, prefix=""):
    out = []
    for t in texts:
        enc = tokenizer(prefix + t, padding="max_length", truncation=True,
                        max_length=MAX_LEN, return_tensors="np")
        r = model.predict({
            "input_ids": enc["input_ids"].astype(np.int32),
            "attention_mask": enc["attention_mask"].astype(np.int32),
        })
        vec = list(r.values())[0].flatten().astype(np.float32)
        out.append(vec / (np.linalg.norm(vec) + 1e-12))
    return out


def evaluate(name, model, tokenizer):
    fvecs = embed_batch(model, tokenizer, contents)
    qvecs = embed_batch(model, tokenizer, [q for q, _ in queries], prefix=BGE_QUERY_PREFIX)
    top1 = top3 = 0
    for (q, expect), qv in zip(queries, qvecs):
        order = sorted(range(len(fvecs)), key=lambda i: -cos(qv, fvecs[i]))
        pos = order.index(expect) + 1
        if pos == 1:
            top1 += 1
        if pos <= 3:
            top3 += 1
    print("%s: top1 %d/15  top3 %d/15" % (name, top1, top3))
    return top1, top3


if "--dump" in sys.argv:
    # 导出同一对照集为桥端点 /memory/retrieval-eval 的请求体（应用内回归用）。
    import json
    payload = {
        "facts": [{"content": c, "category": cat} for c, cat in fact_defs],
        "queries": [{"q": q, "expect": e} for q, e in queries],
    }
    out = Path("/tmp/eval-set.json")
    out.write_text(json.dumps(payload, ensure_ascii=False))
    print("payload:", out)
    sys.exit(0)

tokenizer = AutoTokenizer.from_pretrained(str(SRC), local_files_only=True)
for name, path in [("fp16", "BGEZh-fp16.mlpackage"), ("int8", "BGEZh-int8.mlpackage")]:
    model = ct.models.MLModel(str(OUT / path))
    evaluate(name, model, tokenizer)
print("参照：GGUF(带前缀) 13/15 · BM25 %d/15" % BM25_TOP1)
