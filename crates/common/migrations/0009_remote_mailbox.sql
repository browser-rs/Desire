-- 远程控制重构（Trove im_ws 模式，服务端可水平扩展）：
-- ① remote_inbox 升级为双端信箱：recipient='desktop' = 手机→桌面（指令/留言），
--    recipient='controller' = 桌面→手机（快照/回包，该桌面全部控制器共享信箱）。
--    发送一律 POST /remote/push：INSERT 行（持久、离线 24h 可达）→ Redis PUBLISH
--    express 信封（尽力而为，与实例无关）；接收 = express 即时 + GET /remote/pull
--    兜底，消费端按行 id 去重。WS 不再承载业务帧，只做订阅下行 + 心跳。
-- ② desktop_last_seen_at：桌面每次 pull 由服务器盖章（跨实例在线判定：
--    15s 内有戳 = 在线）。不再依赖进程内注册表。
ALTER TABLE `remote_inbox`
  ADD COLUMN `recipient` varchar(16) NOT NULL DEFAULT 'desktop' AFTER `desktop_device_id`,
  ADD KEY `idx_inbox_pending2` (`user_id`,`desktop_device_id`,`recipient`,`delivered_at`);

ALTER TABLE `remote_pairings`
  ADD COLUMN `desktop_last_seen_at` datetime(6) DEFAULT NULL AFTER `claimed_at`;
