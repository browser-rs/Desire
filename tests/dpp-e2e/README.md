# DPP 真机 E2E（审批闸门 + 事件驱动回合）

前置手工步骤（顺序敏感）：

1. 构建并以自动化模式启动（独立构建产物，勿动 /Applications）：
   `xcodebuild -project Desire.xcodeproj -scheme Desire -derivedDataPath build/DerivedData build`
   `open build/DerivedData/Build/Products/Debug/Desire.app --args --automation`
2. **快照并改写访问等级**（闸门 E2E 需要 autoEdit；app 退出时 didSet 会用当前值
   覆盖 aiFullAccess，两个键都要还原）：
   `defaults read me.siwi.Desire aiAccessLevel` / `aiFullAccess` 记录原值 →
   `defaults write me.siwi.Desire aiAccessLevel -int 1` + `aiFullAccess -bool false`
3. 起常驻 fixture/假 LLM：`nohup python3 tests/dpp-e2e/serve_daemon.py &`
   （8877 = DPP fixture，8880 = 假 OpenAI SSE；**必须独立进程**——脚本内线程
   会随脚本退出死掉，制造"网络错误"假象）
4. `python3 tests/dpp-e2e/gate_e2e.py --use-daemon`（审批闸门 20 项）
   `python3 tests/dpp-e2e/event_e2e.py`（事件驱动回合 8 项）
5. 收尾：`osascript -e 'quit app "Desire"'` → 还原两个 defaults 键 →
   `pkill -f serve_daemon` → `lsof -nP -iTCP:8877 -iTCP:8880` 确认端口释放。

脚本自身负责：模型档案重定向与还原（并核对）、事件模式复位、测试会话按 id
删除。 gate_e2e.py 断言细节见文件头注释。
