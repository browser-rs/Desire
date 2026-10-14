
---

## 安装

未签名构建（CI 无 Developer ID 证书），要求 macOS 26.5+。
提供两种包：**Apple Silicon（arm64）** 与 **Intel（x86_64）**——Intel 包为
交叉编译产物，未经真机验证，遇到问题请用 arm64 包（或在 issue 里反馈）。

1. **解压** `Desire-__TAG__-macos-arm64.zip`（双击，或
   `ditto -x -k Desire-__TAG__-macos-arm64.zip .`；Intel 机器把文件名里的
   `arm64` 换成 `x86_64`）。
2. **安装**：把解压出来的 **`Desire.app` 拖进 `/Applications`**。
3. **移除一次隔离标记**（未签名构建必需），路径写**你放 app 的那个**：

```
xattr -cr /Applications/Desire.app
```

4. **打开** `Desire.app`。首次启动 Gatekeeper 会检查一次；做过第 3 步就能正常打开。

> 报 `xattr: No such file: Desire.app` 说明当前目录里没有解压好的 app——
> 命令要写完整路径（如 `/Applications/Desire.app`），或先 `cd` 到它所在目录。

> 校验：`shasum -a 256 -c SHASUMS256.txt`（两种包的校验和都在里面）。
