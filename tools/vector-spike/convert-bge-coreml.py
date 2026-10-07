#!/usr/bin/env python3
# 0.7.1 阶段二：bge-small-zh-v1.5 → Core ML（转换链一次性脚本，2026-10-07）。
# 产物：BGEZh-fp16.mlpackage / BGEZh-int8.mlpackage（供 app 打包，二选一）
# 与 BGEZhVocab.txt（WordPiece 词表，Swift 分词器用）。
# 模型 = BertModel 编码器；CLS 池化烘进 traced 图（输出 [1,512]），L2 归一化在
# Swift 侧做。输入固定 [1,512]（memories 短文本，ANode 友好；质量与 512 上限
# 评测一致）。
# 运行（一次性，开发机）：
#   python3 -m venv /tmp/mlconv
#   /tmp/mlconv/bin/pip install torch transformers coremltools numpy
#   /tmp/mlconv/bin/python tools/vector-spike/convert-bge-coreml.py /tmp/bge-hf /tmp/bge-out
# 源权重目录（/tmp/bge-hf）= config.json + tokenizer_config.json + vocab.txt +
# model.safetensors（HF 或 hf-mirror，BAAI/bge-small-zh-v1.5）。
import sys
from pathlib import Path

import numpy as np
import torch
import coremltools as ct
from transformers import AutoModel, AutoTokenizer

SRC = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/bge-hf")
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("/tmp/bge-out")
MAX_LEN = 512
OUT.mkdir(parents=True, exist_ok=True)

model = AutoModel.from_pretrained(str(SRC), local_files_only=True)
model.eval()


class ClsPool(torch.nn.Module):
    def __init__(self, inner):
        super().__init__()
        self.inner = inner

    def forward(self, input_ids, attention_mask):
        hidden = self.inner(input_ids=input_ids, attention_mask=attention_mask).last_hidden_state
        return hidden[:, 0, :]  # CLS 池化（bge v1.5 语义）


tokenizer = AutoTokenizer.from_pretrained(str(SRC), local_files_only=True)
sample = tokenizer("用户偏好用中文回答问题", return_tensors="pt",
                   padding="max_length", truncation=True, max_length=MAX_LEN)
ids = sample["input_ids"].to(torch.int32)
mask = sample["attention_mask"].to(torch.int32)

traced = torch.jit.trace(ClsPool(model).eval(), (ids, mask))
mlmodel = ct.convert(
    traced,
    inputs=[
        ct.TensorType(name="input_ids", shape=(1, MAX_LEN), dtype=np.int32),
        ct.TensorType(name="attention_mask", shape=(1, MAX_LEN), dtype=np.int32),
    ],
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS15,
)
fp16_path = OUT / "BGEZh-fp16.mlpackage"
mlmodel.save(str(fp16_path))
print("fp16 saved:", fp16_path, sum(f.stat().st_size for f in fp16_path.rglob("*") if f.is_file()) >> 20, "MB")

# int8 线性量化（MatMul/Linear 大权重），体积减半；质量以 eval-coreml.py 复核。
from coremltools.optimize.coreml import (
    OpLinearQuantizerConfig,
    OptimizationConfig,
    linear_quantize_weights,
)

quant_config = OptimizationConfig(
    global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", weight_threshold=512)
)
int8_model = linear_quantize_weights(mlmodel, config=quant_config)
int8_path = OUT / "BGEZh-int8.mlpackage"
int8_model.save(str(int8_path))
print("int8 saved:", int8_path, sum(f.stat().st_size for f in int8_path.rglob("*") if f.is_file()) >> 20, "MB")

# 词表原样带出（Swift WordPiece 分词器资源）。
import shutil

shutil.copy(SRC / "vocab.txt", OUT / "BGEZhVocab.txt")
print("vocab copied")
