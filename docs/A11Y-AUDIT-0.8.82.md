# v0.8.82 新视图无障碍清单

| 视图/控件 | 标签 | 备注 |
|---|---|---|
| 密码面板头部图标按钮 | `.accessibilityLabel(help)` | 生成/导入/加密导出/CSV/清空均读得懂 |
| 加密密码包 SecureField | Archive password / Confirm password | 口令框不再是“未命名文本框” |
| 密码健康操作 | 文本按钮（Mark handled/Snooze） | 行上下文菜单 |
| 支付卡设置行/删除 | 标题 + Delete card | 卡号输入有 Card number 标签 |
| 站点 Fill Card | 文本菜单 | 只列品牌+末四位 |
| 任务运行历史按钮 | Run history | 抽屉内状态/输出可读 |
| 任务失败诊断卡 | 类别 + 指引文本 | 不用只靠红色图标 |
| 同步冲突动作 | Use Local / Use Remote | 设置页与手机同文案 |
| 定时任务失败通知 | Retry / Ignore | 系统通知动作 |

**未做**：逐视图 VoiceOver Inspector 手工走查、首次进入引导。
`#Preview`/快照只验证布局，不等同于 VoiceOver 实测。
