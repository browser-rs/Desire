
---

## 安装

未签名构建（CI 无 Developer ID 证书），仅支持 Apple Silicon（arm64，macOS 26.5+）。

1. **解压** `Desire-__TAG__-macos-arm64.zip`（双击，或
   `ditto -x -k Desire-__TAG__-macos-arm64.zip .`）。
2. **安装**：把解压出来的 **`Desire.app` 拖进 `/Applications`**。
3. **移除一次隔离标记**（未签名构建必需），路径写**你放 app 的那个**：

```
xattr -cr /Applications/Desire.app
```

4. **打开** `Desire.app`。首次启动 Gatekeeper 会检查一次；做过第 3 步就能正常打开。

> 报 `xattr: No such file: Desire.app` 说明当前目录里没有解压好的 app——
> 命令要写完整路径（如 `/Applications/Desire.app`），或先 `cd` 到它所在目录。
