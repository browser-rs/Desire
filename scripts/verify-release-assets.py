#!/usr/bin/env python3
"""发布资产回验：远端 Release 的资产大小/sha256 与本地待上传文件三方一致。

用法：python3 scripts/verify-release-assets.py <tag> <owner/repo> [目录]

对齐的是本地发版时代的 verify 闸门：GitHub 的 asset.digest 是服务端对**上传字节**
算的 sha256，和本地文件比对即可等价于"重新下载再校验"，且不吃资产 CDN 的慢速。
"""

import glob
import hashlib
import json
import os
import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__.strip())
        return 2
    tag, repo = sys.argv[1], sys.argv[2]
    directory = sys.argv[3] if len(sys.argv) > 3 else "."

    raw = subprocess.check_output(
        ["gh", "api", f"repos/{repo}/releases/tags/{tag}"], text=True
    )
    assets = {a["name"]: a for a in json.loads(raw)["assets"]}

    files = sorted(glob.glob(os.path.join(directory, "Desire-*.zip")))
    files.append(os.path.join(directory, "SHASUMS256.txt"))
    if len(files) != 3:
        print(f"✗ 预期 3 个资产，实际找到 {len(files)}：{files}", file=sys.stderr)
        return 1

    ok = True
    for path in files:
        name = os.path.basename(path)
        if name not in assets:
            print(f"✗ 远端缺资产 {name}", file=sys.stderr)
            ok = False
            continue
        data = open(path, "rb").read()
        asset = assets[name]
        if len(data) != asset["size"]:
            print(f"✗ {name} 大小不符：本地 {len(data)} vs 远端 {asset['size']}", file=sys.stderr)
            ok = False
            continue
        digest = "sha256:" + hashlib.sha256(data).hexdigest()
        if digest != asset["digest"]:
            print(f"✗ {name} sha256 不符", file=sys.stderr)
            ok = False
            continue
        print(f"✓ {name}（{asset['size']} bytes，sha256 三方一致）")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
