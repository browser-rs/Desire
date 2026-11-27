# 支付卡保险库（v0.8.82）设计记录

## 边界

- **本机 only**：v1 不进同步、不导出、不共享；换机需重新录入。
- **CVV 永不落盘**：模型、UI、桥都没有 CVV 字段。站点要求 CVV 时由用户手输。
- **卡号只在用户显式动作时读**：列表/设置只看品牌、末四位、有效期（元数据）。
- **不自动提交**：填充只写空字段并派发 input/change；提交永远由用户点击。

## 存储

| 数据 | 位置 | 说明 |
|---|---|---|
| 卡号 | Keychain，account `payment-card-<uuid>`，service `me.siwi.Desire` | 与网站密码同钥匙串域；封闭实例写 `<data-dir>/keychain/` 文件库 |
| 品牌/末四位/有效期/持卡人/Label | `DiskStore` key `paymentCardsMeta` | 全是非机密元数据；列表不读 Keychain |
| CVV | 不存 | 没有字段、没有读取路径 |

## 使用路径

1. 设置 → 自动填充 → Payment Cards → Add Card：输入 Label/持卡人/卡号/有效期；
   `PaymentCardNumber` 做 Luhn、品牌、有效期校验，失败不写入。
2. 站点锁弹层 → Fill Card → 选一张卡：宿主读一次 Keychain，注入
   `__desireFillCard`；只填 `cc-number` / `cc-name` / `cc-exp` / month/year 形状的空字段。
3. 删除：先删 Keychain 条目，再删元数据。

## 威胁模型检查

- 磁盘泄露：元数据无卡号；Keychain 受 ACL/登录密码保护（真实环境）或封闭文件库（测试）。
- 页面脚本：填充脚本只在 `agentToolWorld` 求值，不把 Card 对象暴露给页面全局；值通过 DOM 事件写入。
- 日志/桥：桥只返回 `brand/last4/month/year`，不返回卡号；不写日志。
- 同步/备份：v1 明确不做；备份导出不包含支付卡。

## 未做（后续）

- 卡号更新/替换（当前删除后重加）。
- 跨设备同步（需要单独的保险库设计）。
- 多浏览器导入（Chrome 支付卡 CSV 格式差异大，先不做）。
